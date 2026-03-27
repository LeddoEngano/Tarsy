import ActivityKit
import Foundation

struct TarsyActivityAttributes: ActivityAttributes {
    /// Fixed data that doesn't change during the activity
    let workspaceId: String
    let workspaceName: String
    let engineType: String
    let engineIcon: String
    let startedAt: Date

    /// Dynamic data that updates during the activity
    struct ContentState: Codable, Hashable {
        let status: String           // "running", "waiting", "completed", "error"
        let currentTool: String      // Tool display name (e.g., "Editing")
        let currentToolIcon: String  // SF Symbol name
        let elapsedSeconds: Int
    }
}
