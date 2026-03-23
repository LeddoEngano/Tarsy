import Foundation

actor ClaudeCodeSession {
    let id: String
    let workspacePath: String
    let aiContext: String?
    private var conversationId: String?
    private var isProcessing = false

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
        // No-op for print mode — session is ready immediately
        print("[ClaudeCode] Session \(id) ready (print mode) at \(workspacePath)")
        onOutput?("Claude Code ready. Send a message to start.\n")
    }

    func sendMessage(_ message: String) {
        guard !message.isEmpty else { return }
        guard !isProcessing else {
            onOutput?("⏳ Still processing previous request...\n")
            return
        }

        isProcessing = true

        Task {
            let expandedPath = (workspacePath as NSString).expandingTildeInPath
            let claudePath = findClaudeCLI()

            print("[ClaudeCode] Processing message in session \(id): \(message.prefix(80))...")

            // Build args: use -p (print mode) for clean output
            var args = ["-p", message, "--dangerously-skip-permissions"]

            // Resume conversation if we have a previous session
            if let cid = conversationId {
                args.append(contentsOf: ["--resume", cid])
            }

            // System prompt from AI context
            if conversationId == nil, let ctx = aiContext, !ctx.isEmpty {
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
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            // Stream stdout in real-time
            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { await self?.onOutput?(text) }
            }

            // Capture stderr for conversation ID and errors
            let stderrAccumulator = StderrAccumulator()
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                stderrAccumulator.append(text)
            }

            do {
                try process.run()

                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().async {
                        process.waitUntilExit()
                        continuation.resume()
                    }
                }

                // Flush pipes
                try? await Task.sleep(nanoseconds: 200_000_000)
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                // Try to extract conversation ID from stderr for --resume
                let stderr = stderrAccumulator.value
                if let cid = extractConversationId(from: stderr) {
                    conversationId = cid
                    print("[ClaudeCode] Got conversation ID: \(cid)")
                }

                if process.terminationStatus != 0 && !stderr.isEmpty {
                    onOutput?("\n⚠️ \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))\n")
                }

                print("[ClaudeCode] Message processed, exit code: \(process.terminationStatus)")

            } catch {
                print("[ClaudeCode] Failed: \(error)")
                onOutput?("\n❌ Error: \(error.localizedDescription)\n")
            }

            isProcessing = false
            onComplete?("done")
        }
    }

    func terminate() {
        print("[ClaudeCode] Session \(id) terminated")
    }

    private func extractConversationId(from stderr: String) -> String? {
        // Claude CLI outputs conversation/session ID to stderr
        // Look for patterns like "conversation: abc123" or session IDs
        let patterns = [
            #"(?:conversation|session|resume)[:\s]+([a-zA-Z0-9_-]{8,})"#,
            #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)),
               let range = Range(match.range(at: 1), in: stderr) {
                return String(stderr[range])
            }
        }
        return nil
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

private class StderrAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""
    var value: String { lock.lock(); defer { lock.unlock() }; return _value }
    func append(_ text: String) { lock.lock(); _value += text; lock.unlock() }
}
