import Foundation

actor ClaudeCodeSession {
    let id: String
    let workspacePath: String
    let aiContext: String?
    private var masterFd: Int32 = -1
    private var childPid: pid_t = 0
    private var isRunning = false
    private var readSource: DispatchSourceRead?
    private var lastSentMessage: String?
    private var hasReceivedInitialPrompt = false

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

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE")
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        env["COLUMNS"] = "200"
        env["LINES"] = "50"

        if let ctx = aiContext, !ctx.isEmpty {
            env["CLAUDE_SYSTEM_PROMPT"] = ctx
        }

        let envStrings = env.map { "\($0.key)=\($0.value)" }
        let cEnv = envStrings.map { strdup($0) } + [nil]
        defer { cEnv.forEach { if let p = $0 { free(p) } } }

        let args = [claudePath, "--dangerously-skip-permissions"]
        let cArgs = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { if let p = $0 { free(p) } } }

        var winSize = winsize(ws_row: 50, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = 0
        let pid = forkpty(&fd, nil, nil, &winSize)

        if pid < 0 { throw ClaudeError.forkFailed }

        if pid == 0 {
            chdir(expandedPath)
            execve(claudePath, cArgs, cEnv)
            _exit(1)
        }

        self.masterFd = fd
        self.childPid = pid
        self.isRunning = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                if let text = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                    Task { await self?.processOutput(text) }
                }
            } else if bytesRead <= 0 {
                Task { await self?.handleExit() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.readSource = source

        print("[ClaudeCode] Interactive session \(id) started with PID \(pid)")
    }

    func sendMessage(_ message: String) {
        guard isRunning, masterFd >= 0 else {
            print("[ClaudeCode] Cannot send — session not running")
            return
        }

        lastSentMessage = message
        let input = message + "\n"
        print("[ClaudeCode] Sending: \(message.prefix(80))...")

        input.withCString { ptr in
            write(masterFd, ptr, strlen(ptr))
        }
    }

    func terminate() {
        if childPid > 0 { kill(childPid, SIGTERM) }
        readSource?.cancel()
        readSource = nil
        isRunning = false
    }

    private func processOutput(_ raw: String) {
        // Strip ANSI escape codes
        let cleaned = raw.stripANSI()

        // Skip empty output
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Skip the initial Claude prompt/banner (first output before user sends anything)
        if !hasReceivedInitialPrompt {
            hasReceivedInitialPrompt = true
            // Don't skip — let the user see the initial ready state
            if trimmed.contains("Claude Code") || trimmed.contains("~/") {
                onOutput?("Claude Code ready.\n")
                return
            }
        }

        // Filter out the echoed input (PTY echoes what we type)
        if let sent = lastSentMessage {
            if trimmed == sent || trimmed.hasPrefix(sent) {
                // This is just the echo of our input, skip it
                let remainder = String(trimmed.dropFirst(sent.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if remainder.isEmpty {
                    return
                }
            }
            // After first real output, clear the sent message
            if !trimmed.contains(sent) {
                lastSentMessage = nil
            }
        }

        // Filter out prompt lines (status bar stuff)
        let lines = cleaned.components(separatedBy: "\n")
        let filteredLines = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty lines at start
            if t.isEmpty { return true }
            // Skip prompt/status bar patterns
            if t.hasPrefix("~/") && t.contains("|") { return false } // ~/project (main)| Opus 4.6
            if t.contains("MCP servers") { return false }
            if t.contains("bypass permissions") { return false }
            if t.contains("shift+tab") { return false }
            if t.contains("ctrl+g") { return false }
            if t.contains("Update available") { return false }
            if t.contains("brew upgrade") { return false }
            if t == "─" || t.allSatisfy({ $0 == "─" || $0 == " " }) { return false } // Separator lines
            return true
        }

        let filtered = filteredLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !filtered.isEmpty {
            onOutput?(filtered + "\n")
        }
    }

    private func handleExit() {
        isRunning = false
        readSource?.cancel()
        readSource = nil
        onComplete?("Session ended")
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
        var errorDescription: String? { "Failed to create PTY for Claude Code" }
    }
}

extension String {
    func stripANSI() -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "\\x1b\\[[0-9;]*[a-zA-Z]|\\x1b\\][^\u{07}\u{1b}]*(?:\u{07}|\\x1b\\\\)|\\x1b\\[\\?[0-9;]*[a-zA-Z]|\\x1b[()][0-9A-B]|\\x1b\\[[0-9]*[ABCDJKH]|\\r",
            options: []
        ) else { return self }
        return regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: "")
    }
}
