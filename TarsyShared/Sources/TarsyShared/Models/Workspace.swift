import Foundation

public struct Workspace: Codable, Identifiable, Sendable {
    public let id: UUID
    public let userId: UUID
    public let machineId: UUID
    public let name: String
    public let repoUrl: String?
    public let localPath: String
    public let stack: WorkspaceStack
    public let status: WorkspaceStatus
    public let currentBranch: String?
    public let devServerCommand: String?
    public let streamUrl: String?
    public let aiContext: String?
    public let config: [String: String]?
    public let createdAt: Date
    public let updatedAt: Date

    public enum WorkspaceStack: String, Codable, Sendable {
        case web
        case mobile
        case backend
        case fullstack
    }

    public enum WorkspaceStatus: String, Codable, Sendable {
        case idle
        case starting
        case running
        case error
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case machineId = "machine_id"
        case name
        case repoUrl = "repo_url"
        case localPath = "local_path"
        case stack
        case status
        case currentBranch = "current_branch"
        case devServerCommand = "dev_server_command"
        case streamUrl = "stream_url"
        case aiContext = "ai_context"
        case config
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
