import Foundation

public struct UltraContextMessage: Codable, Sendable {
    public let role: String
    public let content: String
    public let index: Int?

    public init(role: String, content: String, index: Int? = nil) {
        self.role = role
        self.content = content
        self.index = index
    }
}

public struct UltraContextSession: Codable, Identifiable, Sendable {
    public let id: String
    public let messages: [UltraContextMessage]
    public let version: Int?
    public let createdAt: String?
    public let updatedAt: String?
    public let title: String?
    public let hasImage: Bool
    public let projectPath: String?
    public let engineType: String?
    public let workspaceId: String?
    public let messageCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, messages, version, title
        case hasImage = "has_image"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case projectPath = "project_path"
        case engineType = "engine_type"
        case workspaceId = "workspace_id"
        case messageCount = "message_count"
    }

    public init(id: String, messages: [UltraContextMessage] = [], version: Int? = nil,
                createdAt: String? = nil, updatedAt: String? = nil, title: String? = nil,
                hasImage: Bool = false, projectPath: String? = nil, engineType: String? = nil,
                workspaceId: String? = nil, messageCount: Int? = nil) {
        self.id = id
        self.messages = messages
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.hasImage = hasImage
        self.projectPath = projectPath
        self.engineType = engineType
        self.workspaceId = workspaceId
        self.messageCount = messageCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        messages = (try? container.decode([UltraContextMessage].self, forKey: .messages)) ?? []
        version = try? container.decode(Int.self, forKey: .version)
        createdAt = try? container.decode(String.self, forKey: .createdAt)
        updatedAt = try? container.decode(String.self, forKey: .updatedAt)
        title = try? container.decode(String.self, forKey: .title)
        hasImage = (try? container.decode(Bool.self, forKey: .hasImage)) ?? false
        projectPath = try? container.decode(String.self, forKey: .projectPath)
        engineType = try? container.decode(String.self, forKey: .engineType)
        workspaceId = try? container.decode(String.self, forKey: .workspaceId)
        messageCount = try? container.decode(Int.self, forKey: .messageCount)
    }

    /// Display title: use title field, or fallback to project name, or session ID prefix
    public var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let path = projectPath { return path.components(separatedBy: "/").last ?? path }
        return "Session \(id.prefix(8))"
    }

    /// Project name extracted from path
    public var projectName: String? {
        projectPath?.components(separatedBy: "/").last
    }
}

/// Client that talks to UltraContext via Supabase Edge Function proxy.
@MainActor
public class UltraContextClient: ObservableObject {
    @Published public var sessions: [UltraContextSession] = []
    @Published public var isLoading = false

    private let proxyURL: String

    public init() {
        let base = TarsyConfig.supabaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.proxyURL = base + "/functions/v1/ultracontext-proxy"
    }

    public static func configured() -> UltraContextClient {
        UltraContextClient()
    }

    public var isConfigured: Bool { true }

    private func authToken() async -> String? {
        try? await supabase.auth.session.accessToken
    }

    private func post(_ payload: [String: String]) async throws -> Data {
        guard let url = URL(string: proxyURL) else { throw URLError(.badURL) }
        guard let token = await authToken() else { throw URLError(.userAuthenticationRequired) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(TarsyConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    // MARK: - CRUD

    private struct CreateContextResponse: Decodable { let id: String }

    public func createContext(projectPath: String? = nil, engineType: String? = nil) async throws -> UltraContextSession {
        var payload = ["action": "create"]
        if let p = projectPath { payload["project_path"] = p }
        if let e = engineType { payload["engine_type"] = e }
        let data = try await post(payload)
        let created = try JSONDecoder().decode(CreateContextResponse.self, from: data)
        return UltraContextSession(id: created.id, projectPath: projectPath, engineType: engineType)
    }

    public func getContext(id: String) async throws -> UltraContextSession {
        let data = try await post(["action": "get", "id": id])
        return try JSONDecoder().decode(UltraContextSession.self, from: data)
    }

    public func appendMessage(contextId: String, role: String, content: String) async throws {
        _ = try await post(["action": "message", "id": contextId, "role": role, "content": content])
    }

    public func listContexts() async throws -> [UltraContextSession] {
        let data = try await post(["action": "list"])
        if let wrapper = try? JSONDecoder().decode([String: [UltraContextSession]].self, from: data),
           let contexts = wrapper["data"] {
            return contexts
        }
        return try JSONDecoder().decode([UltraContextSession].self, from: data)
    }

    public func deleteContexts(ids: [String]) async throws {
        guard let url = URL(string: proxyURL) else { throw URLError(.badURL) }
        guard let token = await authToken() else { throw URLError(.userAuthenticationRequired) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(TarsyConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        let payload: [String: Any] = ["action": "delete", "ids": ids]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, _) = try await URLSession.shared.data(for: req)
        sessions.removeAll { ids.contains($0.id) }
    }

    // MARK: - Load sessions

    public func loadSessions() async {
        isLoading = true
        do {
            sessions = try await listContexts()
        } catch {
            print("[UltraContext] Load sessions error: \(error)")
        }
        isLoading = false
    }
}
