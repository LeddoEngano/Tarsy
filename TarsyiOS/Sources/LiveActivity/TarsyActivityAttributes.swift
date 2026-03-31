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
        let startedAt: Date          // Used by Text(date, style: .timer) for live countdown
        let contextPercent: Double   // 0–100, context window usage
        let message: String?         // Optional detail (e.g., waiting question text)

        init(status: String, currentTool: String, currentToolIcon: String, startedAt: Date, contextPercent: Double = 0, message: String? = nil) {
            self.status = status
            self.currentTool = currentTool
            self.currentToolIcon = currentToolIcon
            self.startedAt = startedAt
            self.contextPercent = contextPercent
            self.message = message
        }
    }
}
