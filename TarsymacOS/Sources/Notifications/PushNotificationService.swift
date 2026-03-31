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

    /// Encodable wrapper for Live Activity push payloads
    private struct LAUpdateBody: Encodable {
        let user_id: String
        let workspace_id: String
        let content_state: LAContentState
        let event: String
        let alert: [String: String]?
        let dismissal_date: Int?
    }

    private struct LAContentState: Encodable {
        let status: String
        let currentTool: String
        let currentToolIcon: String
        let startedAt: Double
        let contextPercent: Double
        let message: String?
    }

    func sendLiveActivityUpdate(
        workspaceId: String,
        contentState: [String: Any],
        event: String = "update",
        alert: [String: String]? = nil
    ) async {
        do {
            let userId = try await supabase.auth.session.user.id.uuidString

            let state = LAContentState(
                status: contentState["status"] as? String ?? "running",
                currentTool: contentState["currentTool"] as? String ?? "Working",
                currentToolIcon: contentState["currentToolIcon"] as? String ?? "wrench",
                startedAt: contentState["startedAt"] as? Double ?? Date().timeIntervalSince1970,
                contextPercent: contentState["contextPercent"] as? Double ?? 0,
                message: contentState["message"] as? String
            )

            let body = LAUpdateBody(
                user_id: userId,
                workspace_id: workspaceId,
                content_state: state,
                event: event,
                alert: alert,
                dismissal_date: event == "end" ? Int(Date().timeIntervalSince1970) + 60 : nil
            )

            try await supabase.functions.invoke(
                "update-live-activity",
                options: .init(body: body)
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
