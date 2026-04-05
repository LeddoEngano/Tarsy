import ActivityKit
import Foundation

/// Shared constants for widget ↔ app communication (this file compiles in both targets)
enum TarsyLiveActivityConstants {
    static let appGroup = "group.com.tarsy.ios"
    static let pendingResponseKey = "pendingPermissionResponse"
    static let darwinNotificationName = "com.tarsy.ios.permissionResponse"
}

struct TarsyActivityAttributes: ActivityAttributes {
    /// Fixed data that doesn't change during the activity
    let workspaceId: String
    let workspaceName: String
    let engineType: String
    let engineIcon: String       // SF Symbol fallback
    let engineIconAsset: String? // Asset catalog image name (e.g., "ClaudeIcon")

    /// Dynamic data that updates during the activity
    struct ContentState: Codable, Hashable {
        let status: String           // "running", "waiting", "completed", "error"
        let currentTool: String      // Tool display name (e.g., "Editing")
        let currentToolIcon: String  // SF Symbol name
        let startedAt: Double        // Unix timestamp (timeIntervalSince1970) — Double for APNs JSON compatibility
        let contextPercent: Double   // 0–100, context window usage
        let message: String?         // Optional detail (e.g., waiting question text)
        let userPrompt: String?      // The user's last prompt message
        let lastAgentMessage: String? // Last message from the agent
        let activeAgents: [String]?  // Other active agents (e.g., "Claude Code · Writing tests")
        // Interactive permission response fields (populated when status == "waiting")
        let sessionId: String?       // Session to respond to
        let engineTypeRaw: String?   // Engine type raw value for response packet
        let questionKey: String?     // Question text (used as answer dict key)
        let questionOptions: [String]? // Available options for quick-action buttons
        let permissionRequestId: String? // Control protocol request ID (for permission responses)

        init(status: String, currentTool: String, currentToolIcon: String, startedAt: Double, contextPercent: Double = 0, message: String? = nil, userPrompt: String? = nil, lastAgentMessage: String? = nil, activeAgents: [String]? = nil, sessionId: String? = nil, engineTypeRaw: String? = nil, questionKey: String? = nil, questionOptions: [String]? = nil, permissionRequestId: String? = nil) {
            self.status = status
            self.currentTool = currentTool
            self.currentToolIcon = currentToolIcon
            self.startedAt = startedAt
            self.contextPercent = contextPercent
            self.message = message
            self.userPrompt = userPrompt
            self.lastAgentMessage = lastAgentMessage
            self.activeAgents = activeAgents
            self.sessionId = sessionId
            self.engineTypeRaw = engineTypeRaw
            self.questionKey = questionKey
            self.questionOptions = questionOptions
            self.permissionRequestId = permissionRequestId
        }
    }
}
