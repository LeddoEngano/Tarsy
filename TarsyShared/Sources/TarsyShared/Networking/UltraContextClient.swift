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

    enum CodingKeys: String, CodingKey {
        case id, messages, version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(id: String, messages: [UltraContextMessage], version: Int?, createdAt: String?, updatedAt: String?) {
        self.id = id
        self.messages = messages
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        messages = (try? container.decode([UltraContextMessage].self, forKey: .messages)) ?? []
        version = try? container.decode(Int.self, forKey: .version)
        createdAt = try? container.decode(String.self, forKey: .createdAt)
        updatedAt = try? container.decode(String.self, forKey: .updatedAt)
    }
}

/// Client that talks to UltraContext via Supabase Edge Function proxy.
/// The API key never leaves the server — only the user's Supabase auth token is used.
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

    private struct CreateContextResponse: Decodable {
        let id: String
    }

    public func createContext() async throws -> UltraContextSession {
        let data = try await post(["action": "create"])
        let created = try JSONDecoder().decode(CreateContextResponse.self, from: data)
        return UltraContextSession(id: created.id, messages: [], version: nil, createdAt: nil, updatedAt: nil)
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
