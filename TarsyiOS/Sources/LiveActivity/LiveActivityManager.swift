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
    /// Tracked user prompts per activity
    private var userPrompts: [String: String] = [:]
    /// Tracked last agent messages per activity
    private var lastAgentMessages: [String: String] = [:]

    /// Activities go stale after this interval without updates, triggering the "Updating…" fallback UI
    private let staleTTL: TimeInterval = 120

    private init() {}

    // MARK: - Keys

    /// Activity key scoped to workspace + tab so multiple agents don't collide
    private func key(workspaceId: String, tabId: String? = nil) -> String {
        if let tabId { return "\(workspaceId)-\(tabId)" }
        return workspaceId
    }

    /// Returns a summary of all active agents except the one with the given key.
    /// Format: "engineName||status||toolName||toolIcon" per entry.
    private func activeAgentsSummary(excluding activityKey: String) -> [String]? {
        let others = activities.filter { $0.key != activityKey }.compactMap { (_, activity) -> String? in
            let state = activity.content.state
            guard state.status == "running" || state.status == "waiting" else { return nil }
            return "\(activity.attributes.engineType)||\(state.status)||\(state.currentTool)||\(state.currentToolIcon)"
        }
        return others.isEmpty ? nil : others
    }

    // MARK: - Public API

    func startActivity(workspaceId: String, workspaceName: String, engineType: AIEngineType, tabId: String? = nil) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let activityKey = key(workspaceId: workspaceId, tabId: tabId)

        // Don't create duplicate
        if activities[activityKey] != nil { return }

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
            engineIcon: engineType.iconName,
            engineIconAsset: engineType.iconAsset
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

            // Observe push token updates and store in Supabase for APNs Live Activity pushes
            Task {
                for await tokenData in activity.pushTokenUpdates {
                    let token = tokenData.map { String(format: "%02x", $0) }.joined()
                    await self.storeLiveActivityToken(token, workspaceId: workspaceId)
                }
            }
        } catch {
#if DEBUG
            print("[LiveActivity] Failed to start: \(error)")
#endif
        }
    }

    func updateTool(workspaceId: String, tool: AgentToolType, tabId: String? = nil, contextPercent: Double? = nil) {
        let activityKey = key(workspaceId: workspaceId, tabId: tabId)
        guard let activity = activities[activityKey],
              let startDate = startDates[activityKey] else { return }

        if let cp = contextPercent { contextPercents[activityKey] = cp }
        let cp = contextPercents[activityKey] ?? 0

        let state = TarsyActivityAttributes.ContentState(
            status: "running",
            currentTool: tool.displayName,
            currentToolIcon: tool.iconName,
            startedAt: startDate,
            contextPercent: cp,
            userPrompt: userPrompts[activityKey],
            lastAgentMessage: lastAgentMessages[activityKey],
            activeAgents: activeAgentsSummary(excluding: activityKey)
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
            message: currentState.message,
            userPrompt: userPrompts[activityKey],
            lastAgentMessage: lastAgentMessages[activityKey],
            activeAgents: activeAgentsSummary(excluding: activityKey)
        )

        Task { await activity.update(.init(state: state, staleDate: .now.addingTimeInterval(staleTTL))) }
    }

    func updateUserPrompt(workspaceId: String, prompt: String, tabId: String? = nil) {
        let activityKey = key(workspaceId: workspaceId, tabId: tabId)
        userPrompts[activityKey] = prompt
    }

    func updateLastAgentMessage(workspaceId: String, message: String, tabId: String? = nil) {
        let activityKey = key(workspaceId: workspaceId, tabId: tabId)
        lastAgentMessages[activityKey] = message
    }

    func updateStatus(workspaceId: String, status: String, tabId: String? = nil, message: String? = nil, sessionId: String? = nil, engineType: String? = nil, questionKey: String? = nil, questionOptions: [String]? = nil, permissionRequestId: String? = nil) {
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
            message: status == "waiting" ? message : nil,
            userPrompt: userPrompts[activityKey],
            lastAgentMessage: lastAgentMessages[activityKey],
            activeAgents: activeAgentsSummary(excluding: activityKey),
            sessionId: status == "waiting" ? sessionId : nil,
            engineTypeRaw: status == "waiting" ? engineType : nil,
            questionKey: status == "waiting" ? questionKey : nil,
            questionOptions: status == "waiting" ? questionOptions : nil,
            permissionRequestId: status == "waiting" ? permissionRequestId : nil
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
            userPrompts.removeValue(forKey: activityKey)
            lastAgentMessages.removeValue(forKey: activityKey)

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
            userPrompts.removeValue(forKey: k)
            lastAgentMessages.removeValue(forKey: k)
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
        userPrompts.removeAll()
        lastAgentMessages.removeAll()

        for activity in Activity<TarsyActivityAttributes>.activities {
            guard activity.activityState == .active || activity.activityState == .stale else { continue }
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }

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

    // MARK: - Widget Permission Response Observer

    /// Callback invoked when a permission response arrives from the Live Activity widget buttons.
    /// Set this from the app root to forward responses via WebSocket.
    /// Parameters: (sessionId, answer, engineType, workspaceId, permissionRequestId?)
    var onPermissionResponse: ((String, String, String, String, String?) -> Void)?

    private var darwinObserverRegistered = false

    private let appGroupId = TarsyLiveActivityConstants.appGroup
    private let pendingResponseKey = TarsyLiveActivityConstants.pendingResponseKey
    /// Tracks the last processed response ID to deduplicate rapid taps
    private var lastProcessedResponseId: String?

    /// Start observing Darwin notifications from the widget extension.
    /// Call once from the app root after setting `onPermissionResponse`.
    func startWidgetResponseObserver() {
        guard !darwinObserverRegistered else { return }
        darwinObserverRegistered = true

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            Self.darwinCallback,
            TarsyLiveActivityConstants.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )

        // Check for any pending response from a previous widget interaction
        // (e.g., if the app was killed when the user tapped a button)
        processWidgetResponse()
    }

    /// C-function callback for Darwin notification — dispatches to MainActor
    private static let darwinCallback: CFNotificationCallback = { _, _, _, _, _ in
        Task { @MainActor in
            LiveActivityManager.shared.processWidgetResponse()
        }
    }

    /// Read a pending permission response from App Group UserDefaults,
    /// update the Live Activity, and forward via the `onPermissionResponse` callback.
    func processWidgetResponse() {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = defaults.data(forKey: pendingResponseKey),
              let response = try? JSONDecoder().decode([String: String].self, from: data),
              let sessionId = response["sessionId"],
              let answer = response["answer"],
              let engineType = response["engineType"],
              let workspaceId = response["workspaceId"] else { return }

        // Deduplicate: skip if we already processed this exact response
        let responseId = response["responseId"] ?? ""
        if !responseId.isEmpty && responseId == lastProcessedResponseId { return }
        lastProcessedResponseId = responseId

        // Clear the pending response immediately to prevent double-processing
        defaults.removeObject(forKey: pendingResponseKey)
        defaults.synchronize()

        // Update Live Activity back to "running" — find by workspaceId prefix
        // since we don't have the tabId in the widget response
        for activityKey in activities.keys where activityKey.hasPrefix(workspaceId) {
            guard let activity = activities[activityKey],
                  let startDate = startDates[activityKey] else { continue }
            let cp = contextPercents[activityKey] ?? 0
            let state = TarsyActivityAttributes.ContentState(
                status: "running",
                currentTool: "Resuming",
                currentToolIcon: "arrow.triangle.2.circlepath",
                startedAt: startDate,
                contextPercent: cp
            )
            Task { await activity.update(.init(state: state, staleDate: .now.addingTimeInterval(staleTTL))) }
        }

        // Forward the response to the WebSocket connection
        let permissionRequestId = response["permissionRequestId"]
        onPermissionResponse?(sessionId, answer, engineType, workspaceId, permissionRequestId)

        // Notify in-app UI (WorkspaceView) to clear the question overlay
        NotificationCenter.default.post(
            name: .widgetPermissionResponseProcessed,
            object: nil,
            userInfo: [
                "workspaceId": workspaceId,
                "sessionId": sessionId,
            ]
        )

#if DEBUG
        print("[LiveActivity] Processed widget permission response: \(answer) for session \(sessionId)")
#endif
    }
}

extension Notification.Name {
    /// Posted when a permission response from the Live Activity widget has been processed.
    /// userInfo contains "workspaceId" and "sessionId".
    static let widgetPermissionResponseProcessed = Notification.Name("widgetPermissionResponseProcessed")
}
