import Foundation

public struct AgentTask: Codable, Identifiable, Sendable {
    public let id: UUID
    public let userId: UUID
    public let workspaceId: UUID
    public let tabId: String
    public let description: String
    public var status: TaskStatus
    public var sessionId: String?
    public var engineType: String?
    public var errorMessage: String?
    public let createdAt: Date
    public var updatedAt: Date

    public enum TaskStatus: String, Codable, Sendable {
        case running
        case waiting
        case completed
        case error
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case workspaceId = "workspace_id"
        case tabId = "tab_id"
        case description
        case status
        case sessionId = "session_id"
        case engineType = "engine_type"
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID = UUID(),
        userId: UUID,
        workspaceId: UUID,
        tabId: String,
        description: String,
        status: TaskStatus = .running,
        sessionId: String? = nil,
        engineType: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.description = description
        self.status = status
        self.sessionId = sessionId
        self.engineType = engineType
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
