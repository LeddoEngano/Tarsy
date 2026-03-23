import Foundation

actor ClaudeCodeSession {
    let id: String
    let workspacePath: String
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var isRunning = false

    private var onOutput: (@Sendable (String) -> Void)?
    private var onComplete: (@Sendable (String) -> Void)?

    init(id: String, workspacePath: String) {
        self.id = id
        self.workspacePath = workspacePath
    }

    func setHandlers(
        onOutput: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String) -> Void
    ) {
        self.onOutput = onOutput
        self.onComplete = onComplete
    }

    func start(aiContext: String? = nil) throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        // Find claude CLI
        let claudePath = findClaudeCLI()

        let expandedPath = (workspacePath as NSString).expandingTildeInPath
        print("[ClaudeCode] Starting session \(id) at \(expandedPath) with CLI: \(claudePath)")

        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["--dangerously-skip-permissions"]
        process.currentDirectoryURL = URL(fileURLWithPath: expandedPath)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        // Remove CLAUDECODE env var to prevent "nested session" error
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE")
        // Inject AI context as system prompt via env if available
        if let ctx = aiContext, !ctx.isEmpty {
            env["CLAUDE_SYSTEM_PROMPT"] = ctx
        }
        process.environment = env

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.handleOutput(text) }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.handleOutput(text) }
        }

        process.terminationHandler = { [weak self] proc in
            Task { await self?.handleTermination(exitCode: proc.terminationStatus) }
        }

        try process.run()

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.isRunning = true

        print("[ClaudeCode] Session \(id) started in \(workspacePath)")
    }

    func sendMessage(_ message: String) {
        guard isRunning, let pipe = inputPipe else { return }
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        pipe.fileHandleForWriting.write(data)
    }

    func terminate() {
        process?.terminate()
        cleanup()
    }

    private func handleOutput(_ text: String) {
        onOutput?(text)
    }

    private func handleTermination(exitCode: Int32) {
        isRunning = false
        onComplete?("Session ended with exit code: \(exitCode)")
        cleanup()
    }

    private func cleanup() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        isRunning = false
    }

    private func findClaudeCLI() -> String {
        let paths = [
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.claude/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                print("[ClaudeCode] Found CLI at: \(path)")
                return path
            }
        }

        print("[ClaudeCode] WARNING: claude CLI not found in known paths")
        return "/opt/homebrew/bin/claude"
    }
}
