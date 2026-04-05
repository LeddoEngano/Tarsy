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

    // MARK: - Output buffering

    /// Buffers agent output chunks per session to avoid saving each small WebSocket chunk as a separate message.
    /// Flushes after 3 seconds of inactivity or when engineCompleted/userMessage is called.
    private var outputBuffers: [String: String] = [:]
    private var flushTasks: [String: Task<Void, Never>] = [:]
    private let maxBufferSize = 16000

    private func bufferOutput(sessionId: String, content: String) async {
        outputBuffers[sessionId, default: ""] += content

        // Cancel previous flush timer
        flushTasks[sessionId]?.cancel()

        // Flush immediately if buffer is large
        if (outputBuffers[sessionId]?.count ?? 0) >= maxBufferSize {
            await flushBuffer(sessionId: sessionId)
            return
        }

        // Schedule flush after inactivity
        flushTasks[sessionId] = Task {
            try? await Task.sleep(nanoseconds: UInt64(3.0 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.flushBuffer(sessionId: sessionId)
        }
    }

    private func flushBuffer(sessionId: String) async {
        flushTasks[sessionId]?.cancel()
        flushTasks.removeValue(forKey: sessionId)

        guard let buffered = outputBuffers.removeValue(forKey: sessionId),
              !buffered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let ctxId = contextMap[sessionId] else { return }

        let content = truncateWithMarker(buffered, limit: 8000)
        do {
            try await appendMessage(contextId: ctxId, role: "assistant", content: content)
        } catch {
            #if DEBUG
            print("[UltraContext] Flush buffer error: \(error)")
            #endif
        }
    }

    // MARK: - Truncation helper

    /// Truncates content to the given limit, appending [truncated] if content was cut.
    private func truncateWithMarker(_ content: String, limit: Int) -> String {
        guard content.count > limit else { return content }
        return String(content.prefix(limit - 12)) + "\n[truncated]"
    }

    // MARK: - HTTP

    private func authToken() async -> String? {
        try? await supabase.auth.session.accessToken
    }

    private func post(_ payload: [String: String]) async throws -> Data {
        guard let url = URL(string: proxyURL) else { throw URLError(.badURL) }
        guard let token = await authToken() else { throw URLError(.userAuthenticationRequired) }
        #if DEBUG
        print("[UltraContext] POST action=\(payload["action"] ?? "?")")
        #endif
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(TarsyConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            #if DEBUG
            print("[UltraContext] HTTP \(http.statusCode): \(body)")
            #endif
        }
        return data
    }

    private struct CreateContextResponse: Decodable {
        let id: String
    }

    private func createContext(projectPath: String? = nil, engineType: String? = nil, workspaceId: String? = nil) async throws -> String {
        var payload = ["action": "create"]
        if let p = projectPath { payload["project_path"] = p }
        if let e = engineType { payload["engine_type"] = e }
        if let w = workspaceId { payload["workspace_id"] = w }
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
    private var pendingEngines: [String: (engineType: String, workspacePath: String, workspaceId: String?)] = [:]

    func engineStarted(sessionId: String, engineType: String, workspacePath: String, workspaceId: String? = nil) async {
        // Don't create context yet — wait for the first real message
        pendingEngines[sessionId] = (engineType, workspacePath, workspaceId)
    }

    /// Ensures a context exists for this session, creating lazily if needed
    private func ensureContext(sessionId: String) async -> String? {
        if let ctxId = contextMap[sessionId] { return ctxId }
        guard let info = pendingEngines.removeValue(forKey: sessionId) else { return nil }
        do {
            let ctxId = try await createContext(projectPath: info.workspacePath, engineType: info.engineType, workspaceId: info.workspaceId)
            contextMap[sessionId] = ctxId
            return ctxId
        } catch {
            #if DEBUG
            print("[UltraContext] Create context error: \(error)")
            #endif
            return nil
        }
    }

    func userMessage(sessionId: String, content: String) async {
        // Flush any buffered agent output before saving user message (preserves chronological order)
        await flushBuffer(sessionId: sessionId)

        guard let ctxId = await ensureContext(sessionId: sessionId) else { return }
        let truncated = truncateWithMarker(content, limit: 8000)
        do {
            try await appendMessage(contextId: ctxId, role: "user", content: truncated)
        } catch {
            #if DEBUG
            print("[UltraContext] Append user message error: \(error)")
            #endif
        }
    }

    func agentOutput(sessionId: String, content: String) async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Ensure context exists (fixes race condition where output arrives before first userMessage)
        guard await ensureContext(sessionId: sessionId) != nil else { return }
        await bufferOutput(sessionId: sessionId, content: content)
    }

    func engineCompleted(sessionId: String, summary: String) async {
        // Flush any remaining buffered output before marking completed
        await flushBuffer(sessionId: sessionId)

        guard let ctxId = contextMap[sessionId] else { return }
        let truncated = truncateWithMarker(summary, limit: 4000)
        do {
            try await appendMessage(contextId: ctxId, role: "assistant", content: "[completed] \(truncated)")
        } catch {
            #if DEBUG
            print("[UltraContext] Complete error: \(error)")
            #endif
        }
        contextMap.removeValue(forKey: sessionId)
    }

    func engineClosed(sessionId: String) async {
        await flushBuffer(sessionId: sessionId)
        contextMap.removeValue(forKey: sessionId)
        pendingEngines.removeValue(forKey: sessionId)
    }
}
