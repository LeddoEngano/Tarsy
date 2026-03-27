import ActivityKit
import Foundation
import TarsyShared

@MainActor
class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()

    /// Active activities indexed by workspace ID
    private var activities: [String: Activity<TarsyActivityAttributes>] = [:]
    /// Start times for elapsed calculation
    private var startTimes: [String: Date] = [:]
    /// Timer for periodic elapsed time updates
    private var updateTimer: Timer?

    private init() {
        startPeriodicUpdates()
    }

    // MARK: - Public API

    func startActivity(workspaceId: String, workspaceName: String, engineType: AIEngineType) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Don't create duplicate
        if activities[workspaceId] != nil { return }

        let attributes = TarsyActivityAttributes(
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            engineType: engineType.displayName,
            engineIcon: engineType.iconName,
            startedAt: Date()
        )

        let state = TarsyActivityAttributes.ContentState(
            status: "running",
            currentTool: "Starting",
            currentToolIcon: "play.circle",
            elapsedSeconds: 0
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            activities[workspaceId] = activity
            startTimes[workspaceId] = Date()
        } catch {
            print("[LiveActivity] Failed to start: \(error)")
        }
    }

    func updateTool(workspaceId: String, tool: AgentToolType) {
        guard let activity = activities[workspaceId],
              let startTime = startTimes[workspaceId] else { return }

        let elapsed = Int(Date().timeIntervalSince(startTime))
        let state = TarsyActivityAttributes.ContentState(
            status: "running",
            currentTool: tool.displayName,
            currentToolIcon: tool.iconName,
            elapsedSeconds: elapsed
        )

        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    func updateStatus(workspaceId: String, status: String) {
        guard let activity = activities[workspaceId],
              let startTime = startTimes[workspaceId] else { return }

        let elapsed = Int(Date().timeIntervalSince(startTime))
        let currentState = activity.content.state

        let state = TarsyActivityAttributes.ContentState(
            status: status,
            currentTool: status == "waiting" ? "Needs input" : currentState.currentTool,
            currentToolIcon: status == "waiting" ? "questionmark.circle" : currentState.currentToolIcon,
            elapsedSeconds: elapsed
        )

        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    func endActivity(workspaceId: String, status: String = "completed") {
        guard let activity = activities[workspaceId],
              let startTime = startTimes[workspaceId] else { return }

        let elapsed = Int(Date().timeIntervalSince(startTime))
        let finalState = TarsyActivityAttributes.ContentState(
            status: status,
            currentTool: status == "error" ? "Failed" : "Done",
            currentToolIcon: status == "error" ? "xmark.circle" : "checkmark.circle",
            elapsedSeconds: elapsed
        )

        Task {
            await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .after(.now + 30))
        }

        activities.removeValue(forKey: workspaceId)
        startTimes.removeValue(forKey: workspaceId)
    }

    func endAllActivities() {
        for (wsId, _) in activities {
            endActivity(workspaceId: wsId)
        }
    }

    var hasActiveActivities: Bool {
        !activities.isEmpty
    }

    // MARK: - Periodic Timer (elapsed time updates)

    private func startPeriodicUpdates() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateAllElapsedTimes()
            }
        }
    }

    private func updateAllElapsedTimes() {
        for (wsId, activity) in activities {
            guard let startTime = startTimes[wsId] else { continue }
            let elapsed = Int(Date().timeIntervalSince(startTime))
            let current = activity.content.state

            let state = TarsyActivityAttributes.ContentState(
                status: current.status,
                currentTool: current.currentTool,
                currentToolIcon: current.currentToolIcon,
                elapsedSeconds: elapsed
            )

            Task {
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
    }
}
