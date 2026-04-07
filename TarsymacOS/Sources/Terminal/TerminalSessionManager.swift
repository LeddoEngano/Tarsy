import Foundation
import TarsyShared

actor TerminalSessionManager {
    private var sessions: [String: TerminalSession] = [:]
    private var claudeSessions: [String: ClaudeCodeSession] = [:]
    private var engineSessions: [String: any AIEngine] = [:]

    // MARK: - Raw Terminal Sessions

    func createSession(id: String = UUID().uuidString, workingDirectory: String? = nil) throws -> String {
        let expandedDir = workingDirectory.map { ($0 as NSString).expandingTildeInPath }
        let session = try TerminalSession(id: id, workingDirectory: expandedDir)
        sessions[id] = session
        return id
    }

    func sendInput(_ input: String, to sessionId: String) {
        sessions[sessionId]?.sendInput(input)
    }

    func closeSession(_ sessionId: String) {
        sessions[sessionId]?.terminate()
        sessions.removeValue(forKey: sessionId)
    }

    func isSessionAlive(_ sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        return session.process.isRunning
    }

    func listSessions() -> [String] {
        Array(sessions.keys)
    }

    func setOutputHandler(for sessionId: String, handler: @escaping @Sendable (String) -> Void) {
        sessions[sessionId]?.onOutput = handler
    }

    // MARK: - Claude Code Sessions

    func createClaudeSession(
        id: String = UUID().uuidString,
        workspacePath: String,
        aiContext: String? = nil,
        permissionMode: AgentPermissionConfig.PermissionMode = .dangerous,
        onOutput: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String) -> Void,
        onAskUser: @escaping @Sendable (String, [String]) -> Void = { _, _ in }
    ) throws -> String {
        let session = ClaudeCodeSession(id: id, workspacePath: workspacePath, aiContext: aiContext, permissionMode: permissionMode)
        claudeSessions[id] = session

        Task {
            await session.setHandlers(onOutput: onOutput, onComplete: onComplete)
            await session.setAskUserHandler(onAskUser)
            try await session.start()
        }

        return id
    }

    func setClaudeStatusHandler(sessionId: String, handler: @escaping @Sendable (String, Int, Int, Int) -> Void) async {
        await claudeSessions[sessionId]?.setStatusHandler(handler)
    }

    func setClaudeSessionIdHandler(sessionId: String, handler: @escaping @Sendable (String) -> Void) async {
        await claudeSessions[sessionId]?.setSessionIdHandler(handler)
    }

    func sendClaudeMessage(_ message: String, images imagesJson: String? = nil, to sessionId: String) async {
        await claudeSessions[sessionId]?.sendMessage(message, imagesJson: imagesJson)
    }

    func respondToClaudeQuestion(_ answer: String, sessionId: String) async {
        await claudeSessions[sessionId]?.respondToQuestion(answer)
    }

    func setClaudePermissionHandler(sessionId: String, handler: @escaping @Sendable (String, String, [String: Any]) -> Void) async {
        await claudeSessions[sessionId]?.setPermissionHandler(handler)
    }

    func respondToClaudePermission(_ requestId: String, answer: String, sessionId: String) async {
        await claudeSessions[sessionId]?.respondToPermission(requestId: requestId, answer: answer)
    }

    func closeClaudeSession(_ sessionId: String) async {
        await claudeSessions[sessionId]?.terminate()
        claudeSessions.removeValue(forKey: sessionId)
    }

    func listClaudeSessions() -> [String] {
        Array(claudeSessions.keys)
    }

    // MARK: - Generic Engine Sessions (Multi-Provider)

    func createEngineSession(
        id: String = UUID().uuidString,
        engineType: AIEngineType,
        workspacePath: String,
        command: String? = nil,
        apiKey: String? = nil,
        permissionMode: AgentPermissionConfig.PermissionMode = .dangerous,
        onOutput: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String) -> Void,
        onAskUser: @escaping @Sendable (String, [String]) -> Void = { _, _ in }
    ) async throws -> String {
        let engine: any AIEngine

        if engineType == .claude {
            let session = ClaudeCodeSession(id: id, workspacePath: workspacePath, permissionMode: permissionMode)
            claudeSessions[id] = session
            engine = session
        } else if engineType == .codex {
            let session = CodexSession(id: id, workspacePath: workspacePath, permissionMode: permissionMode)
            engine = session
        } else if engineType == .gemini {
            let session = GeminiSession(id: id, workspacePath: workspacePath, permissionMode: permissionMode)
            engine = session
        } else {
            let session = GenericCLIEngine(id: id, engineType: engineType, workspacePath: workspacePath, command: command, apiKey: apiKey, permissionMode: permissionMode)
            engine = session
        }

        engineSessions[id] = engine

        await engine.setHandlers(onOutput: onOutput, onComplete: onComplete)
        await engine.setAskUserHandler(onAskUser)
        try await engine.start()

        return id
    }

    func setEngineStatusHandler(sessionId: String, handler: @escaping @Sendable (String, Int, Int, Int) -> Void) async {
        if let generic = engineSessions[sessionId] as? GenericCLIEngine {
            await generic.setStatusHandler(handler)
        } else if let codex = engineSessions[sessionId] as? CodexSession {
            await codex.setStatusHandler(handler)
        } else if let claude = engineSessions[sessionId] as? ClaudeCodeSession {
            await claude.setStatusHandler(handler)
        } else if let gemini = engineSessions[sessionId] as? GeminiSession {
            await gemini.setStatusHandler(handler)
        }
    }

    func sendEngineMessage(_ message: String, to sessionId: String) async {
        await engineSessions[sessionId]?.sendMessage(message)
    }

    func respondToCodexApproval(_ answer: String, sessionId: String) async {
        if let codex = engineSessions[sessionId] as? CodexSession {
            await codex.handleApprovalAnswer(answer)
        } else {
            await engineSessions[sessionId]?.respondToQuestion(answer)
        }
    }

    func respondToGeminiPermission(_ answer: String, rpcId: Int, sessionId: String) async {
        if let gemini = engineSessions[sessionId] as? GeminiSession {
            await gemini.respondToGeminiPermission(rpcId: rpcId, answer: answer)
        } else {
            await engineSessions[sessionId]?.respondToQuestion(answer)
        }
    }

    func respondToEngineQuestion(_ answer: String, sessionId: String) async {
        await engineSessions[sessionId]?.respondToQuestion(answer)
    }

    func closeEngineSession(_ sessionId: String) async {
        await engineSessions[sessionId]?.terminate()
        engineSessions.removeValue(forKey: sessionId)
        claudeSessions.removeValue(forKey: sessionId)
    }

    // MARK: - All Sessions

    func listAllSessions() -> (terminals: [String], claude: [String], engines: [String]) {
        (terminals: Array(sessions.keys), claude: Array(claudeSessions.keys), engines: Array(engineSessions.keys))
    }
}

class TerminalSession {
    let id: String
    let process: Process
    let inputPipe: Pipe
    let outputPipe: Pipe
    var onOutput: (@Sendable (String) -> Void)?

    init(id: String, workingDirectory: String? = nil) throws {
        self.id = id
        self.process = Process()
        self.inputPipe = Pipe()
        self.outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        // Enrich PATH with common tool locations that Xcode's sandbox doesn't include
        var env = ProcessInfo.processInfo.environment
        // Sandbox makes HOME point to container — use real user home instead
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
        let home = realHome.isEmpty ? (env["HOME"] ?? NSHomeDirectory()) : realHome
        // Set HOME to real home so child processes (nvm, etc.) find their config
        env["HOME"] = home
        let extraPaths = [
            "/opt/homebrew/bin",                  // Homebrew (Apple Silicon)
            "/usr/local/bin",                     // Homebrew (Intel) / system tools
            "\(home)/.local/share/pnpm",          // pnpm standalone
            "\(home)/.bun/bin",                   // bun
            "\(home)/.cargo/bin",                 // rust/cargo
            "\(home)/.volta/bin",                 // volta
            "\(home)/go/bin",                     // go
        ]
        var resolvedPaths = extraPaths.filter { FileManager.default.fileExists(atPath: $0) }

        // nvm: list all node version dirs and add their bin/
        let nvmDir = "\(home)/.nvm/versions/node"
        let nvmDirExists = FileManager.default.fileExists(atPath: nvmDir)
        if nvmDirExists {
            do {
                let versions = try FileManager.default.contentsOfDirectory(atPath: nvmDir)
                for version in versions {
                    let binPath = "\(nvmDir)/\(version)/bin"
                    if FileManager.default.fileExists(atPath: binPath) {
                        resolvedPaths.append(binPath)
                    }
                }
            } catch {
                #if DEBUG
                print("[TerminalSession] ERROR listing nvm dir: \(error)")
                #endif
            }
        }

        // Also try common node manager paths directly
        let additionalNodePaths = [
            "\(home)/.nvm/versions/node",  // will be scanned above
            "\(home)/.fnm/node-versions",  // fnm
            "\(home)/.asdf/shims",         // asdf
            "\(home)/.proto/shims",        // proto
            "\(home)/.local/share/fnm/node-versions", // fnm alternative
        ]
        for dir in additionalNodePaths {
            if FileManager.default.fileExists(atPath: dir) {
                if let subs = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                    for sub in subs {
                        let binPath = "\(dir)/\(sub)/bin"
                        if FileManager.default.fileExists(atPath: binPath) {
                            resolvedPaths.append(binPath)
                        }
                    }
                }
            }
        }

        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        let enrichedPath = (resolvedPaths + [currentPath]).joined(separator: ":")
        env["PATH"] = enrichedPath
        #if DEBUG
        print("[TerminalSession] Enriched PATH additions: \(resolvedPaths)")
        #endif
        process.environment = env

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.onOutput?(text)
        }

        try process.run()

        // After the shell starts (and .zshrc finishes), force cd to the correct
        // workspace directory. This guarantees the right cwd even when the user's
        // shell profile contains a `cd` that overrides currentDirectoryURL.
        if let dir = workingDirectory {
            let escaped = dir.replacingOccurrences(of: "'", with: "'\\''")
            let cdCmd = "cd '\(escaped)'\n"
            if let data = cdCmd.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
        }
    }

    func sendInput(_ input: String) {
        guard let data = "\(input)\n".data(using: .utf8) else { return }
        inputPipe.fileHandleForWriting.write(data)
    }

    func terminate() {
        process.terminate()
        outputPipe.fileHandleForReading.readabilityHandler = nil
    }
}
