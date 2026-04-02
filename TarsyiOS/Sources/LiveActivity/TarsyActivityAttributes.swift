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
        let pupilX: Double           // Pupil horizontal offset (-1…1), animated between updates
        let pupilY: Double           // Pupil vertical offset (-1…1), animated between updates
        // Interactive permission response fields (populated when status == "waiting")
        let sessionId: String?       // Session to respond to
        let engineTypeRaw: String?   // Engine type raw value for response packet
        let questionKey: String?     // Question text (used as answer dict key)
        let questionOptions: [String]? // Available options for quick-action buttons

        init(status: String, currentTool: String, currentToolIcon: String, startedAt: Double, contextPercent: Double = 0, message: String? = nil, pupilX: Double = 0, pupilY: Double = 0, sessionId: String? = nil, engineTypeRaw: String? = nil, questionKey: String? = nil, questionOptions: [String]? = nil) {
            self.status = status
            self.currentTool = currentTool
            self.currentToolIcon = currentToolIcon
            self.startedAt = startedAt
            self.contextPercent = contextPercent
            self.message = message
            self.pupilX = pupilX
            self.pupilY = pupilY
            self.sessionId = sessionId
            self.engineTypeRaw = engineTypeRaw
            self.questionKey = questionKey
            self.questionOptions = questionOptions
        }
    }
}
