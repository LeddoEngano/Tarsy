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
        onOutput: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String) -> Void,
        onAskUser: @escaping @Sendable (String, [String]) -> Void = { _, _ in }
    ) throws -> String {
        let session = ClaudeCodeSession(id: id, workspacePath: workspacePath, aiContext: aiContext)
        claudeSessions[id] = session

        Task {
            await session.setHandlers(onOutput: onOutput, onComplete: { [weak self] (msg: String) in
                onComplete(msg)
                Task { await self?.removeClaudeSession(id) }
            })
            await session.setAskUserHandler(onAskUser)
            try await session.start()
        }

        return id
    }

    func setClaudeStatusHandler(sessionId: String, handler: @escaping @Sendable (String, Int, Int) -> Void) async {
        await claudeSessions[sessionId]?.setStatusHandler(handler)
    }

    func sendClaudeMessage(_ message: String, images imagesJson: String? = nil, to sessionId: String) async {
        await claudeSessions[sessionId]?.sendMessage(message, imagesJson: imagesJson)
    }

    func respondToClaudeQuestion(_ answer: String, sessionId: String) async {
        await claudeSessions[sessionId]?.respondToQuestion(answer)
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

    // MARK: - Generic Engine Sessions (Multi-Provider)

    func createEngineSession(
        id: String = UUID().uuidString,
        engineType: AIEngineType,
        workspacePath: String,
        command: String? = nil,
        apiKey: String? = nil,
        onOutput: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String) -> Void,
        onAskUser: @escaping @Sendable (String, [String]) -> Void = { _, _ in }
    ) throws -> String {
        let engine: any AIEngine

        if engineType == .claude {
            let session = ClaudeCodeSession(id: id, workspacePath: workspacePath)
            claudeSessions[id] = session
            engine = session
        } else {
            let session = GenericCLIEngine(id: id, engineType: engineType, workspacePath: workspacePath, command: command, apiKey: apiKey)
            engine = session
        }

        engineSessions[id] = engine

        Task {
            await engine.setHandlers(onOutput: onOutput, onComplete: { [weak self] (msg: String) in
                onComplete(msg)
                Task { await self?.removeEngineSession(id) }
            })
            await engine.setAskUserHandler(onAskUser)
            try await engine.start()
        }

        return id
    }

    func sendEngineMessage(_ message: String, to sessionId: String) async {
        await engineSessions[sessionId]?.sendMessage(message)
    }

    func respondToEngineQuestion(_ answer: String, sessionId: String) async {
        await engineSessions[sessionId]?.respondToQuestion(answer)
    }

    func closeEngineSession(_ sessionId: String) async {
        await engineSessions[sessionId]?.terminate()
        engineSessions.removeValue(forKey: sessionId)
        claudeSessions.removeValue(forKey: sessionId)
    }

    private func removeEngineSession(_ id: String) {
        engineSessions.removeValue(forKey: id)
        claudeSessions.removeValue(forKey: id)
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
