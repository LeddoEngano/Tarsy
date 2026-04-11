import SwiftUI
import TarsyShared

/// Settings → Mac Permissions sheet. Queries the macOS daemon for
/// live permission status (`permissions:status_request`) and shows a
/// green/red list so the user can tell at a glance whether anything
/// has been silently revoked — e.g., after a macOS update, a mistaken
/// toggle in System Settings, or a TCC reset.
///
/// The macOS side also broadcasts `permissions:status` unsolicited
/// whenever state transitions, so this view stays live without having
/// to poll from iOS.
struct PermissionDoctorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var status: LivePermissions? = nil
    @State private var lastUpdated: Date? = nil
    @State private var isRequesting = false

    struct LivePermissions: Equatable {
        var screenRecording: Bool
        var accessibility: Bool
        var automation: Bool
        var fullDiskAccess: Bool

        static func decode(from payload: [String: String]) -> LivePermissions {
            LivePermissions(
                screenRecording: payload["screen_recording"] == "true",
                accessibility: payload["accessibility"] == "true",
                automation: payload["automation"] == "true",
                fullDiskAccess: payload["full_disk_access"] == "true"
            )
        }

        var allGranted: Bool {
            screenRecording && accessibility && automation && fullDiskAccess
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header

                        if let status {
                            permissionList(status: status)
                            summary(status: status)
                        } else if !connectionManager.isConnected {
                            disconnectedState
                        } else {
                            loadingState
                        }

                        remoteLimitsExplainer

                        Spacer(minLength: 20)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("mac permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close") { dismiss() }
                        .foregroundColor(TarsyTheme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        requestStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(
                                isRequesting
                                    ? TarsyTheme.textSecondary
                                    : TarsyTheme.accentAmber)
                    }
                    .disabled(isRequesting || !connectionManager.isConnected)
                }
            }
            .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            connectionManager.addListener("permission-doctor-listener") { packet in
                guard packet.action == .permissionsStatus,
                      let payload = packet.payload else { return }
                Task { @MainActor in
                    self.status = LivePermissions.decode(from: payload)
                    self.lastUpdated = Date()
                    self.isRequesting = false
                }
            }
            requestStatus()
        }
        .onDisappear {
            connectionManager.removeListener("permission-doctor-listener")
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("live permissions")
                .font(TarsyTheme.font(size: 18, weight: .bold))
                .foregroundColor(TarsyTheme.textPrimary)
            Text("fetched directly from your mac. if any of these are red, tarsy cannot fully function remotely.")
                .font(TarsyTheme.monoFontSmall)
                .foregroundColor(TarsyTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func permissionList(status: LivePermissions) -> some View {
        VStack(spacing: 1) {
            permissionRow(
                icon: "rectangle.dashed.badge.record",
                name: "Screen Recording",
                why: "video stream to your iphone",
                granted: status.screenRecording)
            permissionRow(
                icon: "hand.tap",
                name: "Accessibility",
                why: "remote clicks and keystrokes",
                granted: status.accessibility)
            permissionRow(
                icon: "gearshape.2",
                name: "Automation",
                why: "browser control + dismissing dialogs",
                granted: status.automation)
            permissionRow(
                icon: "externaldrive.badge.checkmark",
                name: "Full Disk Access",
                why: "agents touching files anywhere",
                granted: status.fullDiskAccess)
        }
        .cornerRadius(10)
    }

    private func permissionRow(
        icon: String, name: String, why: String, granted: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(TarsyTheme.font(size: 16))
                .foregroundColor(TarsyTheme.textSecondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textPrimary)
                Text(why)
                    .font(TarsyTheme.font(size: 9))
                    .foregroundColor(TarsyTheme.textSecondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(granted ? TarsyTheme.accentMoss : TarsyTheme.statusError)
                    .frame(width: 6, height: 6)
                Text(granted ? "granted" : "missing")
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(
                        granted ? TarsyTheme.accentMoss : TarsyTheme.statusError)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(TarsyTheme.backgroundSecondary)
    }

    @ViewBuilder
    private func summary(status: LivePermissions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if status.allGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(TarsyTheme.accentMoss)
                    Text("all permissions granted")
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.accentMoss)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(TarsyTheme.accentTerracotta)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("one or more permissions are missing")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.accentTerracotta)
                        Text("open system settings on your mac and re-enable the missing grants. if you cannot do that remotely, handle it next time you're at your mac.")
                            .font(TarsyTheme.font(size: 10))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let lastUpdated {
                Text("last refresh: \(lastUpdated.formatted(.dateTime.hour().minute().second()))")
                    .font(TarsyTheme.font(size: 9))
                    .foregroundColor(TarsyTheme.statusIdle)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(TarsyTheme.backgroundSecondary)
        )
    }

    private var loadingState: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
            Text("querying your mac...")
                .font(TarsyTheme.monoFontSmall)
                .foregroundColor(TarsyTheme.textSecondary)
                .padding(.leading, 8)
            Spacer()
        }
        .padding()
    }

    /// Honest one-paragraph explainer about what Tarsy fundamentally
    /// cannot do remotely — the secure-input wall that applies to
    /// every remote control tool on macOS, not just Tarsy. Users who
    /// understand the constraint forgive it; users who discover it
    /// mid-crisis churn.
    private var remoteLimitsExplainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("what tarsy can't do remotely")
                .font(TarsyTheme.font(size: 11, weight: .semibold))
                .foregroundColor(TarsyTheme.textSecondary)

            Text("if macos asks for your admin password (installing software, changing a privacy setting), tarsy can see the prompt and will send you a notification — but it cannot type your password for you. macos blocks remote tools from touching password fields. this is the same limit teamviewer, anydesk, and every other remote control tool hits. for those, handle it next time you're at your mac.")
                .font(TarsyTheme.font(size: 10))
                .foregroundColor(TarsyTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            Text("for every other kind of prompt (file access, automation consent, keychain unlock, etc.), tarsy's safety net should catch it and let you approve remotely.")
                .font(TarsyTheme.font(size: 10))
                .foregroundColor(TarsyTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(TarsyTheme.backgroundSecondary)
        )
    }

    private var disconnectedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.icloud")
                    .foregroundColor(TarsyTheme.accentTerracotta)
                Text("not connected")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.accentTerracotta)
            }
            Text("tarsy needs to be connected to your mac to fetch live permission status.")
                .font(TarsyTheme.font(size: 10))
                .foregroundColor(TarsyTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(TarsyTheme.accentTerracotta.opacity(0.08))
        )
    }

    // MARK: - Actions

    private func requestStatus() {
        guard connectionManager.isConnected else { return }
        isRequesting = true
        connectionManager.send(WSPacket(action: .permissionsStatusRequest))
        // Timeout the spinner if the Mac never replies.
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                if self.status == nil {
                    self.isRequesting = false
                }
            }
        }
    }
}
