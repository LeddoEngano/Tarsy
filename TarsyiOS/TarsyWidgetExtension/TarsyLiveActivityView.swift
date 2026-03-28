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
                            .foregroundColor(amberColor)
                        Text(context.attributes.engineType)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundColor(secondaryColor)
                        Text(context.state.startedAt, style: .timer)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(secondaryColor)
                            .monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        Text(context.attributes.workspaceName)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .lineLimit(1)

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
                HStack(spacing: 4) {
                    Image(systemName: context.attributes.engineIcon)
                        .font(.system(size: 12))
                        .foregroundColor(amberColor)
                }
            } compactTrailing: {
                HStack(spacing: 3) {
                    if context.state.status == "waiting" {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(amberColor)
                    } else {
                        Text(context.state.startedAt, style: .timer)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(mossColor)
                            .monospacedDigit()
                            .frame(minWidth: 32)
                    }
                }
            } minimal: {
                Image(systemName: context.state.status == "waiting" ? "questionmark.circle.fill" : context.attributes.engineIcon)
                    .font(.system(size: 12))
                    .foregroundColor(context.state.status == "waiting" ? amberColor : mossColor)
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
                    .fill(amberColor.opacity(0.2))
                    .frame(width: 40, height: 40)
                Image(systemName: context.attributes.engineIcon)
                    .font(.system(size: 18))
                    .foregroundColor(amberColor)
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(context.attributes.workspaceName)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(secondaryColor)
                        .monospacedDigit()
                }

                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: context.state.currentToolIcon)
                            .font(.system(size: 10))
                        Text(context.state.currentTool)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundColor(statusColor(context.state.status))

                    Spacer()

                    statusBadge(context.state.status)
                }
            }
        }
        .padding(16)
        .background(Color(red: 0.1, green: 0.1, blue: 0.1))
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

    // TarsyTheme colors as computed properties (avoid Color(hex:) conflicts)
    private var amberColor: Color { Color(red: 212/255, green: 165/255, blue: 116/255) }
    private var mossColor: Color { Color(red: 122/255, green: 139/255, blue: 111/255) }
    private var terracottaColor: Color { Color(red: 196/255, green: 112/255, blue: 75/255) }
    private var secondaryColor: Color { Color(red: 168/255, green: 158/255, blue: 145/255) }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "running": return mossColor
        case "waiting": return amberColor
        case "completed": return mossColor
        case "error": return terracottaColor
        default: return secondaryColor
        }
    }
}
