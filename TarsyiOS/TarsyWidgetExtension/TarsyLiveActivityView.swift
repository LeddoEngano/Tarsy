import ActivityKit
import SwiftUI
import WidgetKit

struct TarsyLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TarsyActivityAttributes.self) { context in
            // Lock Screen — compact single row
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded — single row: tool status + workspace + timer
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        Image(systemName: statusIcon(context.state))
                            .font(.system(size: 13))
                            .foregroundColor(statusColor(context.state.status))
                        Text(context.state.currentTool)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(secondaryColor)
                        .monospacedDigit()
                        .frame(minWidth: 36, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.workspaceName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(secondaryColor)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    EmptyView()
                }
            } compactLeading: {
                Image(systemName: statusIcon(context.state))
                    .font(.system(size: 12))
                    .foregroundColor(statusColor(context.state.status))
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(secondaryColor)
                    .monospacedDigit()
                    .frame(minWidth: 32)
            } minimal: {
                Image(systemName: statusIcon(context.state))
                    .font(.system(size: 12))
                    .foregroundColor(statusColor(context.state.status))
            }
        }
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TarsyActivityAttributes>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon(context.state))
                .font(.system(size: 16))
                .foregroundColor(statusColor(context.state.status))

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.workspaceName)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(context.state.currentTool)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(statusColor(context.state.status))
            }

            Spacer()

            Text(context.state.startedAt, style: .timer)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(secondaryColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(red: 0.1, green: 0.1, blue: 0.1))
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
