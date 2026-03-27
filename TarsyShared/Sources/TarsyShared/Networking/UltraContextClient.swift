import Foundation

public struct UltraContextMessage: Codable, Sendable {
    public let role: String  // "user" or "assistant"
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
}

@MainActor
public class UltraContextClient: ObservableObject {
    @Published public var sessions: [UltraContextSession] = []
    @Published public var isLoading = false

    private let baseURL: String
    private let apiKey: String

    public init(baseURL: String = "https://api.ultracontext.ai", apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey ?? TarsyConfig.ultraContextAPIKey
    }

    /// Create a client using the bundled API key from TarsyConfig
    public static func configured() -> UltraContextClient {
        UltraContextClient()
    }

    public var isConfigured: Bool { !apiKey.isEmpty }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    // MARK: - CRUD

    public func createContext() async throws -> UltraContextSession {
        let data = try await request("/contexts", method: "POST")
        return try JSONDecoder().decode(UltraContextSession.self, from: data)
    }

    public func getContext(id: String) async throws -> UltraContextSession {
        let data = try await request("/contexts/\(id)")
        return try JSONDecoder().decode(UltraContextSession.self, from: data)
    }

    public func appendMessage(contextId: String, role: String, content: String) async throws {
        let msg = ["role": role, "content": content]
        let body = try JSONEncoder().encode(msg)
        _ = try await request("/contexts/\(contextId)/messages", method: "POST", body: body)
    }

    public func listContexts() async throws -> [UltraContextSession] {
        let data = try await request("/contexts")
        // API might return { data: [...] } or just [...]
        if let wrapper = try? JSONDecoder().decode([String: [UltraContextSession]].self, from: data),
           let contexts = wrapper["data"] {
            return contexts
        }
        return try JSONDecoder().decode([UltraContextSession].self, from: data)
    }

    // MARK: - Load sessions

    public func loadSessions() async {
        guard isConfigured else { return }
        isLoading = true
        do {
            sessions = try await listContexts()
        } catch {
            print("[UltraContext] Load sessions error: \(error)")
        }
        isLoading = false
    }
}
