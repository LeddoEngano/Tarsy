import ActivityKit
import AppIntents
import Foundation

private let K = TarsyLiveActivityConstants.self

/// Intent triggered by Live Activity permission buttons (Deny, Allow, Allow All).
/// Runs in the widget extension process WITHOUT opening the app.
/// Writes the response to App Group UserDefaults and signals the main app via Darwin notification.
struct PermissionResponseIntent: AppIntent {
    static var title: LocalizedStringResource = "Respond to Permission"
    static var description: IntentDescription? = "Respond to an AI agent permission request from the Lock Screen"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Session ID")
    var sessionId: String

    @Parameter(title: "Engine Type")
    var engineType: String

    @Parameter(title: "Answer")
    var answer: String

    @Parameter(title: "Workspace ID")
    var workspaceId: String

    init() {}

    init(sessionId: String, engineType: String, answer: String, workspaceId: String) {
        self.sessionId = sessionId
        self.engineType = engineType
        self.answer = answer
        self.workspaceId = workspaceId
    }

    func perform() async throws -> some IntentResult {
        // Immediate visual feedback: update Live Activity to "Resuming"
        for activity in Activity<TarsyActivityAttributes>.activities {
            if activity.attributes.workspaceId == workspaceId {
                let current = activity.content.state
                let newState = TarsyActivityAttributes.ContentState(
                    status: "running",
                    currentTool: "Resuming",
                    currentToolIcon: "arrow.triangle.2.circlepath",
                    startedAt: current.startedAt,
                    contextPercent: current.contextPercent
                )
                await activity.update(.init(state: newState, staleDate: .now.addingTimeInterval(120)))
                break
            }
        }

        // Write response for main app to pick up and send via WebSocket
        // Include a unique ID so the main app can deduplicate rapid taps
        if let defaults = UserDefaults(suiteName: K.appGroup) {
            let response: [String: String] = [
                "sessionId": sessionId,
                "engineType": engineType,
                "answer": answer,
                "workspaceId": workspaceId,
                "responseId": UUID().uuidString,
            ]
            if let data = try? JSONEncoder().encode(response) {
                defaults.set(data, forKey: K.pendingResponseKey)
                defaults.synchronize()
            }
        }

        // Wake up main app via cross-process Darwin notification
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(K.darwinNotificationName as CFString),
            nil, nil, true
        )

        return .result()
    }
}
