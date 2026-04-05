import AppKit
import SwiftUI

/// A floating, non-activating panel that hosts the UltraContext overlay button.
/// Positioned relative to the terminal window and never steals keyboard focus.
final class OverlayButtonWindow: NSPanel {
    init(onClick: @escaping () -> Void) {
        let buttonSize: CGFloat = 36
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: buttonSize, height: buttonSize),
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
        hasShadow = false
        ignoresMouseEvents = false
        isMovableByWindowBackground = false

        let hostingView = NSHostingView(rootView: OverlayButtonView(onClick: onClick))
        hostingView.frame = NSRect(x: 0, y: 0, width: buttonSize, height: buttonSize)
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Reposition to top-right of the given terminal window frame.
    /// `terminalFrame` uses top-left origin (AX coordinates).
    func anchorToTerminalWindow(_ terminalFrame: CGRect) {
        guard let screen = bestScreen(for: terminalFrame) else { return }

        let buttonSize = frame.size
        let padding: CGFloat = 12

        // AX uses top-left origin; convert to AppKit bottom-left origin
        let screenHeight = screen.frame.maxY + screen.frame.minY
        let x = terminalFrame.maxX - buttonSize.width - padding
        let y = screenHeight - terminalFrame.origin.y - buttonSize.height - padding - 32 // offset below title bar

        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func bestScreen(for axFrame: CGRect) -> NSScreen? {
        // Find the screen that contains the terminal window's top-left corner
        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            // AX top-left to AppKit bottom-left for the point
            let screenHeight = screen.frame.maxY + screen.frame.minY
            let convertedY = screenHeight - axFrame.origin.y
            let point = NSPoint(x: axFrame.origin.x, y: convertedY)
            if screenFrame.contains(point) {
                return screen
            }
        }
        return NSScreen.main
    }
}

// MARK: - Button View

private struct OverlayButtonView: View {
    let onClick: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onClick) {
            ZStack {
                Circle()
                    .fill(Color(hex: "131316").opacity(0.9))
                    .overlay(
                        Circle()
                            .strokeBorder(Color(hex: "2a2a30"), lineWidth: 1)
                    )

                Image(systemName: "brain.head.profile")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isHovering ? Color(hex: "ffffff") : Color(hex: "71717a"))
            }
        }
        .buttonStyle(.plain)
        .frame(width: 36, height: 36)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}
