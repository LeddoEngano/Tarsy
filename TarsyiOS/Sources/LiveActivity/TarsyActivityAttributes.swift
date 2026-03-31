import ActivityKit
import Foundation

struct TarsyActivityAttributes: ActivityAttributes {
    /// Fixed data that doesn't change during the activity
    let workspaceId: String
    let workspaceName: String
    let engineType: String
    let engineIcon: String

    /// Dynamic data that updates during the activity
    struct ContentState: Codable, Hashable {
        let status: String           // "running", "waiting", "completed", "error"
        let currentTool: String      // Tool display name (e.g., "Editing")
        let currentToolIcon: String  // SF Symbol name
        let startedAt: Double        // Unix timestamp (timeIntervalSince1970) — Double for APNs JSON compatibility
        let contextPercent: Double   // 0–100, context window usage
        let message: String?         // Optional detail (e.g., waiting question text)

        init(status: String, currentTool: String, currentToolIcon: String, startedAt: Double, contextPercent: Double = 0, message: String? = nil) {
            self.status = status
            self.currentTool = currentTool
            self.currentToolIcon = currentToolIcon
            self.startedAt = startedAt
            self.contextPercent = contextPercent
            self.message = message
        }
    }
}
