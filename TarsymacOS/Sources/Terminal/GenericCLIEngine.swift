import Foundation
import TarsyShared

actor GenericCLIEngine: AIEngine {
    let id: String
    let engineType: AIEngineType
    let workspacePath: String
    let command: String
    let apiKey: String?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var isRunning = false

    private var onOutput: (@Sendable (String) -> Void)?
    private var onComplete: (@Sendable (String) -> Void)?
    private var onAskUser: (@Sendable (String, [String]) -> Void)?

    init(id: String, engineType: AIEngineType, workspacePath: String, command: String? = nil, apiKey: String? = nil) {
        self.id = id
        self.engineType = engineType
        self.workspacePath = workspacePath
        self.command = command ?? engineType.defaultCommand ?? "echo"
        self.apiKey = apiKey
    }

    func setHandlers(
        onOutput: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String) -> Void
    ) {
        self.onOutput = onOutput
        self.onComplete = onComplete
    }

    func setAskUserHandler(_ handler: @escaping @Sendable (String, [String]) -> Void) {
        self.onAskUser = handler
    }

    func start() throws {
        let expandedPath = (workspacePath as NSString).expandingTildeInPath
        let cliPath = findCLI()

        print("[GenericCLI] Starting \(engineType.displayName) session \(id) at \(expandedPath)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = argsForEngine()
        proc.currentDirectoryURL = URL(fileURLWithPath: expandedPath)

        var env = ProcessInfo.processInfo.environment
        // Inject API key if provided
        if let key = apiKey, let envVar = engineType.envKeyName {
            env[envVar] = key
        }
        env["TERM"] = "dumb"
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Stream stdout in real time
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.onOutput?(text) }
        }

        // Also capture stderr as output
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.onOutput?(text) }
        }

        proc.terminationHandler = { [weak self] _ in
            Task { await self?.handleExit() }
        }

        try proc.run()

        self.process = proc
        self.stdinPipe = stdin
        self.isRunning = true

        print("[GenericCLI] \(engineType.displayName) session \(id) started with PID \(proc.processIdentifier)")
        onOutput?("\(engineType.displayName) ready. Send a message to start.\n")
    }

    func sendMessage(_ message: String) {
        guard let pipe = stdinPipe else {
            print("[GenericCLI] Cannot send — no stdin pipe")
            return
        }

        print("[GenericCLI] Sending to \(engineType.displayName): \(message.prefix(80))...")

        if let data = "\(message)\n".data(using: .utf8) {
            pipe.fileHandleForWriting.write(data)
        }
    }

    func respondToQuestion(_ answer: String) {
        // Generic CLIs don't have structured questions — just send as input
        sendMessage(answer)
    }

    func terminate() {
        process?.terminate()
        process = nil
        stdinPipe = nil
        isRunning = false
    }

    // MARK: - Private

    private func handleExit() {
        isRunning = false
        onComplete?("Session ended")
        print("[GenericCLI] \(engineType.displayName) session \(id) exited")
    }

    private func argsForEngine() -> [String] {
        switch engineType {
        case .gemini:
            return [] // gemini CLI runs interactively
        case .codex:
            return [] // codex CLI runs interactively
        case .aider:
            return ["--no-auto-commits", "--no-git"]
        case .custom, .claude:
            return []
        }
    }

    private func findCLI() -> String {
        let searchPaths = [
            "/opt/homebrew/bin/\(command)",
            "\(NSHomeDirectory())/.local/bin/\(command)",
            "/usr/local/bin/\(command)",
            "\(NSHomeDirectory())/.npm-global/bin/\(command)",
            "\(NSHomeDirectory())/.cargo/bin/\(command)",
            "\(NSHomeDirectory())/.pyenv/shims/\(command)"
        ]
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/opt/homebrew/bin/\(command)"
    }
}
