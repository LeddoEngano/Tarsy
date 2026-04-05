import AppKit
import SwiftUI
import TarsyShared

/// A floating panel that displays UltraContext sessions for injection.
final class ContextPickerPanel: NSPanel {
    private let panelWidth: CGFloat = 340
    private let panelHeight: CGFloat = 420

    init(sessions: [UltraContextSession], onSelect: @escaping (UltraContextSession) -> Void, onDismiss: @escaping () -> Void) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let view = ContextPickerView(sessions: sessions, onSelect: onSelect, onDismiss: onDismiss)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Position the picker next to the overlay button
    func anchorToButton(_ buttonFrame: NSRect) {
        let x = buttonFrame.origin.x - panelWidth - 8
        let y = buttonFrame.origin.y - panelHeight + buttonFrame.height
        setFrameOrigin(NSPoint(x: max(x, 20), y: max(y, 40)))
    }
}

// MARK: - Picker View

private struct ContextPickerView: View {
    let sessions: [UltraContextSession]
    let onSelect: (UltraContextSession) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""

    private var filtered: [UltraContextSession] {
        let sorted = sessions.sorted { a, b in
            (a.updatedAt ?? "") > (b.updatedAt ?? "")
        }
        guard !searchText.isEmpty else { return sorted }
        let query = searchText.lowercased()
        return sorted.filter { session in
            session.displayTitle.lowercased().contains(query) ||
            (session.engineType?.lowercased().contains(query) ?? false) ||
            (session.projectName?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("contexts")
                    .font(TarsyTheme.font(size: 13, weight: .semibold))
                    .foregroundColor(TarsyTheme.textPrimary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(TarsyTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(TarsyTheme.textSecondary)
                TextField("search...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(TarsyTheme.font(size: 12))
                    .foregroundColor(TarsyTheme.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(TarsyTheme.backgroundTertiary)
            .cornerRadius(6)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            Divider()
                .background(TarsyTheme.backgroundTertiary)

            // Sessions list
            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 24))
                        .foregroundColor(TarsyTheme.textSecondary)
                    Text(sessions.isEmpty ? "no contexts available" : "no matches")
                        .font(TarsyTheme.font(size: 12))
                        .foregroundColor(TarsyTheme.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { session in
                            ContextRow(session: session)
                                .onTapGesture { onSelect(session) }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(width: 340, height: 420)
        .background(TarsyTheme.backgroundPrimary)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(TarsyTheme.backgroundTertiary, lineWidth: 1)
        )
    }
}

// MARK: - Row

private struct ContextRow: View {
    let session: UltraContextSession
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Engine icon
            engineIcon
                .font(.system(size: 12))
                .foregroundColor(TarsyTheme.textSecondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(TarsyTheme.font(size: 12, weight: .medium))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let engine = session.engineType {
                        Text(engine)
                            .font(TarsyTheme.font(size: 10))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                    if let count = session.messageCount {
                        Text("\(count) msgs")
                            .font(TarsyTheme.font(size: 10))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "arrow.right.circle")
                .font(.system(size: 12))
                .foregroundColor(isHovering ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isHovering ? TarsyTheme.backgroundSecondary : Color.clear)
        .cornerRadius(6)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }

    @ViewBuilder
    private var engineIcon: some View {
        switch session.engineType?.lowercased() {
        case "claude", "claude-code":
            Image(systemName: "sparkle")
        case "gemini":
            Image(systemName: "diamond")
        case "codex":
            Image(systemName: "chevron.left.forwardslash.chevron.right")
        case "aider":
            Image(systemName: "wrench")
        default:
            Image(systemName: "terminal")
        }
    }
}
