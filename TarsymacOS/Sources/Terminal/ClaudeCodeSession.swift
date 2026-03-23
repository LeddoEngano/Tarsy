import Foundation

actor ClaudeCodeSession {
    let id: String
    let workspacePath: String
    let aiContext: String?
    private var sessionId: String?
    private var isProcessing = false
    private var currentProcess: Process?
    private var stdinPipe: Pipe?

    private var onOutput: (@Sendable (String) -> Void)?
    private var onComplete: (@Sendable (String) -> Void)?
    // Called when AskUserQuestion tool is invoked — sends question + options to iOS
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
        print("[ClaudeCode] Session \(id) ready at \(workspacePath)")
        onOutput?("Claude Code ready. Send a message to start.\n")
    }

    func sendMessage(_ message: String) {
        guard !message.isEmpty else { return }
        guard !isProcessing else {
            onOutput?("⏳ Still processing...\n")
            return
        }

        isProcessing = true

        Task {
            await runClaude(message: message)
            isProcessing = false
            onComplete?("done")
        }
    }

    /// Called when user selects an option from AskUserQuestion
    func respondToQuestion(_ answer: String) {
        guard let pipe = stdinPipe else {
            print("[ClaudeCode] No stdin pipe to respond to")
            return
        }

        // Send the user's answer as a stream-json input
        let response: [String: Any] = [
            "type": "user_tool_result",
            "content": answer
        ]

        if let data = try? JSONSerialization.data(withJSONObject: response),
           var jsonStr = String(data: data, encoding: .utf8) {
            jsonStr += "\n"
            if let bytes = jsonStr.data(using: .utf8) {
                pipe.fileHandleForWriting.write(bytes)
                print("[ClaudeCode] Sent user response: \(answer)")
            }
        }
    }

    func terminate() {
        currentProcess?.terminate()
        currentProcess = nil
        stdinPipe = nil
        isProcessing = false
    }

    // MARK: - Private

    private func runClaude(message: String) async {
        let expandedPath = (workspacePath as NSString).expandingTildeInPath
        let claudePath = findClaudeCLI()

        print("[ClaudeCode] Running: \(message.prefix(80))...")

        var args = [
            "-p", message,
            "--dangerously-skip-permissions",
            "--output-format", "stream-json",
            "--verbose"
        ]

        if let sid = sessionId {
            args.append(contentsOf: ["--resume", sid])
        }

        if sessionId == nil, let ctx = aiContext, !ctx.isEmpty {
            args.append(contentsOf: ["--system-prompt", ctx])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: expandedPath)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE")
        env["TERM"] = "dumb"
        process.environment = env

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe

        self.currentProcess = process
        self.stdinPipe = inputPipe

        // Process stream-json output line by line
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

            // Each line is a JSON event
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                Task { await self?.handleStreamEvent(trimmed) }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { _ in
            // Ignore stderr (verbose logs)
        }

        do {
            try process.run()

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    continuation.resume()
                }
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            self.currentProcess = nil
            self.stdinPipe = nil

            print("[ClaudeCode] Exit code: \(process.terminationStatus)")
        } catch {
            print("[ClaudeCode] Failed: \(error)")
            onOutput?("Error: \(error.localizedDescription)\n")
        }
    }

    private func handleStreamEvent(_ jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "assistant":
            // Extract text content from assistant message
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if let blockType = block["type"] as? String {
                        if blockType == "text", let text = block["text"] as? String {
                            onOutput?(text)
                        }
                        if blockType == "tool_use" {
                            handleToolUse(block)
                        }
                    }
                }
            }

        case "result":
            // Final result — extract session_id
            if let sid = json["session_id"] as? String {
                sessionId = sid
            }
            // Send the final result text if we haven't already
            if let result = json["result"] as? String {
                // Only send if it's different from what we already streamed
                // (the stream already sent the text via assistant events)
                _ = result
            }

        default:
            break
        }
    }

    private func handleToolUse(_ block: [String: Any]) {
        guard let name = block["name"] as? String else { return }

        if name == "AskUserQuestion" || name == "askUserQuestion" {
            if let input = block["input"] as? [String: Any] {
                let question = input["question"] as? String ?? input["text"] as? String ?? "Question from Claude"
                var options: [String] = []

                // Extract options from various possible formats
                if let opts = input["options"] as? [String] {
                    options = opts
                } else if let choices = input["choices"] as? [String] {
                    options = choices
                } else if let opts = input["options"] as? [[String: Any]] {
                    options = opts.compactMap { $0["label"] as? String ?? $0["value"] as? String }
                }

                print("[ClaudeCode] AskUserQuestion: \(question), options: \(options)")
                onOutput?("\n📋 \(question)\n")
                onAskUser?(question, options)
            }
        } else {
            // Other tool use — show what's happening
            if let input = block["input"] as? [String: Any] {
                let description = input["command"] as? String
                    ?? input["file_path"] as? String
                    ?? input["query"] as? String
                    ?? name
                onOutput?("🔧 \(name): \(description)\n")
            }
        }
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
