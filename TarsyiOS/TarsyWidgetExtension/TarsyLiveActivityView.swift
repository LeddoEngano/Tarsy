import ActivityKit
import SwiftUI
import WidgetKit

struct TarsyLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TarsyActivityAttributes.self) { context in
            // Lock Screen — thin single row
            lockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.1, green: 0.1, blue: 0.1))
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded — keep minimal
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.currentTool, systemImage: statusIcon(context.state))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(statusColor(context.state.status))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(secondaryColor)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    EmptyView()
                }
            } compactLeading: {
                // Just the status/tool icon
                Image(systemName: statusIcon(context.state))
                    .font(.system(size: 11))
                    .foregroundColor(statusColor(context.state.status))
            } compactTrailing: {
                // Just the timer, no forced width
                Text(context.state.startedAt, style: .timer)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(secondaryColor)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: statusIcon(context.state))
                    .font(.system(size: 11))
                    .foregroundColor(statusColor(context.state.status))
            }
        }
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TarsyActivityAttributes>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon(context.state))
                .font(.system(size: 13))
                .foregroundColor(statusColor(context.state.status))

            Text(context.attributes.workspaceName)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer()

            Text(context.state.startedAt, style: .timer)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(secondaryColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func statusIcon(_ state: TarsyActivityAttributes.ContentState) -> String {
        switch state.status {
        case "waiting": return "questionmark.circle.fill"
        case "completed": return "checkmark.circle.fill"
        case "error": return "xmark.circle.fill"
        default: return state.currentToolIcon
        }
    }

    private var mossColor: Color { Color(red: 122/255, green: 139/255, blue: 111/255) }
    private var amberColor: Color { Color(red: 212/255, green: 165/255, blue: 116/255) }
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
