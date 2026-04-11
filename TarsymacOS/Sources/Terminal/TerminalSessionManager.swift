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

    func interruptSession(_ sessionId: String) {
        sessions[sessionId]?.interrupt()
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

    /// Install a callback that fires every time the wrapped-command
    /// sentinel is seen in the session's output stream — i.e. the
    /// shell has just finished a command and is ready for the next one.
    func setPromptReadyHandler(for sessionId: String, handler: @escaping @Sendable () -> Void) {
        sessions[sessionId]?.onPromptReady = handler
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

    func interruptEngineSession(_ sessionId: String) async {
        await engineSessions[sessionId]?.interrupt()
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
    /// Fired whenever the sentinel marker appears in the output stream,
    /// i.e. every time a user-issued command finishes and the shell is
    /// ready for the next input. Used by the iOS client to clear the
    /// "cancel" / spinner affordance.
    var onPromptReady: (@Sendable () -> Void)?

    /// Per-session unique token. We wrap every `sendInput` command with
    /// `; printf '\n__TARSY_DONE_<token>__\n'` so that when the command
    /// list finishes, zsh emits a marker we can detect in the output
    /// stream. A UUID suffix guarantees the marker can never collide
    /// with real command output.
    private let sentinelToken: String
    /// Fully-formed marker (what we scan for in the output stream).
    private let sentinelMarker: String
    /// Bytes we scan for when detecting the marker. Computed once.
    private let sentinelMarkerCount: Int
    /// Output accumulator for marker detection. Chunks from the pipe
    /// may split a marker in half, so we hold back up to
    /// `sentinelMarkerCount - 1` trailing bytes until we either see
    /// more data (confirming / rejecting the match) or the session
    /// closes.
    private var outputBuffer: String = ""

    init(id: String, workingDirectory: String? = nil) throws {
        self.id = id
        self.process = Process()
        self.inputPipe = Pipe()
        self.outputPipe = Pipe()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        self.sentinelToken = token
        self.sentinelMarker = "\u{1E}__TARSY_DONE_\(token)__\u{1E}"
        self.sentinelMarkerCount = self.sentinelMarker.count

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
            self?.processIncomingOutput(text)
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
        let sanitized = input.trimmingCharacters(in: .newlines)
        guard !sanitized.isEmpty else { return }

        // Wrap every command in a brace group and append a sentinel
        // printf on the same command list. When zsh finishes executing
        // the list (success, failure, even silent fall-through) it
        // prints the sentinel, which the output scanner uses as the
        // "prompt is ready" signal for the iOS client.
        //
        // `{ ... ; }` is a command group, NOT a subshell — it runs in
        // the parent shell, so user `cd`s and variable assignments keep
        // working. ASCII Record Separator (\x1E) is used as the marker
        // delimiter so it can never collide with real command output.
        // `printf` is a zsh builtin, so the wrap is essentially free.
        let wrapped = "{ \(sanitized); }; printf '\\036__TARSY_DONE_\(sentinelToken)__\\036'\n"
        guard let data = wrapped.data(using: .utf8) else { return }
        inputPipe.fileHandleForWriting.write(data)
    }

    func interrupt() {
        process.interrupt() // sends SIGINT
    }

    func terminate() {
        process.terminate()
        outputPipe.fileHandleForReading.readabilityHandler = nil
    }

    // MARK: - Output Processing

    /// Appends incoming text to the buffer, emits any sentinel-free
    /// prefix as normal output, and fires `onPromptReady` for each
    /// complete sentinel marker detected. Holds back up to
    /// `sentinelMarkerCount - 1` trailing bytes so a marker split
    /// across chunks is still caught.
    private func processIncomingOutput(_ text: String) {
        outputBuffer += text

        // Drain every complete marker currently in the buffer.
        while let range = outputBuffer.range(of: sentinelMarker) {
            let before = String(outputBuffer[..<range.lowerBound])
            if !before.isEmpty { onOutput?(before) }
            outputBuffer.removeSubrange(outputBuffer.startIndex..<range.upperBound)
            onPromptReady?()
        }

        // After draining, the buffer may still contain a partial marker
        // at its tail. Figure out the longest suffix of the buffer that
        // is also a prefix of the marker, and hold back exactly that
        // many characters. Everything before it is safe to emit.
        let holdBack = longestMarkerPrefixSuffix()
        if holdBack < outputBuffer.count {
            let safeEnd = outputBuffer.index(outputBuffer.endIndex, offsetBy: -holdBack)
            let safe = String(outputBuffer[..<safeEnd])
            if !safe.isEmpty { onOutput?(safe) }
            outputBuffer.removeSubrange(outputBuffer.startIndex..<safeEnd)
        }
    }

    /// Length of the longest suffix of `outputBuffer` that is also a
    /// prefix of `sentinelMarker`. Used to hold back just enough
    /// trailing bytes to detect a marker split across chunks without
    /// delaying the bulk of the stream.
    private func longestMarkerPrefixSuffix() -> Int {
        let maxCheck = min(outputBuffer.count, sentinelMarkerCount - 1)
        guard maxCheck > 0 else { return 0 }
        for len in stride(from: maxCheck, through: 1, by: -1) {
            let suffixStart = outputBuffer.index(outputBuffer.endIndex, offsetBy: -len)
            let suffix = String(outputBuffer[suffixStart...])
            if sentinelMarker.hasPrefix(suffix) {
                return len
            }
        }
        return 0
    }
}
