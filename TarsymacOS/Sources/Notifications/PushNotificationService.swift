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

    func notifyTaskComplete(workspace: String, summary: String) {
        sendLocalNotification(
            title: "Tarsy - \(workspace)",
            body: summary
        )

        // Also push to Supabase for iOS delivery
        Task {
            await sendRemotePush(title: "Tarsy - \(workspace)", body: summary)
        }
    }

    func notifyPRCreated(workspace: String, prNumber: String) {
        sendLocalNotification(
            title: "Tarsy - \(workspace)",
            body: "PR #\(prNumber) created"
        )

        Task {
            await sendRemotePush(title: "Tarsy - \(workspace)", body: "PR #\(prNumber) created")
        }
    }

    func notifyError(workspace: String, error: String) {
        sendLocalNotification(
            title: "Tarsy - \(workspace)",
            body: "Error: \(error)"
        )
    }

    private func sendRemotePush(title: String, body: String) async {
        // Insert into a notifications table that triggers a Supabase Edge Function
        // The Edge Function sends APNs to all registered iOS devices
        do {
            try await supabase
                .from("push_notifications")
                .insert([
                    "title": title,
                    "body": body
                ])
                .execute()
        } catch {
            print("[Push] Failed to send remote push: \(error)")
        }
    }
}
