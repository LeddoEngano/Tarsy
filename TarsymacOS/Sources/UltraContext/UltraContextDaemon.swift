import Foundation
import TarsyShared

/// Manages UltraContext sessions by pushing data via Supabase Edge Function proxy.
/// The UltraContext API key stays on the server — only the Supabase auth token is used.
actor UltraContextSync {
    static let shared = UltraContextSync()

    private let proxyURL = TarsyConfig.supabaseURL.absoluteString + "/functions/v1/ultracontext-proxy"

    /// Maps engine sessionId -> UltraContext contextId
    private var contextMap: [String: String] = [:]

    // MARK: - HTTP

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
        req.setValue(TarsyConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[UltraContext] HTTP \(http.statusCode): \(body)")
        }
        return data
    }

    private struct CreateContextResponse: Decodable {
        let id: String
    }

    private func createContext() async throws -> String {
        let data = try await request("/contexts", method: "POST")
        let decoded = try JSONDecoder().decode(CreateContextResponse.self, from: data)
        return decoded.id
    }

    private func appendMessage(contextId: String, role: String, content: String) async throws {
        let msg = ["role": role, "content": content]
        let body = try JSONEncoder().encode(msg)
        _ = try await request("/contexts/\(contextId)/messages", method: "POST", body: body)
    }

    // MARK: - Engine lifecycle

    func engineStarted(sessionId: String, engineType: String, workspacePath: String) async {
        do {
            let ctxId = try await createContext()
            contextMap[sessionId] = ctxId
            try await appendMessage(
                contextId: ctxId,
                role: "user",
                content: "[engine:\(engineType)] Started in \(workspacePath)"
            )
        } catch {
            print("[UltraContext] Create context error: \(error)")
        }
    }

    func userMessage(sessionId: String, content: String) async {
        guard let ctxId = contextMap[sessionId] else { return }
        do {
            try await appendMessage(contextId: ctxId, role: "user", content: String(content.prefix(8000)))
        } catch {
            print("[UltraContext] Append user message error: \(error)")
        }
    }

    func agentOutput(sessionId: String, content: String) async {
        guard let ctxId = contextMap[sessionId], !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await appendMessage(contextId: ctxId, role: "assistant", content: String(content.prefix(8000)))
        } catch {
            print("[UltraContext] Append output error: \(error)")
        }
    }

    func engineCompleted(sessionId: String, summary: String) async {
        guard let ctxId = contextMap[sessionId] else { return }
        do {
            try await appendMessage(contextId: ctxId, role: "assistant", content: "[completed] \(String(summary.prefix(4000)))")
        } catch {
            print("[UltraContext] Complete error: \(error)")
        }
        contextMap.removeValue(forKey: sessionId)
    }

    func engineClosed(sessionId: String) {
        contextMap.removeValue(forKey: sessionId)
    }
}
