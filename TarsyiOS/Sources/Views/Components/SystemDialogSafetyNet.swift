import SwiftUI
import TarsyShared
import UserNotifications

// MARK: - Model

/// A pending macOS system-level dialog (TCC, Automation, Keychain,
/// admin-password sheet) forwarded from the Mac so the user can handle
/// it remotely.
struct PendingSystemDialog: Identifiable, Equatable {
    /// Stable id assigned by the macOS detector. Used to target
    /// click-button commands at a specific dialog.
    let id: String
    let owner: String
    let title: String
    let body: String
    let buttons: [Button]
    /// `false` for dialogs backed by a secure text field (admin
    /// password, FileVault, keychain password). On those, iOS shows
    /// a "requires your admin password" message instead of clickable
    /// approve/deny buttons — macOS' WindowServer drops synthetic
    /// keystrokes into secure text fields, so we cannot help here.
    let remotelyActionable: Bool

    struct Button: Equatable, Codable, Identifiable {
        var id: String { label }
        let label: String
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }
}

// MARK: - Service

/// Subscribes to system-dialog packets from the macOS daemon and
/// exposes the currently-pending dialog (if any) as published state
/// for the banner/sheet UI.
///
/// Fires a local user notification when a new dialog arrives and the
/// app is not in the foreground, so the user has a chance to notice
/// without the app being actively open. (A server-side push via the
/// existing `push_notifications` pipeline is a follow-up for when iOS
/// is fully suspended — the local path only covers foreground/recent
/// background states.)
@MainActor
final class SystemDialogService: ObservableObject {
    @Published var currentDialog: PendingSystemDialog?

    private weak var connection: ConnectionManager?

    init() {}

    /// Attach to a ConnectionManager. Safe to call multiple times —
    /// the existing listener is replaced.
    func attach(to connection: ConnectionManager) {
        self.connection = connection
        connection.addListener("system-dialog-safety-net") { [weak self] packet in
            guard let self else { return }
            Task { @MainActor in
                self.handle(packet)
            }
        }
    }

    func detach() {
        connection?.removeListener("system-dialog-safety-net")
        connection = nil
    }

    private func handle(_ packet: WSPacket) {
        switch packet.action {
        case .systemDialogDetected:
            guard let dialog = decodeDialog(from: packet) else { return }
            // Debounce: if we already have the same dialog open, don't
            // re-notify or trigger a fresh UI animation.
            if currentDialog?.id == dialog.id { return }
            currentDialog = dialog
            maybeFireLocalNotification(for: dialog)
        case .systemDialogDismissed:
            guard let id = packet.payload?["id"] else { return }
            if currentDialog?.id == id {
                currentDialog = nil
            }
        default:
            break
        }
    }

    private func decodeDialog(from packet: WSPacket) -> PendingSystemDialog? {
        guard let payload = packet.payload,
              let id = payload["id"],
              let owner = payload["owner"]
        else { return nil }
        let title = payload["title"] ?? ""
        let body = payload["body"] ?? ""
        let remotelyActionable = (payload["remotelyActionable"] ?? "false") == "true"

        var buttons: [PendingSystemDialog.Button] = []
        if let buttonsJSON = payload["buttons"],
           let data = buttonsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(
                [PendingSystemDialog.Button].self, from: data) {
            buttons = decoded
        }

        return PendingSystemDialog(
            id: id,
            owner: owner,
            title: title,
            body: body,
            buttons: buttons,
            remotelyActionable: remotelyActionable
        )
    }

    /// Send a click-button command back to the Mac. The Mac re-scans
    /// live before clicking (stale AX refs would misfire otherwise),
    /// and we optimistically clear local state — the Mac will also
    /// emit `systemDialogDismissed` which is handled above.
    func click(_ label: String, on dialog: PendingSystemDialog) {
        connection?.send(WSPacket(
            action: .systemDialogClickButton,
            payload: [
                "id": dialog.id,
                "label": label,
            ]
        ))
        // Optimistic clear — re-appearance of the dialog will just
        // replace it (same id would be debounced, different id is a
        // new prompt).
        if currentDialog?.id == dialog.id {
            currentDialog = nil
        }
    }

    private func maybeFireLocalNotification(for dialog: PendingSystemDialog) {
        // Only fire when not foregrounded — we don't want a
        // notification to stack on top of the in-app banner.
        let state = UIApplication.shared.applicationState
        guard state != .active else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your Mac needs attention"
        if !dialog.title.isEmpty {
            content.body = dialog.title
        } else {
            content.body = "A system prompt is waiting for your approval."
        }
        content.sound = .default
        content.userInfo = ["system_dialog_id": dialog.id]

        let request = UNNotificationRequest(
            identifier: "system-dialog-\(dialog.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Banner

/// Persistent banner shown above the main content whenever a system
/// dialog is pending on the Mac. Tapping opens `SystemDialogSheet`.
struct SystemDialogBanner: View {
    @ObservedObject var service: SystemDialogService
    @Binding var showSheet: Bool

    var body: some View {
        if let dialog = service.currentDialog {
            Button {
                showSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.bubble")
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("mac needs attention")
                            .font(TarsyTheme.monoFontSmall)
                            .bold()
                        Text(dialog.title.isEmpty
                             ? "unknown system prompt"
                             : dialog.title)
                            .font(TarsyTheme.font(size: 10))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Text("review")
                        .font(TarsyTheme.font(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(TarsyTheme.accentAmber, lineWidth: 1)
                        )
                }
                .foregroundColor(TarsyTheme.accentAmber)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(TarsyTheme.accentAmber.opacity(0.1))
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Sheet

/// Modal sheet showing the full dialog contents and either native
/// buttons mirroring the macOS alert (when remotely-actionable) or a
/// plain informational message explaining why the user must handle
/// it physically at the Mac.
struct SystemDialogSheet: View {
    let dialog: PendingSystemDialog
    let onClick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Owner chip
                    HStack(spacing: 6) {
                        Image(systemName: "desktopcomputer")
                            .font(.caption2)
                        Text(dialog.owner)
                            .font(TarsyTheme.font(size: 10))
                    }
                    .foregroundColor(TarsyTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(TarsyTheme.backgroundSecondary)
                    )

                    // Title
                    if !dialog.title.isEmpty {
                        Text(dialog.title)
                            .font(TarsyTheme.font(size: 16, weight: .bold))
                            .foregroundColor(TarsyTheme.textPrimary)
                    }

                    // Body
                    if !dialog.body.isEmpty {
                        Text(dialog.body)
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()
                        .background(TarsyTheme.backgroundTertiary)

                    // Action area
                    if dialog.remotelyActionable && !dialog.buttons.isEmpty {
                        actionableButtons
                    } else {
                        nonActionableMessage
                    }

                    Spacer(minLength: 20)
                }
                .padding(20)
            }
            .background(TarsyTheme.backgroundPrimary)
            .navigationTitle("mac needs attention")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close") { dismiss() }
                        .foregroundColor(TarsyTheme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var actionableButtons: some View {
        VStack(spacing: 10) {
            ForEach(dialog.buttons) { button in
                Button {
                    onClick(button.label)
                } label: {
                    // Use the exact macOS label ("Allow" / "Don't Allow" /
                    // "OK" / "Cancel") so the user knows exactly what
                    // will happen on the Mac.
                    Text(button.label)
                        .font(TarsyTheme.font(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(buttonBackground(for: button.label))
                        .foregroundColor(buttonForeground(for: button.label))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            Text("tapping a button posts a synthetic click on the mac. your mac stays locked.")
                .font(TarsyTheme.font(size: 10))
                .foregroundColor(TarsyTheme.statusIdle)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var nonActionableMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 32))
                .foregroundColor(TarsyTheme.accentTerracotta)

            Text("this one needs your admin password")
                .font(TarsyTheme.font(size: 14, weight: .bold))
                .foregroundColor(TarsyTheme.textPrimary)

            Text("macos blocks remote tools from typing into password fields (this is the same reason teamviewer/anydesk can't do it either). tarsy can see the prompt but can't dismiss it for you. handle it next time you're at your mac.")
                .font(TarsyTheme.monoFontSmall)
                .foregroundColor(TarsyTheme.textSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if !dialog.buttons.isEmpty {
                Text("visible buttons on this prompt:")
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(TarsyTheme.statusIdle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                ForEach(dialog.buttons) { button in
                    Text("• \(button.label)")
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(TarsyTheme.accentTerracotta.opacity(0.08))
        )
    }

    /// Colour the destructive / cancel button differently from the
    /// affirmative one. We can't know which is which from the label
    /// alone, but macOS' common labels give us a strong heuristic.
    private func buttonBackground(for label: String) -> Color {
        let lower = label.lowercased()
        if lower.contains("don't allow") || lower == "cancel" || lower.contains("deny") {
            return TarsyTheme.backgroundSecondary
        }
        return TarsyTheme.accentAmber
    }

    private func buttonForeground(for label: String) -> Color {
        let lower = label.lowercased()
        if lower.contains("don't allow") || lower == "cancel" || lower.contains("deny") {
            return TarsyTheme.textPrimary
        }
        return TarsyTheme.backgroundPrimary
    }
}
