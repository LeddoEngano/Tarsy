import Foundation
import TarsyShared
import UserNotifications

class PushNotificationService {
    static let shared = PushNotificationService()

    func sendLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    func notifyTaskComplete(workspace: String, summary: String, workspaceId: String? = nil) {
        sendLocalNotification(
            title: "Tarsy - \(workspace)",
            body: summary
        )

        Task {
            await sendRemotePush(title: "Tarsy - \(workspace)", body: summary, workspaceId: workspaceId)
        }
    }

    func notifyPRCreated(workspace: String, prNumber: String, workspaceId: String? = nil) {
        sendLocalNotification(
            title: "Tarsy - \(workspace)",
            body: "PR #\(prNumber) created"
        )

        Task {
            await sendRemotePush(title: "Tarsy - \(workspace)", body: "PR #\(prNumber) created", workspaceId: workspaceId)
        }
    }

    func notifyAgentQuestion(workspace: String, question: String, workspaceId: String? = nil) {
        let body = question.prefix(100).description + (question.count > 100 ? "..." : "")
        sendLocalNotification(
            title: "Tarsy - \(workspace) needs input",
            body: body
        )

        Task {
            await sendRemotePush(
                title: "Tarsy - \(workspace)",
                body: "Agent needs your input: \(body)",
                workspaceId: workspaceId
            )
        }
    }

    func notifyError(workspace: String, error: String, workspaceId: String? = nil) {
        sendLocalNotification(
            title: "Tarsy - \(workspace)",
            body: "Error: \(error)"
        )

        Task {
            await sendRemotePush(
                title: "Tarsy - \(workspace)",
                body: "Error: \(error)",
                workspaceId: workspaceId
            )
        }
    }

    // MARK: - Live Activity Push Updates

    func sendLiveActivityUpdate(
        workspaceId: String,
        contentState: [String: Any],
        event: String = "update",
        alert: [String: String]? = nil
    ) async {
        do {
            let userId = try await supabase.auth.session.user.id.uuidString
            var body: [String: Any] = [
                "user_id": userId,
                "workspace_id": workspaceId,
                "content_state": contentState,
                "event": event
            ]
            if let alert { body["alert"] = alert }
            if event == "end" {
                body["dismissal_date"] = Int(Date().timeIntervalSince1970) + 60
            }
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            try await supabase.functions.invoke(
                "update-live-activity",
                options: .init(body: jsonData)
            )
        } catch {
            print("[Push] Live Activity update failed: \(error)")
        }
    }

    private func sendRemotePush(title: String, body: String, workspaceId: String? = nil) async {
        do {
            var payload: [String: String] = [
                "title": title,
                "body": body
            ]
            if let wsId = workspaceId {
                payload["workspace_id"] = wsId
            }
            try await supabase
                .from("push_notifications")
                .insert(payload)
                .execute()
        } catch {
            print("[Push] Failed to send remote push: \(error)")
        }
    }
}
