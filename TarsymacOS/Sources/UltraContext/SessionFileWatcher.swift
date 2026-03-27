import Foundation
import TarsyShared

/// Watches Claude Code session files (~/.claude/projects/**/*.jsonl) and syncs
/// new messages to UltraContext via the Supabase proxy.
/// Replaces the need for the ultracontext CLI daemon.
actor SessionFileWatcher {
    static let shared = SessionFileWatcher()

    private var watchedFiles: [String: Int64] = [:]  // path -> last read offset
    private var sessionContextMap: [String: String] = [:]  // claudeSessionId -> ultraContextId
    private var timer: Timer?
    private var isRunning = false

    private let proxyURL: String = {
        let base = TarsyConfig.supabaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return base + "/functions/v1/ultracontext-proxy"
    }()

    private let claudeDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
        return home + "/.claude/projects"
    }()

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        print("[SessionWatcher] Watching \(claudeDir)")

        // Initial scan
        Task { await scanAndSync() }

        // Poll every 5 seconds for new content
        Task { @MainActor in
            Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
                Task { await SessionFileWatcher.shared.scanAndSync() }
            }
        }
    }

    func stop() {
        isRunning = false
    }

    // MARK: - Scan

    private func scanAndSync() async {
        guard isRunning else { return }

        // Find all .jsonl files modified in the last 24h
        let fm = FileManager.default
        guard fm.fileExists(atPath: claudeDir) else { return }

        let cutoff = Date().addingTimeInterval(-86400)
        let enumerator = fm.enumerator(atPath: claudeDir)

        while let relativePath = enumerator?.nextObject() as? String {
            guard relativePath.hasSuffix(".jsonl") else { continue }
            // Skip subagent files — only watch main session files
            guard !relativePath.contains("/subagents/") else { continue }

            let fullPath = claudeDir + "/" + relativePath
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate > cutoff else { continue }

            await processFile(fullPath)
        }
    }

    private func processFile(_ path: String) async {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { handle.closeFile() }

        let lastOffset = watchedFiles[path] ?? 0
        handle.seek(toFileOffset: UInt64(lastOffset))

        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }

        watchedFiles[path] = Int64(handle.offsetInFile)

        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }

        for line in lines {
            await processLine(line)
        }
    }

    // MARK: - Parse & Sync

    private struct SessionLine: Decodable {
        let type: String?  // "user" or "assistant"
        let sessionId: String?
        let message: MessageContent?
        let cwd: String?

        struct MessageContent: Decodable {
            let role: String?
            let content: ContentValue?
        }

        enum ContentValue: Decodable {
            case string(String)
            case array([ContentBlock])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let str = try? container.decode(String.self) {
                    self = .string(str)
                } else if let arr = try? container.decode([ContentBlock].self) {
                    self = .array(arr)
                } else {
                    self = .string("")
                }
            }

            var text: String {
                switch self {
                case .string(let s): return s
                case .array(let blocks):
                    return blocks.compactMap { block -> String? in
                        if case .text = block.type { return block.text }
                        if case .toolUse = block.type { return "[\(block.name ?? "tool")]" }
                        return nil
                    }.joined(separator: "\n")
                }
            }
        }

        struct ContentBlock: Decodable {
            let type: BlockType?
            let text: String?
            let name: String?

            enum BlockType: String, Decodable {
                case text
                case toolUse = "tool_use"
                case toolResult = "tool_result"
            }
        }
    }

    private func processLine(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(SessionLine.self, from: data),
              let sessionId = parsed.sessionId,
              let role = parsed.message?.role ?? parsed.type,
              let content = parsed.message?.content?.text,
              !content.isEmpty else { return }

        // Only sync user and assistant messages
        guard role == "user" || role == "assistant" else { return }

        // Skip very short content (tool results, etc.)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 5 else { return }

        // Ensure we have an UltraContext context for this session
        if sessionContextMap[sessionId] == nil {
            do {
                let ctxId = try await createContext(sessionId: sessionId, cwd: parsed.cwd)
                sessionContextMap[sessionId] = ctxId
            } catch {
                print("[SessionWatcher] Create context error: \(error)")
                return
            }
        }

        guard let ctxId = sessionContextMap[sessionId] else { return }

        do {
            try await appendMessage(contextId: ctxId, role: role, content: String(trimmed.prefix(8000)))
        } catch {
            print("[SessionWatcher] Append error: \(error)")
        }
    }

    // MARK: - API

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
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[SessionWatcher] HTTP \(http.statusCode): \(body)")
        }
        return data
    }

    private struct CreateResponse: Decodable { let id: String }

    private func createContext(sessionId: String, cwd: String?) async throws -> String {
        let data = try await post(["action": "create"])
        let decoded = try JSONDecoder().decode(CreateResponse.self, from: data)
        let project = cwd?.components(separatedBy: "/").last ?? "unknown"
        try await appendMessage(contextId: decoded.id, role: "user", content: "[session:\(sessionId.prefix(8))] Project: \(project)")
        print("[SessionWatcher] Created context \(decoded.id) for session \(sessionId.prefix(8))")
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
}
