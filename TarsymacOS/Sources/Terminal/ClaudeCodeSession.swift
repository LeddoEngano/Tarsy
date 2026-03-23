import Foundation

actor ClaudeCodeSession {
    let id: String
    let workspacePath: String
    let aiContext: String?
    private var masterFd: Int32 = -1
    private var childPid: pid_t = 0
    private var isRunning = false
    private var readSource: DispatchSourceRead?

    private var onOutput: (@Sendable (String) -> Void)?
    private var onComplete: (@Sendable (String) -> Void)?

    init(id: String, workspacePath: String, aiContext: String? = nil) {
        self.id = id
        self.workspacePath = workspacePath
        self.aiContext = aiContext
    }

    func setHandlers(
        onOutput: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String) -> Void
    ) {
        self.onOutput = onOutput
        self.onComplete = onComplete
    }

    func start() throws {
        let expandedPath = (workspacePath as NSString).expandingTildeInPath
        let claudePath = findClaudeCLI()

        print("[ClaudeCode] Starting interactive session \(id) at \(expandedPath)")

        // Build environment
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE")
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = "120"
        env["LINES"] = "40"

        if let ctx = aiContext, !ctx.isEmpty {
            env["CLAUDE_SYSTEM_PROMPT"] = ctx
        }

        // Convert env to C format
        let envStrings = env.map { "\($0.key)=\($0.value)" }
        let cEnv = envStrings.map { strdup($0) } + [nil]
        defer { cEnv.forEach { if let p = $0 { free(p) } } }

        // Build args
        let args = [claudePath, "--dangerously-skip-permissions"]
        let cArgs = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { if let p = $0 { free(p) } } }

        // Set window size
        var winSize = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)

        // Fork with PTY
        var masterFd: Int32 = 0
        let pid = forkpty(&masterFd, nil, nil, &winSize)

        if pid < 0 {
            throw ClaudeError.forkFailed
        }

        if pid == 0 {
            // Child process
            chdir(expandedPath)
            execve(claudePath, cArgs, cEnv)
            _exit(1)
        }

        // Parent process
        self.masterFd = masterFd
        self.childPid = pid
        self.isRunning = true

        // Read output from PTY
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(masterFd, &buffer, buffer.count)
            if bytesRead > 0 {
                if let text = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                    // Strip ANSI escape codes for clean output
                    let clean = text.stripANSI()
                    if !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Task { await self?.handleOutput(clean) }
                    }
                }
            } else if bytesRead <= 0 {
                Task { await self?.handleExit() }
            }
        }
        source.setCancelHandler {
            close(masterFd)
        }
        source.resume()
        self.readSource = source

        print("[ClaudeCode] Interactive session \(id) started with PID \(pid)")
    }

    func sendMessage(_ message: String) {
        guard isRunning, masterFd >= 0 else {
            print("[ClaudeCode] Cannot send — session not running")
            return
        }

        let input = message + "\n"
        print("[ClaudeCode] Sending input to session \(id): \(message.prefix(50))...")

        input.withCString { ptr in
            write(masterFd, ptr, strlen(ptr))
        }
    }

    func terminate() {
        if childPid > 0 {
            kill(childPid, SIGTERM)
        }
        readSource?.cancel()
        readSource = nil
        isRunning = false
        print("[ClaudeCode] Session \(id) terminated")
    }

    private func handleOutput(_ text: String) {
        onOutput?(text)
    }

    private func handleExit() {
        isRunning = false
        readSource?.cancel()
        readSource = nil
        onComplete?("Session ended")
        print("[ClaudeCode] Session \(id) exited")
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
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/opt/homebrew/bin/claude"
    }

    enum ClaudeError: LocalizedError {
        case forkFailed

        var errorDescription: String? {
            switch self {
            case .forkFailed: return "Failed to create PTY for Claude Code"
            }
        }
    }
}

extension String {
    func stripANSI() -> String {
        // Remove ANSI escape sequences (colors, cursor movement, etc.)
        guard let regex = try? NSRegularExpression(pattern: "\\x1b\\[[0-9;]*[a-zA-Z]|\\x1b\\][^\u{07}]*\u{07}|\\x1b\\[\\?[0-9;]*[a-zA-Z]", options: []) else {
            return self
        }
        return regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: "")
    }
}
