import ActivityKit
import Foundation
import TarsyShared

@MainActor
class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()

    /// Active activities indexed by activityKey (workspaceId-tabId)
    private var activities: [String: Activity<TarsyActivityAttributes>] = [:]
    /// Start times per activity
    private var startDates: [String: Date] = [:]

    private init() {}

    // MARK: - Keys

    /// Activity key scoped to workspace + tab so multiple agents don't collide
    private func key(workspaceId: String, tabId: String? = nil) -> String {
        if let tabId { return "\(workspaceId)-\(tabId)" }
        return workspaceId
    }

    // MARK: - Public API

    func startActivity(workspaceId: String, workspaceName: String, engineType: AIEngineType, tabId: String? = nil) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let activityKey = key(workspaceId: workspaceId, tabId: tabId)

        // Don't create duplicate
        if activities[activityKey] != nil { return }

        let now = Date()
        let attributes = TarsyActivityAttributes(
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            engineType: engineType.displayName,
            engineIcon: engineType.iconName
        )

        let state = TarsyActivityAttributes.ContentState(
            status: "running",
            currentTool: "Starting",
            currentToolIcon: "play.circle",
            startedAt: now
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            activities[activityKey] = activity
            startDates[activityKey] = now
        } catch {
            print("[LiveActivity] Failed to start: \(error)")
        }
    }

    func updateTool(workspaceId: String, tool: AgentToolType, tabId: String? = nil) {
        let activityKey = key(workspaceId: workspaceId, tabId: tabId)
        guard let activity = activities[activityKey],
              let startDate = startDates[activityKey] else { return }

        let state = TarsyActivityAttributes.ContentState(
            status: "running",
            currentTool: tool.displayName,
            currentToolIcon: tool.iconName,
            startedAt: startDate
        )

        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func updateStatus(workspaceId: String, status: String, tabId: String? = nil) {
        let activityKey = key(workspaceId: workspaceId, tabId: tabId)
        guard let activity = activities[activityKey],
              let startDate = startDates[activityKey] else { return }

        let currentState = activity.content.state
        let state = TarsyActivityAttributes.ContentState(
            status: status,
            currentTool: status == "waiting" ? "Needs input" : currentState.currentTool,
            currentToolIcon: status == "waiting" ? "questionmark.circle" : currentState.currentToolIcon,
            startedAt: startDate
        )

        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func endActivity(workspaceId: String, status: String = "completed", tabId: String? = nil) {
        let activityKey = key(workspaceId: workspaceId, tabId: tabId)
        guard let activity = activities[activityKey],
              let startDate = startDates[activityKey] else { return }

        let finalState = TarsyActivityAttributes.ContentState(
            status: status,
            currentTool: status == "error" ? "Failed" : "Done",
            currentToolIcon: status == "error" ? "xmark.circle" : "checkmark.circle",
            startedAt: startDate
        )

        Task { await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .after(.now + 60)) }

        activities.removeValue(forKey: activityKey)
        startDates.removeValue(forKey: activityKey)
    }

    /// End all activities for a workspace (e.g., when user leaves the workspace view)
    func endActivitiesForWorkspace(_ workspaceId: String) {
        let keysToEnd = activities.keys.filter { $0.hasPrefix(workspaceId) }
        for k in keysToEnd {
            if let activity = activities[k], let startDate = startDates[k] {
                let finalState = TarsyActivityAttributes.ContentState(
                    status: "completed",
                    currentTool: "Done",
                    currentToolIcon: "checkmark.circle",
                    startedAt: startDate
                )
                Task { await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .default) }
            }
            activities.removeValue(forKey: k)
            startDates.removeValue(forKey: k)
        }
    }

    func endAllActivities() {
        for (key, activity) in activities {
            let startDate = startDates[key] ?? Date()
            let state = TarsyActivityAttributes.ContentState(
                status: "completed", currentTool: "Done", currentToolIcon: "checkmark.circle", startedAt: startDate
            )
            Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .default) }
        }
        activities.removeAll()
        startDates.removeAll()
    }

    var hasActiveActivities: Bool {
        !activities.isEmpty
    }
}
