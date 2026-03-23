import Foundation

actor TerminalSessionManager {
    private var sessions: [String: TerminalSession] = [:]
    private var claudeSessions: [String: ClaudeCodeSession] = [:]

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
        onOutput: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String) -> Void
    ) throws -> String {
        let session = ClaudeCodeSession(id: id, workspacePath: workspacePath, aiContext: aiContext)
        claudeSessions[id] = session

        Task {
            await session.setHandlers(
                onOutput: onOutput,
                onComplete: { [weak self] (msg: String) in
                    onComplete(msg)
                    Task { await self?.removeClaudeSession(id) }
                }
            )
            try await session.start()
        }

        return id
    }

    func sendClaudeMessage(_ message: String, to sessionId: String) async {
        await claudeSessions[sessionId]?.sendMessage(message)
    }

    func closeClaudeSession(_ sessionId: String) async {
        await claudeSessions[sessionId]?.terminate()
        claudeSessions.removeValue(forKey: sessionId)
    }

    func listClaudeSessions() -> [String] {
        Array(claudeSessions.keys)
    }

    private func removeClaudeSession(_ id: String) {
        claudeSessions.removeValue(forKey: id)
    }

    // MARK: - All Sessions

    func listAllSessions() -> (terminals: [String], claude: [String]) {
        (terminals: Array(sessions.keys), claude: Array(claudeSessions.keys))
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

        process.environment = ProcessInfo.processInfo.environment

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.onOutput?(text)
        }

        try process.run()
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
