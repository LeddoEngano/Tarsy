import ActivityKit
import Foundation
import TarsyShared

@MainActor
class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()

    /// Active activities indexed by activityKey (workspaceId-tabId)
    private var activities: [String: Activity<TarsyActivityAttributes>] = [:]
    /// Start times per activity (Unix timestamps)
    private var startDates: [String: Double] = [:]
    /// Tracked context percent per activity
    private var contextPercents: [String: Double] = [:]

    /// Activities go stale after this interval without updates, triggering the "Updating…" fallback UI
    private let staleTTL: TimeInterval = 120

    private init() {}

    // MARK: - Keys

    /// Activity key scoped to workspace + tab so multiple agents don't collide
    private func key(workspaceId: String, tabId: String? = nil) -> String {
        if let tabId { return "\(workspaceId)-\(tabId)" }
        return workspaceId
    }

    // MARK: - Public API

    func startActivity(workspaceId: String, workspaceName: String, engineType: AIEngineType, tabId: String? = nil) {
        print("[LA] startActivity wsId=\(workspaceId.prefix(8)) tab=\(tabId ?? "nil") engine=\(engineType.rawValue)")
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LA] ❌ Activities NOT enabled on device")
            return
        }

        let activityKey = key(workspaceId: workspaceId, tabId: tabId)

        // Don't create duplicate
        if activities[activityKey] != nil {
            print("[LA] ⚠️ Duplicate — activity already exists for key=\(activityKey.prefix(16))")
            return
        }

        // Clean up zombie activities from previous sessions before creating new one
        let knownIds = Set(activities.values.map(\.id))
        for zombie in Activity<TarsyActivityAttributes>.activities where !knownIds.contains(zombie.id) {
            Task { await zombie.end(nil, dismissalPolicy: .immediate) }
        }

        let now = Date().timeIntervalSince1970
        let attributes = TarsyActivityAttributes(
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            engineType: engineType.displayName,
            engineIcon: engineType.iconName
        )

        let state = TarsyActivityAttributes.ContentState(
            status: "running",
            currentTool: "Starting",
            currentToolIcon: "arrow.triangle.2.circlepath",
            startedAt: now
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: .now.addingTimeInterval(staleTTL)),
                pushType: .token
            )
            activities[activityKey] = activity
            startDates[activityKey] = now
            contextPercents[activityKey] = 0
            print("[LA] ✅ Activity STARTED id=\(activity.id) key=\(activityKey.prefix(16)) pushType=token")

            // Observe push token updates and store in Supabase for APNs Live Activity pushes
            Task {
                for await tokenData in activity.pushTokenUpdates {
                    let token = tokenData.map { String(format: "%02x", $0) }.joined()
                    print("[LA] 🔑 Push token received: \(token.prefix(16))... for ws=\(workspaceId.prefix(8))")
                    await self.storeLiveActivityToken(token, workspaceId: workspaceId)
                }
                print("[LA] pushTokenUpdates stream ended for key=\(activityKey.prefix(16))")
            }
        } catch {
            print("[LA] ❌ Failed to start activity: \(error)")
        }
    }

    func updateTool(workspaceId: String, tool: AgentToolType, tabId: String? = nil, contextPercent: Double? = nil) {
        let activityKey = key(workspaceId: workspaceId, tabId: tabId)
        guard let activity = activities[activityKey],
              let startDate = startDates[activityKey] else {
            print("[LA] ⚠️ updateTool SKIPPED — no activity for key=\(activityKey.prefix(16)) tool=\(tool.displayName) (tracked keys: \(activities.keys.map { String($0.prefix(16)) }))")
            return
        }
        print("[LA] updateTool key=\(activityKey.prefix(16)) tool=\(tool.displayName)")

        if let cp = contextPercent { contextPercents[activityKey] = cp }
        let cp = contextPercents[activityKey] ?? 0

        let state = TarsyActivityAttributes.ContentState(
            status: "running",
            currentTool: tool.displayName,
            currentToolIcon: tool.iconName,
            startedAt: startDate,
            contextPercent: cp
        )

        Task { await activity.update(.init(state: state, staleDate: .now.addingTimeInterval(staleTTL))) }
    }

    func updateContext(workspaceId: String, contextPercent: Double, tabId: String? = nil) {
        let activityKey = key(workspaceId: workspaceId, tabId: tabId)
        contextPercents[activityKey] = contextPercent

        guard let activity = activities[activityKey],
              let startDate = startDates[activityKey] else { return }

        let currentState = activity.content.state
        let state = TarsyActivityAttributes.ContentState(
            status: currentState.status,
            currentTool: currentState.currentTool,
            currentToolIcon: currentState.currentToolIcon,
            startedAt: startDate,
            contextPercent: contextPercent,
            message: currentState.message
        )

        Task { await activity.update(.init(state: state, staleDate: .now.addingTimeInterval(staleTTL))) }
    }

    func updateStatus(workspaceId: String, status: String, tabId: String? = nil, message: String? = nil) {
        let activityKey = key(workspaceId: workspaceId, tabId: tabId)
        guard let activity = activities[activityKey],
              let startDate = startDates[activityKey] else { return }

        let cp = contextPercents[activityKey] ?? 0
        let currentState = activity.content.state
        let state = TarsyActivityAttributes.ContentState(
            status: status,
            currentTool: status == "waiting" ? "Needs input" : currentState.currentTool,
            currentToolIcon: status == "waiting" ? "questionmark.circle" : currentState.currentToolIcon,
            startedAt: startDate,
            contextPercent: cp,
            message: status == "waiting" ? message : nil
        )

        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(staleTTL))

        Task {
            if status == "waiting" {
                await activity.update(content, alertConfiguration: .init(
                    title: LocalizedStringResource(stringLiteral: "Tarsy"),
                    body: LocalizedStringResource(stringLiteral: message ?? "Your agent needs input"),
                    sound: .default
                ))
            } else {
                await activity.update(content)
            }
        }
    }

    func endActivity(workspaceId: String, status: String = "completed", tabId: String? = nil) {
        let activityKey = key(workspaceId: workspaceId, tabId: tabId)

        if let activity = activities[activityKey] {
            let startDate = startDates[activityKey] ?? activity.content.state.startedAt
            let cp = contextPercents[activityKey] ?? 0
            let finalState = TarsyActivityAttributes.ContentState(
                status: status,
                currentTool: status == "error" ? "Failed" : "Done",
                currentToolIcon: status == "error" ? "xmark.circle" : "checkmark.circle",
                startedAt: startDate,
                contextPercent: cp
            )
            Task {
                let alertBody = status == "error" ? "Agent encountered an error" : "Agent task completed"
                await activity.update(
                    .init(state: finalState, staleDate: nil),
                    alertConfiguration: .init(
                        title: LocalizedStringResource(stringLiteral: "Tarsy"),
                        body: LocalizedStringResource(stringLiteral: alertBody),
                        sound: .default
                    )
                )
                await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .after(.now + 60))
            }
            activities.removeValue(forKey: activityKey)
            startDates.removeValue(forKey: activityKey)
            contextPercents.removeValue(forKey: activityKey)

            // Clean up push token from Supabase
            Task { await removeLiveActivityToken(workspaceId: workspaceId) }
            return
        }

        // Fallback: find matching activity directly from the system
        for activity in Activity<TarsyActivityAttributes>.activities {
            if activity.attributes.workspaceId == workspaceId,
               activity.activityState == .active || activity.activityState == .stale {
                let finalState = TarsyActivityAttributes.ContentState(
                    status: status,
                    currentTool: status == "error" ? "Failed" : "Done",
                    currentToolIcon: status == "error" ? "xmark.circle" : "checkmark.circle",
                    startedAt: activity.content.state.startedAt,
                    contextPercent: activity.content.state.contextPercent
                )
                Task { await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .after(.now + 60)) }
            }
        }
        Task { await removeLiveActivityToken(workspaceId: workspaceId) }
    }

    func endActivitiesForWorkspace(_ workspaceId: String) {
        let keysToEnd = activities.keys.filter { $0.hasPrefix(workspaceId) }
        for k in keysToEnd {
            if let activity = activities[k], let startDate = startDates[k] {
                let finalState = TarsyActivityAttributes.ContentState(
                    status: "completed",
                    currentTool: "Done",
                    currentToolIcon: "checkmark.circle",
                    startedAt: startDate,
                    contextPercent: contextPercents[k] ?? 0
                )
                Task { await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .default) }
            }
            activities.removeValue(forKey: k)
            startDates.removeValue(forKey: k)
            contextPercents.removeValue(forKey: k)
        }

        for activity in Activity<TarsyActivityAttributes>.activities {
            if activity.attributes.workspaceId == workspaceId,
               activity.activityState == .active || activity.activityState == .stale {
                let finalState = TarsyActivityAttributes.ContentState(
                    status: "completed",
                    currentTool: "Done",
                    currentToolIcon: "checkmark.circle",
                    startedAt: activity.content.state.startedAt,
                    contextPercent: activity.content.state.contextPercent
                )
                Task { await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .default) }
            }
        }
        Task { await removeLiveActivityToken(workspaceId: workspaceId) }
    }

    func endAllActivities() {
        for (key, activity) in activities {
            let startDate = startDates[key] ?? Date().timeIntervalSince1970
            let state = TarsyActivityAttributes.ContentState(
                status: "completed", currentTool: "Done", currentToolIcon: "checkmark.circle",
                startedAt: startDate, contextPercent: contextPercents[key] ?? 0
            )
            Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .default) }
        }
        activities.removeAll()
        startDates.removeAll()
        contextPercents.removeAll()

        for activity in Activity<TarsyActivityAttributes>.activities {
            guard activity.activityState == .active || activity.activityState == .stale else { continue }
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }

        // Clean up all tokens
        Task { await removeAllLiveActivityTokens() }
    }

    var hasActiveActivities: Bool {
        !activities.isEmpty || !Activity<TarsyActivityAttributes>.activities.filter({
            $0.activityState == .active || $0.activityState == .stale
        }).isEmpty
    }

    // MARK: - Push Token Management

    private func storeLiveActivityToken(_ token: String, workspaceId: String) async {
        do {
            let userId = try await supabase.auth.session.user.id.uuidString
            try await supabase
                .from("live_activity_tokens")
                .upsert(
                    [
                        "user_id": userId,
                        "workspace_id": workspaceId,
                        "activity_token": token,
                        "updated_at": ISO8601DateFormatter().string(from: Date())
                    ],
                    onConflict: "activity_token"
                )
                .execute()
#if DEBUG
            print("[LiveActivity] Stored push token \(token.prefix(8))... for workspace \(workspaceId.prefix(8))")
#endif
        } catch {
#if DEBUG
            print("[LiveActivity] Failed to store push token: \(error)")
#endif
        }
    }

    private func removeLiveActivityToken(workspaceId: String) async {
        do {
            let userId = try await supabase.auth.session.user.id.uuidString
            try await supabase
                .from("live_activity_tokens")
                .delete()
                .eq("user_id", value: userId)
                .eq("workspace_id", value: workspaceId)
                .execute()
        } catch {
#if DEBUG
            print("[LiveActivity] Failed to remove push token: \(error)")
#endif
        }
    }

    private func removeAllLiveActivityTokens() async {
        do {
            let userId = try await supabase.auth.session.user.id.uuidString
            try await supabase
                .from("live_activity_tokens")
                .delete()
                .eq("user_id", value: userId)
                .execute()
        } catch {
#if DEBUG
            print("[LiveActivity] Failed to remove all push tokens: \(error)")
#endif
        }
    }
}
