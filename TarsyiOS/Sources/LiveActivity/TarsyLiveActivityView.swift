import ActivityKit
import SwiftUI
import WidgetKit

struct TarsyLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TarsyActivityAttributes.self) { context in
            // Lock Screen presentation
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded regions
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: context.attributes.engineIcon)
                            .font(.system(size: 14))
                            .foregroundColor(Color(hexValue: "d4a574"))
                        Text(context.attributes.engineType)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hexValue: "a89e91"))
                        Text(formatElapsed(context.state.elapsedSeconds))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(hexValue: "a89e91"))
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        Text(context.attributes.workspaceName)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)

                        HStack(spacing: 4) {
                            Image(systemName: context.state.currentToolIcon)
                                .font(.system(size: 11))
                            Text(context.state.currentTool)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .foregroundColor(statusColor(context.state.status))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    statusBadge(context.state.status)
                }
            } compactLeading: {
                // Compact leading — engine icon
                Image(systemName: context.attributes.engineIcon)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hexValue: "d4a574"))
            } compactTrailing: {
                // Compact trailing — status indicator
                HStack(spacing: 3) {
                    if context.state.status == "running" {
                        Image(systemName: context.state.currentToolIcon)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hexValue: "7a8b6f"))
                    } else if context.state.status == "waiting" {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hexValue: "d4a574"))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hexValue: "7a8b6f"))
                    }
                }
            } minimal: {
                // Minimal — just the status dot
                Image(systemName: context.attributes.engineIcon)
                    .font(.system(size: 12))
                    .foregroundColor(statusColor(context.state.status))
            }
        }
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TarsyActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            // Engine icon
            ZStack {
                Circle()
                    .fill(Color(hexValue: "d4a574").opacity(0.2))
                    .frame(width: 40, height: 40)
                Image(systemName: context.attributes.engineIcon)
                    .font(.system(size: 18))
                    .foregroundColor(Color(hexValue: "d4a574"))
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(context.attributes.workspaceName)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Text(formatElapsed(context.state.elapsedSeconds))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(hexValue: "a89e91"))
                }

                HStack(spacing: 6) {
                    // Tool indicator
                    HStack(spacing: 3) {
                        Image(systemName: context.state.currentToolIcon)
                            .font(.system(size: 10))
                        Text(context.state.currentTool)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundColor(statusColor(context.state.status))

                    Spacer()

                    // Status badge
                    statusBadge(context.state.status)
                }
            }
        }
        .padding(16)
        .background(Color(hexValue: "1a1a1a"))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 6, height: 6)
            Text(status)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(statusColor(status))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusColor(status).opacity(0.15))
        .cornerRadius(6)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "running": return Color(hexValue: "7a8b6f")
        case "waiting": return Color(hexValue: "d4a574")
        case "completed": return Color(hexValue: "7a8b6f")
        case "error": return Color(hexValue: "c4704b")
        default: return Color(hexValue: "a89e91")
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        if m > 0 {
            return "\(m)m \(s)s"
        }
        return "\(s)s"
    }
}

// Color helper for Live Activity (fileprivate to avoid redeclaration with TarsyTheme)
fileprivate extension Color {
    init(hexValue: String) {
        let hex = hexValue.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
