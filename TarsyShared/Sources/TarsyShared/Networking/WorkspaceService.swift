import Foundation
import Supabase

public struct CreateWorkspaceRequest: Encodable {
    public let userId: String
    public let machineId: String
    public let name: String
    public let repoUrl: String?
    public let localPath: String
    public let stack: String
    public let workspaceType: String
    public let devServerCommand: String?
    public let streamUrl: String?
    public let aiContext: String?
    public let config: [String: String]?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case machineId = "machine_id"
        case name
        case repoUrl = "repo_url"
        case localPath = "local_path"
        case stack
        case workspaceType = "workspace_type"
        case devServerCommand = "dev_server_command"
        case streamUrl = "stream_url"
        case aiContext = "ai_context"
        case config
    }

    public init(userId: String, machineId: String, name: String, repoUrl: String?, localPath: String, stack: String, workspaceType: String = "standard", devServerCommand: String?, streamUrl: String?, aiContext: String?, config: [String: String]? = nil) {
        self.userId = userId
        self.machineId = machineId
        self.name = name
        self.repoUrl = repoUrl
        self.localPath = localPath
        self.stack = stack
        self.workspaceType = workspaceType
        self.devServerCommand = devServerCommand
        self.streamUrl = streamUrl
        self.aiContext = aiContext
        self.config = config
    }
}

public struct UpdateWorkspaceRequest: Encodable {
    public var name: String?
    public var repoUrl: String?
    public var localPath: String?
    public var stack: String?
    public var devServerCommand: String?
    public var streamUrl: String?
    public var aiContext: String?
    public var status: String?
    public var currentBranch: String?
    /// Full replacement of the `config` jsonb. Supabase PATCH replaces the
    /// entire column rather than deep-merging, so callers must build the
    /// complete dict (existing keys + their edits) before assigning here.
    public var config: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name
        case repoUrl = "repo_url"
        case localPath = "local_path"
        case stack
        case devServerCommand = "dev_server_command"
        case streamUrl = "stream_url"
        case aiContext = "ai_context"
        case status
        case currentBranch = "current_branch"
        case config
    }

    public init() {}
}

@MainActor
public class WorkspaceService: ObservableObject {
    @Published public var workspaces: [Workspace] = []
    @Published public var isLoading = false

    public init() {}

    public func fetchWorkspaces() async {
        isLoading = true
        do {
            workspaces = try await supabase
                .from("workspaces")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            #if DEBUG
            print("[WorkspaceService] Fetch error: \(error)")
            #endif
        }
        isLoading = false
    }

    public func createWorkspace(_ request: CreateWorkspaceRequest) async throws -> Workspace {
        let workspace: Workspace = try await supabase
            .from("workspaces")
            .insert(request)
            .select()
            .single()
            .execute()
            .value
        workspaces.insert(workspace, at: 0)
        return workspace
    }

    public func updateWorkspace(id: UUID, _ request: UpdateWorkspaceRequest) async throws {
        try await supabase
            .from("workspaces")
            .update(request)
            .eq("id", value: id.uuidString)
            .execute()
        await fetchWorkspaces()
    }

    public func deleteWorkspace(id: UUID) async throws {
        try await supabase
            .from("workspaces")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
        workspaces.removeAll { $0.id == id }
    }

    public func updateAIContext(workspaceId: UUID, context: String) async throws {
        var req = UpdateWorkspaceRequest()
        req.aiContext = context
        try await updateWorkspace(id: workspaceId, req)
    }
}
