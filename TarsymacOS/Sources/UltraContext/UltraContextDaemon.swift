import Foundation
import TarsyShared

/// Manages UltraContext sessions by pushing data via Supabase Edge Function proxy.
/// The UltraContext API key stays on the server — only the Supabase auth token is used.
actor UltraContextSync {
    static let shared = UltraContextSync()

    private let proxyURL: String = {
        let base = TarsyConfig.supabaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return base + "/functions/v1/ultracontext-proxy"
    }()

    /// Maps engine sessionId -> UltraContext contextId
    private var contextMap: [String: String] = [:]

    // MARK: - HTTP

    private func authToken() async -> String? {
        try? await supabase.auth.session.accessToken
    }

    private func post(_ payload: [String: String]) async throws -> Data {
        guard let url = URL(string: proxyURL) else { throw URLError(.badURL) }
        guard let token = await authToken() else { throw URLError(.userAuthenticationRequired) }
        print("[UltraContext] POST \(proxyURL) action=\(payload["action"] ?? "?")")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(TarsyConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
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

    private func createContext(projectPath: String? = nil, engineType: String? = nil) async throws -> String {
        var payload = ["action": "create"]
        if let p = projectPath { payload["project_path"] = p }
        if let e = engineType { payload["engine_type"] = e }
        let data = try await post(payload)
        let decoded = try JSONDecoder().decode(CreateContextResponse.self, from: data)
        return decoded.id
    }

    private func appendMessage(contextId: String, role: String, content: String) async throws {
        _ = try await post([
            "action": "message",
            "id": contextId,
            "role": role,
            "content": content,
        ])
    }

    // MARK: - Engine lifecycle

    /// Stores engine info for lazy context creation (only on first real message)
    private var pendingEngines: [String: (engineType: String, workspacePath: String)] = [:]

    func engineStarted(sessionId: String, engineType: String, workspacePath: String) async {
        // Don't create context yet — wait for the first real message
        pendingEngines[sessionId] = (engineType, workspacePath)
    }

    /// Ensures a context exists for this session, creating lazily if needed
    private func ensureContext(sessionId: String) async -> String? {
        if let ctxId = contextMap[sessionId] { return ctxId }
        guard let info = pendingEngines.removeValue(forKey: sessionId) else { return nil }
        do {
            let ctxId = try await createContext(projectPath: info.workspacePath, engineType: info.engineType)
            contextMap[sessionId] = ctxId
            return ctxId
        } catch {
            print("[UltraContext] Create context error: \(error)")
            return nil
        }
    }

    func userMessage(sessionId: String, content: String) async {
        guard let ctxId = await ensureContext(sessionId: sessionId) else { return }
        do {
            try await appendMessage(contextId: ctxId, role: "user", content: String(content.prefix(8000)))
        } catch {
            print("[UltraContext] Append user message error: \(error)")
        }
    }

    func agentOutput(sessionId: String, content: String) async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let ctxId = await ensureContext(sessionId: sessionId) else { return }
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
        pendingEngines.removeValue(forKey: sessionId)
    }
}
