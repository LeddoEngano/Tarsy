import ActivityKit
import AppIntents
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
                    tarsyEyes(size: 24)
                        .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    EmptyView()
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
                    .font(Self.tarsyFont(size: 14, weight: .bold))
                    .foregroundColor(context.state.status == "running" ? textPrimary : statusColor(context.state.status))
            } compactTrailing: {
                tarsyEyes(size: 18)
            } minimal: {
                Image(systemName: toolIcon(context.state))
                    .font(Self.tarsyFont(size: 14, weight: .bold))
                    .foregroundColor(statusColor(context.state.status))
            }
        }
    }

    // MARK: - Expanded Bottom

    @ViewBuilder
    private func expandedBottomContent(context: ActivityViewContext<TarsyActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer().frame(height: context.state.status == "waiting" ? 4 : 12)
            // Title: user prompt + agent icon (top row)
            HStack {
                engineIconView(context.attributes)
                    .frame(width: 16, height: 16)

                if let prompt = context.state.userPrompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(Self.tarsyFont(size: 13, weight: .semibold))
                        .foregroundColor(textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(context.state.message ?? context.state.currentTool)
                        .font(Self.tarsyFont(size: 13, weight: .semibold))
                        .foregroundColor(textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                Text("ctx:\(Int(context.state.contextPercent))%")
                    .font(Self.tarsyFont(size: 10, weight: .medium))
                    .foregroundColor(contextBarColor(context.state.contextPercent))
            }

            // Agent activity: what it's doing now
            HStack(spacing: 5) {
                Spacer().frame(width: 16)
                Image(systemName: toolIcon(context.state))
                    .font(Self.tarsyFont(size: 10, weight: .semibold))
                    .foregroundColor(.white)

                if let agentMsg = context.state.lastAgentMessage, !agentMsg.isEmpty {
                    Text(agentMsg)
                        .font(Self.tarsyFont(size: 11, weight: .medium))
                        .foregroundColor(textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(context.attributes.engineType)
                        .font(Self.tarsyFont(size: 11, weight: .medium))
                        .foregroundColor(textPrimary)
                }

                Spacer()

                Text(Date(timeIntervalSince1970: context.state.startedAt), style: .timer)
                    .font(Self.tarsyFont(size: 11, weight: .medium))
                    .foregroundColor(accentWhite)
                    .monospacedDigit()
            }

            // Other active agents indicator
            if let agents = context.state.activeAgents, !agents.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundColor(accentMoss)
                    Text("+\(agents.count) agent\(agents.count > 1 ? "s" : "") running")
                        .font(Self.tarsyFont(size: 10, weight: .medium))
                        .foregroundColor(textSecondary)
                    Spacer()
                }
            }

            // Permission action buttons (when waiting with options)
            if context.state.status == "waiting" {
                permissionButtons(context: context)
            }

            Spacer()

            HStack {
                Spacer()
                Text("be inspired. stay productive.")
                    .font(Self.tarsyFont(size: 8, weight: .regular))
                    .foregroundColor(textSecondary.opacity(0.5))
                Spacer()
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TarsyActivityAttributes>) -> some View {
        if context.isStale {
            // Stale fallback
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(textSecondary.opacity(0.4), lineWidth: 2)
                        .frame(width: 32, height: 32)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(Self.tarsyFont(size: 13, weight: .semibold))
                        .foregroundColor(textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updating…")
                        .font(Self.tarsyFont(size: 12, weight: .medium))
                        .foregroundColor(textSecondary)
                    Text(context.attributes.workspaceName)
                        .font(Self.tarsyFont(size: 10, weight: .regular))
                        .foregroundColor(textSecondary.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
                Text(Date(timeIntervalSince1970: context.state.startedAt), style: .timer)
                    .font(Self.tarsyFont(size: 15, weight: .semibold))
                    .foregroundColor(textSecondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } else {
            // Active state
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    // Status ring + animated Tarsy eyes
                    ZStack {
                        Circle()
                            .trim(from: 0, to: statusRingTrim(context.state.status))
                            .stroke(
                                statusColor(context.state.status),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                            )
                            .frame(width: 32, height: 32)
                            .rotationEffect(.degrees(-90))

                        tarsyEyes(size: 22)
                    }

                    // Tool + workspace + engine
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: toolIcon(context.state))
                                .font(Self.tarsyFont(size: 10, weight: .semibold))
                                .foregroundColor(statusColor(context.state.status))

                            Text(context.state.message ?? context.state.currentTool)
                                .font(Self.tarsyFont(size: 12, weight: .semibold))
                                .foregroundColor(textPrimary)
                                .lineLimit(1)
                        }

                        HStack(spacing: 4) {
                            Text(context.attributes.workspaceName)
                                .font(Self.tarsyFont(size: 10, weight: .medium))
                                .foregroundColor(textSecondary)
                                .lineLimit(1)

                            Text("·")
                                .foregroundColor(textSecondary.opacity(0.5))

                            Text(context.attributes.engineType)
                                .font(Self.tarsyFont(size: 10, weight: .medium))
                                .foregroundColor(textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Timer
                    Text(Date(timeIntervalSince1970: context.state.startedAt), style: .timer)
                        .font(Self.tarsyFont(size: 15, weight: .bold))
                        .foregroundColor(textPrimary)
                        .monospacedDigit()
                }

                // Permission action buttons (when waiting with options)
                if context.state.status == "waiting" {
                    permissionButtons(context: context)
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

    // MARK: - Permission Buttons

    @ViewBuilder
    private func permissionButtons(context: ActivityViewContext<TarsyActivityAttributes>) -> some View {
        if let options = context.state.questionOptions,
           let sessionId = context.state.sessionId,
           !options.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(options.prefix(4).enumerated()), id: \.offset) { _, option in
                    let formattedAnswer = formatAnswer(questionKey: context.state.questionKey, option: option)
                    Button(intent: PermissionResponseIntent(
                        sessionId: sessionId,
                        engineType: context.state.engineTypeRaw ?? "claude",
                        answer: formattedAnswer,
                        workspaceId: context.attributes.workspaceId,
                        permissionRequestId: context.state.permissionRequestId ?? ""
                    )) {
                        Text(option)
                            .font(Self.tarsyFont(size: 12, weight: .semibold))
                            .foregroundColor(permissionButtonTextColor(option))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(permissionButtonColor(option))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func formatAnswer(questionKey: String?, option: String) -> String {
        guard let key = questionKey, !key.isEmpty else { return option }
        return "\(key): \(option)"
    }

    private func isNegativeOption(_ option: String) -> Bool {
        let lower = option.lowercased()
        return lower.contains("deny") || lower == "no" || lower == "n" || lower.contains("reject") || lower.contains("cancel")
    }

    private func isBroadAllowOption(_ option: String) -> Bool {
        let lower = option.lowercased()
        return lower.contains("always") || lower.contains("allow all") || lower.contains("bypass") || lower.contains("trust")
    }

    private func permissionButtonColor(_ option: String) -> Color {
        if isNegativeOption(option) { return accentTerracotta.opacity(0.25) }
        if isBroadAllowOption(option) { return accentMoss.opacity(0.3) }
        return accentWhite.opacity(0.25)
    }

    private func permissionButtonTextColor(_ option: String) -> Color {
        if isNegativeOption(option) { return accentTerracotta }
        if isBroadAllowOption(option) { return accentMoss }
        return accentWhite
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
                .font(Self.tarsyFont(size: 9, weight: .medium))
                .foregroundColor(contextBarColor(percent))
                .frame(width: 28, alignment: .trailing)
        }
    }

    private func contextBarColor(_ percent: Double) -> Color {
        if percent > 80 { return accentTerracotta }
        return accentWhite
    }

    // MARK: - Stale View

    private var staleView: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(Self.tarsyFont(size: 11, weight: .semibold))
                .foregroundColor(textSecondary)
            Text("Updating…")
                .font(Self.tarsyFont(size: 12, weight: .medium))
                .foregroundColor(textSecondary)
        }
    }

    // MARK: - Engine Icon

    @ViewBuilder
    private func engineIconView(_ attrs: TarsyActivityAttributes) -> some View {
        if let asset = attrs.engineIconAsset {
            Image(asset)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: attrs.engineIcon)
                .font(Self.tarsyFont(size: 12, weight: .medium))
                .foregroundColor(textSecondary)
        }
    }

    // MARK: - Tarsy Eyes

    private func tarsyEyes(size: CGFloat) -> some View {
        HStack(spacing: size * 0.06) {
            Circle()
                .fill(.white)
                .frame(width: size * 0.36, height: size * 0.36)
            Circle()
                .fill(.white)
                .frame(width: size * 0.52, height: size * 0.52)
        }
        .frame(width: size, height: size)
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

    // MARK: - TarsyTheme Fonts

    private static func tarsyFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: - TarsyTheme Colors

    private var bgPrimary: Color { Color(red: 0x13/255, green: 0x13/255, blue: 0x16/255) }
    private var textPrimary: Color { Color(red: 0xe4/255, green: 0xe4/255, blue: 0xe7/255) }
    private var textSecondary: Color { Color(red: 0x71/255, green: 0x71/255, blue: 0x7a/255) }
    private var accentWhite: Color { Color.white }
    private var statusStarting: Color { Color(red: 0xe0/255, green: 0xa8/255, blue: 0x6a/255) }
    private var accentMoss: Color { Color(red: 0x6b/255, green: 0xc7/255, blue: 0x7b/255) }
    private var accentTerracotta: Color { Color(red: 0xe5/255, green: 0x71/255, blue: 0x6a/255) }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "running": return accentMoss
        case "waiting": return statusStarting
        case "completed": return accentMoss
        case "error": return accentTerracotta
        default: return textSecondary
        }
    }
}

// MARK: - Previews

private let previewAttrs = TarsyActivityAttributes(
    workspaceId: "p",
    workspaceName: "tarsy-frontend",
    engineType: "Claude Code",
    engineIcon: "brain.head.profile",
    engineIconAsset: "ClaudeIcon"
)

#Preview("Compact — Editing", as: .dynamicIsland(.compact), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Editing", currentToolIcon: "pencil.line", startedAt: Date().timeIntervalSince1970 - 127, contextPercent: 34)
}

#Preview("Compact — Running", as: .dynamicIsland(.compact), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Running", currentToolIcon: "terminal", startedAt: Date().timeIntervalSince1970 - 200, contextPercent: 62)
}

#Preview("Compact — Waiting", as: .dynamicIsland(.compact), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "waiting", currentTool: "Approve changes?", currentToolIcon: "questionmark.circle.fill", startedAt: Date().timeIntervalSince1970 - 45)
}

#Preview("Compact — Error", as: .dynamicIsland(.compact), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "error", currentTool: "Build failed", currentToolIcon: "xmark.circle.fill", startedAt: Date().timeIntervalSince1970 - 300)
}

#Preview("Expanded — Running", as: .dynamicIsland(.expanded), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Writing tests", currentToolIcon: "terminal", startedAt: Date().timeIntervalSince1970 - 312, contextPercent: 45, userPrompt: "Fix the login bug and add unit tests for the auth flow", lastAgentMessage: "Editing AuthManager.swift")
}

#Preview("Expanded — Multi-Agent", as: .dynamicIsland(.expanded), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Editing", currentToolIcon: "pencil.line", startedAt: Date().timeIntervalSince1970 - 600, contextPercent: 87, userPrompt: "Refactor the networking layer", lastAgentMessage: "Reading ConnectionManager.swift", activeAgents: ["Gemini CLI||running||Running tests||terminal", "Aider||waiting||Approve changes?||questionmark.circle"])
}

#Preview("Expanded — Waiting", as: .dynamicIsland(.expanded), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "waiting", currentTool: "Needs input", currentToolIcon: "questionmark.circle.fill", startedAt: Date().timeIntervalSince1970 - 180, contextPercent: 42, message: "Write to hello.txt?", userPrompt: "Create a new hello world file", sessionId: "session-1", engineTypeRaw: "claude", questionKey: "Write to hello.txt?", questionOptions: ["Yes", "No", "Always allow"])
}

#Preview("Expanded — Error", as: .dynamicIsland(.expanded), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "error", currentTool: "Build failed", currentToolIcon: "xmark.circle.fill", startedAt: Date().timeIntervalSince1970 - 600, userPrompt: "Add dark mode support")
}

#Preview("Minimal — Running", as: .dynamicIsland(.minimal), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Editing", currentToolIcon: "pencil.line", startedAt: Date().timeIntervalSince1970 - 90)
}

#Preview("Minimal — Waiting", as: .dynamicIsland(.minimal), using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "waiting", currentTool: "Needs input", currentToolIcon: "questionmark.circle.fill", startedAt: Date().timeIntervalSince1970 - 45)
}

#Preview("Lock Screen — Running", as: .content, using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Editing ContentView.swift", currentToolIcon: "pencil.line", startedAt: Date().timeIntervalSince1970 - 185, contextPercent: 42)
}

#Preview("Lock Screen — High Context", as: .content, using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "running", currentTool: "Running tests", currentToolIcon: "terminal", startedAt: Date().timeIntervalSince1970 - 500, contextPercent: 91)
}

#Preview("Lock Screen — Waiting (Buttons)", as: .content, using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "waiting", currentTool: "Needs input", currentToolIcon: "questionmark.circle.fill", startedAt: Date().timeIntervalSince1970 - 92, contextPercent: 31, message: "Write to hello.txt?", sessionId: "session-1", engineTypeRaw: "claude", questionKey: "Write to hello.txt?", questionOptions: ["Yes", "No", "Always allow"])
}

#Preview("Lock Screen — Error", as: .content, using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "error", currentTool: "Connection lost", currentToolIcon: "xmark.circle.fill", startedAt: Date().timeIntervalSince1970 - 60)
}

#Preview("Lock Screen — Completed", as: .content, using: previewAttrs) {
    TarsyLiveActivityWidget()
} contentStates: {
    TarsyActivityAttributes.ContentState(status: "completed", currentTool: "Done", currentToolIcon: "checkmark.circle", startedAt: Date().timeIntervalSince1970 - 900, contextPercent: 67)
}
