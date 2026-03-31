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
                DynamicIslandExpandedRegion(.leading) { EmptyView() }
                DynamicIslandExpandedRegion(.trailing) { EmptyView() }
                DynamicIslandExpandedRegion(.center) {
                    HStack {
                        statusDot(context.state.status)

                        Text(context.attributes.engineType)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(warmBeige)

                        Spacer()

                        Text(context.state.startedAt, style: .timer)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(amberColor)
                            .monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.isStale {
                        staleView
                    } else {
                        expandedBottomContent(context: context)
                    }
                }
            } compactLeading: {
                Image(systemName: toolIcon(context.state))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(context.state.status == "running" ? warmBeige : statusColor(context.state.status))
            } compactTrailing: {
                Image("TarsyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } minimal: {
                Image(systemName: toolIcon(context.state))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(statusColor(context.state.status))
            }
        }
    }

    // MARK: - Expanded Bottom

    @ViewBuilder
    private func expandedBottomContent(context: ActivityViewContext<TarsyActivityAttributes>) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                // Tool pill
                HStack(spacing: 5) {
                    Image(systemName: toolIcon(context.state))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(context.state.status == "running" ? warmBeige : statusColor(context.state.status))

                    Text(context.state.message ?? context.state.currentTool)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(warmBeige)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(statusColor(context.state.status).opacity(0.12))
                )

                Spacer()

                Text(context.attributes.workspaceName)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(secondaryText)
                    .lineLimit(1)
            }

            // Context usage bar
            if context.state.contextPercent > 0 {
                contextBar(percent: context.state.contextPercent)
            }
        }
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TarsyActivityAttributes>) -> some View {
        if context.isStale {
            // Stale fallback
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 2)
                        .frame(width: 32, height: 32)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updating…")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(context.attributes.workspaceName)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
                Text(context.state.startedAt, style: .timer)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } else {
            // Active state
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    // Status ring + engine icon
                    ZStack {
                        Circle()
                            .trim(from: 0, to: statusRingTrim(context.state.status))
                            .stroke(
                                statusColor(context.state.status),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                            )
                            .frame(width: 32, height: 32)
                            .rotationEffect(.degrees(-90))

                        Image(systemName: context.attributes.engineIcon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                    }

                    // Tool + workspace + engine
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: toolIcon(context.state))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(statusColor(context.state.status))

                            Text(context.state.message ?? context.state.currentTool)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }

                        HStack(spacing: 4) {
                            Text(context.attributes.workspaceName)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)

                            Text("·")
                                .foregroundColor(.secondary.opacity(0.5))

                            Text(context.attributes.engineType)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Timer
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                }

                // Context bar (only when we have data)
                if context.state.contextPercent > 0 {
                    contextBar(percent: context.state.contextPercent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .widgetURL(URL(string: "com.tarsy.ios://workspace/\(context.attributes.workspaceId)"))
        }
    }

    // MARK: - Context Bar

    private func contextBar(percent: Double) -> some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 4)
                    Capsule()
                        .fill(contextBarColor(percent))
                        .frame(width: max(geo.size.width * (percent / 100), 4), height: 4)
                }
            }
            .frame(height: 4)

            Text("\(Int(percent))%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(contextBarColor(percent))
                .frame(width: 28, alignment: .trailing)
        }
    }

    private func contextBarColor(_ percent: Double) -> Color {
        if percent > 80 { return terracottaColor }
        return amberColor
    }

    // MARK: - Stale View

    private var staleView: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(secondaryText)
            Text("Updating…")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(secondaryText)
        }
    }

    // MARK: - Helpers

    private func statusRingTrim(_ status: String) -> CGFloat {
        switch status {
        case "running": return 0.7
        case "waiting": return 0.5
        case "completed": return 1.0
        case "error": return 1.0
        default: return 0.3
        }
    }

    private func statusDot(_ status: String) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 8, height: 8)
    }

    private func toolIcon(_ state: TarsyActivityAttributes.ContentState) -> String {
        switch state.status {
        case "waiting": return "questionmark"
        case "completed": return "checkmark"
        case "error": return "xmark"
        default: return state.currentToolIcon
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
        case "running": return amberColor
        case "waiting": return amberColor
        case "completed": return mossColor
        case "error": return terracottaColor
        default: return secondaryText
        }
    }
}

// MARK: - Previews

private let previewAttrs = TarsyActivityAttributes(
    workspaceId: "p",
    workspaceName: "tarsy-frontend",
    engineType: "Claude Code",
    engineIcon: "brain.head.profile"
)

#Preview("Compact — Editing", as: .dynamicIsland(.compact), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Editing", currentToolIcon: "pencil.line", startedAt: .now.addingTimeInterval(-127), contextPercent: 34)
}

#Preview("Compact — Running", as: .dynamicIsland(.compact), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Running", currentToolIcon: "terminal", startedAt: .now.addingTimeInterval(-200), contextPercent: 62)
}

#Preview("Compact — Waiting", as: .dynamicIsland(.compact), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "waiting", currentTool: "Approve changes?", currentToolIcon: "questionmark.circle.fill", startedAt: .now.addingTimeInterval(-45))
}

#Preview("Compact — Error", as: .dynamicIsland(.compact), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "error", currentTool: "Build failed", currentToolIcon: "xmark.circle.fill", startedAt: .now.addingTimeInterval(-300))
}

#Preview("Expanded — Running", as: .dynamicIsland(.expanded), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Writing tests", currentToolIcon: "terminal", startedAt: .now.addingTimeInterval(-312), contextPercent: 45)
}

#Preview("Expanded — High Context", as: .dynamicIsland(.expanded), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Editing", currentToolIcon: "pencil.line", startedAt: .now.addingTimeInterval(-600), contextPercent: 87)
}

#Preview("Expanded — Waiting", as: .dynamicIsland(.expanded), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "waiting", currentTool: "Needs input", currentToolIcon: "questionmark.circle.fill", startedAt: .now.addingTimeInterval(-180), message: "Delete 3 files?")
}

#Preview("Expanded — Error", as: .dynamicIsland(.expanded), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "error", currentTool: "Build failed", currentToolIcon: "xmark.circle.fill", startedAt: .now.addingTimeInterval(-600))
}

#Preview("Minimal — Running", as: .dynamicIsland(.minimal), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Editing", currentToolIcon: "pencil.line", startedAt: .now.addingTimeInterval(-90))
}

#Preview("Minimal — Waiting", as: .dynamicIsland(.minimal), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "waiting", currentTool: "Needs input", currentToolIcon: "questionmark.circle.fill", startedAt: .now.addingTimeInterval(-45))
}

#Preview("Lock Screen — Running", as: .content, using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Editing ContentView.swift", currentToolIcon: "pencil.line", startedAt: .now.addingTimeInterval(-185), contextPercent: 42)
}

#Preview("Lock Screen — High Context", as: .content, using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Running tests", currentToolIcon: "terminal", startedAt: .now.addingTimeInterval(-500), contextPercent: 91)
}

#Preview("Lock Screen — Waiting", as: .content, using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "waiting", currentTool: "Needs input", currentToolIcon: "questionmark.circle.fill", startedAt: .now.addingTimeInterval(-92), message: "Delete 3 files?")
}

#Preview("Lock Screen — Error", as: .content, using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "error", currentTool: "Connection lost", currentToolIcon: "xmark.circle.fill", startedAt: .now.addingTimeInterval(-60))
}

#Preview("Lock Screen — Completed", as: .content, using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "completed", currentTool: "Done", currentToolIcon: "checkmark.circle", startedAt: .now.addingTimeInterval(-900), contextPercent: 67)
}
