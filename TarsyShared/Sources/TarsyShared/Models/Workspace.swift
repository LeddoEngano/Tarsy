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
    public let workspaceType: WorkspaceType
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

    public enum WorkspaceType: String, Codable, Sendable {
        case standard
        case openClaw = "openclaw"
    }

    /// Whether this workspace captures the full screen instead of a window
    public var isFullScreen: Bool {
        workspaceType == .openClaw
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userId = try container.decode(UUID.self, forKey: .userId)
        machineId = try container.decode(UUID.self, forKey: .machineId)
        name = try container.decode(String.self, forKey: .name)
        repoUrl = try container.decodeIfPresent(String.self, forKey: .repoUrl)
        localPath = try container.decode(String.self, forKey: .localPath)
        stack = try container.decode(WorkspaceStack.self, forKey: .stack)
        status = try container.decode(WorkspaceStatus.self, forKey: .status)
        workspaceType = (try? container.decode(WorkspaceType.self, forKey: .workspaceType)) ?? .standard
        currentBranch = try container.decodeIfPresent(String.self, forKey: .currentBranch)
        devServerCommand = try container.decodeIfPresent(String.self, forKey: .devServerCommand)
        streamUrl = try container.decodeIfPresent(String.self, forKey: .streamUrl)
        aiContext = try container.decodeIfPresent(String.self, forKey: .aiContext)
        config = try container.decodeIfPresent([String: String].self, forKey: .config)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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
        case workspaceType = "workspace_type"
        case currentBranch = "current_branch"
        case devServerCommand = "dev_server_command"
        case streamUrl = "stream_url"
        case aiContext = "ai_context"
        case config
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
