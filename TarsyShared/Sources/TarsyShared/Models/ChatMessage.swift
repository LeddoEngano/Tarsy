import Foundation

public struct ChatMessage: Codable, Identifiable, Sendable {
    public let id: UUID
    public let workspaceId: UUID
    public let tabId: String
    public let role: MessageRole
    public let content: String
    public let createdAt: Date

    public enum MessageRole: String, Codable, Sendable {
        case user
        case assistant
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceId = "workspace_id"
        case tabId = "tab_id"
        case role
        case content
        case createdAt = "created_at"
    }

    public init(id: UUID = UUID(), workspaceId: UUID, tabId: String, role: MessageRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}
