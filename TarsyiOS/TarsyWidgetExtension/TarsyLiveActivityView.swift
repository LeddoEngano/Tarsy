import ActivityKit
import SwiftUI
import WidgetKit

struct TarsyLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TarsyActivityAttributes.self) { context in
            // MARK: - Lock Screen Banner
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // MARK: - Expanded Dynamic Island
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        // Pulsing status dot
                        Circle()
                            .fill(statusColor(context.state.status))
                            .frame(width: 8, height: 8)

                        Image(systemName: context.attributes.engineIcon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(warmBeige)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(secondaryText)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        // Current tool indicator
                        HStack(spacing: 5) {
                            Image(systemName: toolIcon(context.state))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(statusColor(context.state.status))

                            Text(context.state.currentTool)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(warmBeige)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                        )

                        Spacer()

                        // Workspace name
                        Text(context.attributes.workspaceName)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(secondaryText)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                // MARK: - Compact Leading
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor(context.state.status))
                        .frame(width: 6, height: 6)

                    Image(systemName: toolIcon(context.state))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(warmBeige)
                }
            } compactTrailing: {
                // MARK: - Compact Trailing
                Text(context.state.startedAt, style: .timer)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(secondaryText)
                    .monospacedDigit()
            } minimal: {
                // MARK: - Minimal
                ZStack {
                    Circle()
                        .strokeBorder(statusColor(context.state.status).opacity(0.5), lineWidth: 1.5)
                    Image(systemName: minimalIcon(context.state))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(statusColor(context.state.status))
                }
            }
        }
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TarsyActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            // Left: engine icon with status ring
            ZStack {
                Circle()
                    .stroke(statusColor(context.state.status).opacity(0.3), lineWidth: 2)
                    .frame(width: 36, height: 36)

                Circle()
                    .trim(from: 0, to: context.state.status == "running" ? 0.75 : 1.0)
                    .stroke(statusColor(context.state.status), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(-90))

                Image(systemName: context.attributes.engineIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(warmBeige)
            }

            // Center: workspace + tool
            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.workspaceName)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(warmBeige)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: toolIcon(context.state))
                        .font(.system(size: 10))
                        .foregroundColor(statusColor(context.state.status))

                    Text(context.state.currentTool)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Right: timer
            Text(context.state.startedAt, style: .timer)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundColor(amberColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .activityBackgroundTint(bgPrimary)
    }

    // MARK: - Icons

    private func toolIcon(_ state: TarsyActivityAttributes.ContentState) -> String {
        switch state.status {
        case "waiting": return "questionmark.circle.fill"
        case "completed": return "checkmark.circle.fill"
        case "error": return "xmark.circle.fill"
        default: return state.currentToolIcon
        }
    }

    private func minimalIcon(_ state: TarsyActivityAttributes.ContentState) -> String {
        switch state.status {
        case "waiting": return "questionmark"
        case "completed": return "checkmark"
        case "error": return "xmark"
        default: return "chevron.right"
        }
    }

    // MARK: - TarsyTheme Colors

    private var bgPrimary: Color { Color(red: 26/255, green: 26/255, blue: 26/255) }
    private var warmBeige: Color { Color(red: 232/255, green: 224/255, blue: 212/255) }
    private var secondaryText: Color { Color(red: 168/255, green: 158/255, blue: 145/255) }
    private var amberColor: Color { Color(red: 212/255, green: 165/255, blue: 116/255) }
    private var mossColor: Color { Color(red: 122/255, green: 139/255, blue: 111/255) }
    private var terracottaColor: Color { Color(red: 196/255, green: 112/255, blue: 75/255) }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "running": return mossColor
        case "waiting": return amberColor
        case "completed": return mossColor
        case "error": return terracottaColor
        default: return secondaryText
        }
    }
}
