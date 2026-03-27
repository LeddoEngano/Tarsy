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

/// Client that talks to UltraContext via Supabase Edge Function proxy.
/// The API key never leaves the server — only the user's Supabase auth token is used.
@MainActor
public class UltraContextClient: ObservableObject {
    @Published public var sessions: [UltraContextSession] = []
    @Published public var isLoading = false

    private let proxyURL: String

    public init() {
        self.proxyURL = TarsyConfig.supabaseURL.absoluteString + "/functions/v1/ultracontext-proxy"
    }

    public static func configured() -> UltraContextClient {
        UltraContextClient()
    }

    /// Always configured — the proxy handles auth via Supabase token
    public var isConfigured: Bool { true }

    private func authToken() async -> String? {
        try? await supabase.auth.session.accessToken
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let url = URL(string: "\(proxyURL)\(path)") else { throw URLError(.badURL) }
        guard let token = await authToken() else { throw URLError(.userAuthenticationRequired) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
