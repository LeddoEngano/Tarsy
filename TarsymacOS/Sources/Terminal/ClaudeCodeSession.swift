import Foundation

actor ClaudeCodeSession {
    let id: String
    let workspacePath: String
    let aiContext: String?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var isRunning = false
    private var sessionId: String?

    private var onOutput: (@Sendable (String) -> Void)?
    private var onComplete: (@Sendable (String) -> Void)?
    private var onAskUser: (@Sendable (String, [String]) -> Void)?

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

    func setAskUserHandler(_ handler: @escaping @Sendable (String, [String]) -> Void) {
        self.onAskUser = handler
    }

    func start() throws {
        let expandedPath = (workspacePath as NSString).expandingTildeInPath
        let claudePath = findClaudeCLI()

        print("[ClaudeCode] Starting bidirectional session \(id) at \(expandedPath)")

        var args = [
            "-p",
            "--dangerously-skip-permissions",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose"
        ]

        if let ctx = aiContext, !ctx.isEmpty {
            args.append(contentsOf: ["--system-prompt", ctx])
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: expandedPath)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE")
        env["TERM"] = "dumb"
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Process stream-json output line by line
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                Task { await self?.handleStreamEvent(trimmed) }
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { _ in }

        proc.terminationHandler = { [weak self] _ in
            Task { await self?.handleExit() }
        }

        try proc.run()

        self.process = proc
        self.stdinPipe = stdin
        self.isRunning = true

        print("[ClaudeCode] Session \(id) started with PID \(proc.processIdentifier)")
        onOutput?("Claude Code ready. Send a message to start.\n")
    }

    func sendMessage(_ message: String) {
        guard isRunning, let pipe = stdinPipe else {
            print("[ClaudeCode] Cannot send — not running")
            return
        }

        print("[ClaudeCode] Sending message: \(message.prefix(80))...")

        // Send as stream-json user message
        let msg: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": message]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: msg),
           var jsonStr = String(data: data, encoding: .utf8) {
            jsonStr += "\n"
            if let bytes = jsonStr.data(using: .utf8) {
                pipe.fileHandleForWriting.write(bytes)
            }
        }
    }

    func respondToQuestion(_ answer: String) {
        guard isRunning, let pipe = stdinPipe else { return }

        print("[ClaudeCode] Responding to question: \(answer)")

        // Send user response for AskUserQuestion
        let msg: [String: Any] = [
            "type": "user",
            "content": answer
        ]

        if let data = try? JSONSerialization.data(withJSONObject: msg),
           var jsonStr = String(data: data, encoding: .utf8) {
            jsonStr += "\n"
            if let bytes = jsonStr.data(using: .utf8) {
                pipe.fileHandleForWriting.write(bytes)
            }
        }
    }

    func terminate() {
        process?.terminate()
        process = nil
        stdinPipe = nil
        isRunning = false
    }

    // MARK: - Stream Event Handling

    private func handleStreamEvent(_ jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "assistant":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    guard let blockType = block["type"] as? String else { continue }
                    if blockType == "text", let text = block["text"] as? String {
                        onOutput?(text)
                    }
                    if blockType == "tool_use" {
                        handleToolUse(block)
                    }
                }
            }

        case "result":
            if let sid = json["session_id"] as? String {
                sessionId = sid
            }

        case "system":
            if let subtype = json["subtype"] as? String, subtype == "init" {
                if let sid = json["session_id"] as? String {
                    sessionId = sid
                    print("[ClaudeCode] Session initialized: \(sid)")
                }
            }

        default:
            break
        }
    }

    private func handleToolUse(_ block: [String: Any]) {
        guard let name = block["name"] as? String else { return }

        if name == "AskUserQuestion" {
            if let input = block["input"] as? [String: Any] {
                let question = input["question"] as? String ?? input["text"] as? String ?? "Question from Claude"
                var options: [String] = []

                if let opts = input["options"] as? [String] { options = opts }
                else if let choices = input["choices"] as? [String] { options = choices }
                else if let opts = input["options"] as? [[String: Any]] {
                    options = opts.compactMap { $0["label"] as? String ?? $0["value"] as? String }
                }

                print("[ClaudeCode] AskUserQuestion: \(question), options: \(options)")
                onOutput?("\n📋 \(question)\n")
                onAskUser?(question, options)
            }
        } else {
            // Show tool activity
            if let input = block["input"] as? [String: Any] {
                let desc = input["command"] as? String
                    ?? input["file_path"] as? String
                    ?? input["query"] as? String
                    ?? name
                onOutput?("🔧 \(name): \(desc)\n")
            }
        }
    }

    private func handleExit() {
        isRunning = false
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
}
