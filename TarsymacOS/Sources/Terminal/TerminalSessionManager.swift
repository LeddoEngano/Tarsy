import Foundation

actor TerminalSessionManager {
    private var sessions: [String: TerminalSession] = [:]

    func createSession(id: String = UUID().uuidString, workingDirectory: String? = nil) throws -> String {
        let session = try TerminalSession(id: id, workingDirectory: workingDirectory)
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

    func setOutputHandler(for sessionId: String, handler: @escaping (String) -> Void) {
        sessions[sessionId]?.onOutput = handler
    }
}

class TerminalSession {
    let id: String
    let process: Process
    let inputPipe: Pipe
    let outputPipe: Pipe
    var onOutput: ((String) -> Void)?

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
