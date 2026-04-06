import ActivityKit
import AppIntents
import Foundation

private let K = TarsyLiveActivityConstants.self
private let RELAY_URL = "https://tarsy-relay.fly.dev/api/permission-response"

/// Intent triggered by Live Activity permission buttons (Deny, Allow, Allow All).
/// Runs in the widget extension process WITHOUT opening the app.
/// Sends the response directly to the relay server via HTTP POST,
/// bypassing the main app's WebSocket connection entirely.
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

    @Parameter(title: "Permission Request ID")
    var permissionRequestId: String

    init() {}

    init(sessionId: String, engineType: String, answer: String, workspaceId: String, permissionRequestId: String = "") {
        self.sessionId = sessionId
        self.engineType = engineType
        self.answer = answer
        self.workspaceId = workspaceId
        self.permissionRequestId = permissionRequestId
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

        // Try sending directly to relay via HTTP POST
        let sent = await sendToRelay()

        if !sent {
            // Fallback: write to App Group for main app to pick up
            fallbackToAppGroup()
        }

        return .result()
    }

    /// Send the permission response directly to the relay server via HTTP POST.
    /// Returns true if the response was delivered to the machine.
    private func sendToRelay() async -> Bool {
        // Read auth token from App Group (synced by main app)
        guard let defaults = UserDefaults(suiteName: K.appGroup),
              let token = defaults.string(forKey: "widgetAuthToken"),
              !token.isEmpty else {
            return false
        }

        var body: [String: String] = [
            "sessionId": sessionId,
            "answer": answer,
            "engineType": engineType,
            "workspaceId": workspaceId,
        ]
        if !permissionRequestId.isEmpty {
            body["permissionRequestId"] = permissionRequestId
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return false }

        var request = URLRequest(url: URL(string: RELAY_URL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                return true
            }
            // Parse error for debugging
#if DEBUG
            let responseStr = String(data: data, encoding: .utf8) ?? "?"
            print("[Widget] Relay HTTP response: \(responseStr)")
#endif
            return false
        } catch {
#if DEBUG
            print("[Widget] Relay HTTP error: \(error)")
#endif
            return false
        }
    }

    /// Fallback: write response to App Group UserDefaults for main app to pick up
    /// when it returns to foreground.
    private func fallbackToAppGroup() {
        guard let defaults = UserDefaults(suiteName: K.appGroup) else { return }
        var response: [String: String] = [
            "sessionId": sessionId,
            "engineType": engineType,
            "answer": answer,
            "workspaceId": workspaceId,
            "responseId": UUID().uuidString,
        ]
        if !permissionRequestId.isEmpty {
            response["permissionRequestId"] = permissionRequestId
        }
        if let data = try? JSONEncoder().encode(response) {
            defaults.set(data, forKey: K.pendingResponseKey)
            defaults.synchronize()
        }

        // Wake up main app via Darwin notification
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(K.darwinNotificationName as CFString),
            nil, nil, true
        )
    }
}
