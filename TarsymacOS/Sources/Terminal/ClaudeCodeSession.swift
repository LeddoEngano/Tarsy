import Foundation

actor ClaudeCodeSession {
    let id: String
    let workspacePath: String
    let aiContext: String?
    private var sessionId: String?
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
        print("[ClaudeCode] Session \(id) ready at \(workspacePath)")
        onOutput?("Claude Code ready. Send a message to start.\n")
    }

    func sendMessage(_ message: String) {
        guard !message.isEmpty else { return }
        guard !isProcessing else {
            onOutput?("Still processing previous request...\n")
            return
        }

        isProcessing = true

        Task {
            let expandedPath = (workspacePath as NSString).expandingTildeInPath
            let claudePath = findClaudeCLI()

            print("[ClaudeCode] Processing: \(message.prefix(80))...")

            var args = ["-p", message, "--dangerously-skip-permissions", "--output-format", "json"]

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
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            // Accumulate JSON output
            let outputAccumulator = ThreadSafeAccumulator()
            let stderrAccumulator = ThreadSafeAccumulator()

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                outputAccumulator.append(text)
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                stderrAccumulator.append(text)
            }

            do {
                try process.run()

                // Process is running — output will come when done

                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().async {
                        process.waitUntilExit()
                        continuation.resume()
                    }
                }

                try? await Task.sleep(nanoseconds: 200_000_000)
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let jsonOutput = outputAccumulator.value
                let stderr = stderrAccumulator.value

                // Parse JSON response
                if let data = jsonOutput.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                    // Extract session ID for conversation continuity
                    if let sid = json["session_id"] as? String {
                        sessionId = sid
                        print("[ClaudeCode] Session ID: \(sid)")
                    }

                    // Send the clean result text
                    if let result = json["result"] as? String, !result.isEmpty {
                        onOutput?(result)
                    } else if let isError = json["is_error"] as? Bool, isError {
                        onOutput?("Error: \(json["result"] as? String ?? "Unknown error")")
                    }

                } else if !jsonOutput.isEmpty {
                    // Fallback: send raw output if JSON parsing fails
                    onOutput?(jsonOutput)
                }

                if process.terminationStatus != 0 && !stderr.isEmpty {
                    let cleanStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanStderr.isEmpty && !cleanStderr.contains("Update available") {
                        onOutput?("\n⚠️ \(cleanStderr)")
                    }
                }

                print("[ClaudeCode] Done, exit code: \(process.terminationStatus)")

            } catch {
                print("[ClaudeCode] Failed: \(error)")
                onOutput?("Error: \(error.localizedDescription)")
            }

            isProcessing = false
            onComplete?("done")
        }
    }

    func terminate() {
        print("[ClaudeCode] Session \(id) terminated")
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

private class ThreadSafeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""
    var value: String { lock.lock(); defer { lock.unlock() }; return _value }
    func append(_ text: String) { lock.lock(); _value += text; lock.unlock() }
}
