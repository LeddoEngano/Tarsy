import Foundation
import TarsyShared

/// Runs CLI coding agents. Uses structured JSONL output for Codex and Gemini,
/// and plain text headless mode for other CLIs (Aider, etc.).
actor GenericCLIEngine: AIEngine {
    let id: String
    let engineType: AIEngineType
    let workspacePath: String
    let command: String
    let apiKey: String?
    let permissionMode: AgentPermissionConfig.PermissionMode
    private var isRunning = false

    private var currentProcess: Process?

    private var onOutput: (@Sendable (String) -> Void)?
    private var onComplete: (@Sendable (String) -> Void)?
    private var onAskUser: (@Sendable (String, [String]) -> Void)?
    private var onStatusUpdate: (@Sendable (String, Int, Int, Int) -> Void)?

    // Line buffer for JSONL streaming (Codex/Gemini)
    private var lineBuffer: String = ""
    // Accumulated message text for Gemini delta streaming
    private var geminiMessageBuffer: String = ""

    /// Whether this engine uses structured JSONL output
    private var usesStructuredOutput: Bool {
        engineType == .gemini
    }

    init(id: String, engineType: AIEngineType, workspacePath: String, command: String? = nil, apiKey: String? = nil, permissionMode: AgentPermissionConfig.PermissionMode = .dangerous) {
        self.id = id
        self.engineType = engineType
        self.workspacePath = workspacePath
        self.command = command ?? engineType.defaultCommand ?? "echo"
        self.apiKey = apiKey
        self.permissionMode = permissionMode
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

    func setStatusHandler(_ handler: @escaping @Sendable (String, Int, Int, Int) -> Void) {
        self.onStatusUpdate = handler
    }

    func start() throws {
        isRunning = true
        onOutput?("\(engineType.readyMessage)\n")
    }

    func sendMessage(_ message: String) {
        guard isRunning else { return }

        // Kill any previous in-flight request
        currentProcess?.terminate()
        currentProcess = nil
        lineBuffer = ""
        geminiMessageBuffer = ""

        let cliPath = findCLI()
        let expandedPath = (workspacePath as NSString).expandingTildeInPath
        let args = argsForEngine(message: message)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: expandedPath)
        proc.environment = buildEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        let onOutput = self.onOutput

        if usesStructuredOutput {
            // JSONL mode: buffer lines and parse structured events
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { await self?.appendAndProcessLines(text) }
            }
        } else {
            // Plain text mode for other engines
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                let cleaned = GenericCLIEngine.stripAnsi(text)
                if !cleaned.isEmpty {
                    onOutput?(cleaned)
                }
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let cleaned = GenericCLIEngine.stripAnsi(text)
            let lower = cleaned.lowercased()
            let isNoise = lower.contains("cached credentials") ||
                          lower.contains("loaded cached") ||
                          lower.contains("warning:") ||
                          lower.contains("256-color") ||
                          cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !isNoise {
                onOutput?(cleaned)
            }
        }

        let onComplete = self.onComplete
        proc.terminationHandler = { [weak self] _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            Task { await self?.flushLineBuffer() }
            onComplete?("")
        }

        do {
            try proc.run()
            currentProcess = proc
        } catch {
            onOutput?("Error: \(error.localizedDescription)\n")
        }
    }

    func respondToQuestion(_ answer: String) {
        // Headless mode: questions are handled by sending a new message
        sendMessage(answer)
    }

    func interrupt() {
        currentProcess?.interrupt()
    }

    func terminate() {
        isRunning = false
        currentProcess?.terminate()
        currentProcess = nil
        onComplete?("Session ended")
    }

    // MARK: - Line Buffering (JSONL)

    private func appendAndProcessLines(_ text: String) {
        lineBuffer += text
        while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIndex)...])
            guard !line.isEmpty else { continue }
            handleJsonLine(line)
        }
    }

    private func flushLineBuffer() {
        let remaining = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        lineBuffer = ""
        guard !remaining.isEmpty else { return }
        handleJsonLine(remaining)
    }

    // MARK: - JSONL Event Routing

    private func handleJsonLine(_ jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            // Not valid JSON — output as plain text
            let cleaned = GenericCLIEngine.stripAnsi(jsonLine)
            if !cleaned.isEmpty { onOutput?(cleaned) }
            return
        }

        switch engineType {
        case .gemini:
            handleGeminiEvent(type: type, json: json)
        default:
            break
        }
    }

    // MARK: - Gemini JSONL Events (--output-format stream-json)

    private func handleGeminiEvent(type: String, json: [String: Any]) {
        switch type {
        case "init":
            let model = json["model"] as? String ?? "gemini"
            #if DEBUG
            print("[Gemini] Session init: model=\(model)")
            #endif

        case "message":
            let role = json["role"] as? String ?? ""
            let content = json["content"] as? String ?? ""
            let isDelta = json["delta"] as? Bool ?? false

            if role == "assistant" && !content.isEmpty {
                if isDelta {
                    // Delta mode: accumulate and output chunk
                    geminiMessageBuffer += content
                    onOutput?(content)
                } else {
                    // Full message: output directly
                    geminiMessageBuffer = content
                    onOutput?(content)
                }
            }

        case "tool_use":
            let toolName = json["tool_name"] as? String ?? "tool"
            let toolId = json["tool_id"] as? String ?? ""
            if let params = json["parameters"] as? [String: Any] {
                let desc = params["command"] as? String
                    ?? params["file_path"] as? String
                    ?? params["query"] as? String
                    ?? params["pattern"] as? String
                    ?? ""
                onOutput?("🔧 \(toolName): \(desc)\n")
            } else {
                onOutput?("🔧 \(toolName)\n")
            }
            _ = toolId // suppress unused warning

        case "tool_result":
            let status = json["status"] as? String ?? ""
            if status == "error", let error = json["error"] as? String {
                onOutput?("⚠️ Tool error: \(error)\n")
            }

        case "result":
            let status = json["status"] as? String ?? "unknown"
            if let stats = json["stats"] as? [String: Any] {
                let inputTokens = stats["input_tokens"] as? Int ?? stats["input"] as? Int ?? 0
                let outputTokens = stats["output_tokens"] as? Int ?? stats["output"] as? Int ?? 0
                // Gemini 2.5 Pro has 1M context window; pass it so iOS doesn't use 200K fallback
                onStatusUpdate?("gemini", inputTokens, outputTokens, 1_000_000)
            }
            if status == "error" {
                if let errorMsg = json["error"] as? String {
                    onOutput?("❌ \(errorMsg)\n")
                } else if let errorObj = json["error"] as? [String: Any],
                          let msg = errorObj["message"] as? String {
                    onOutput?("❌ \(msg)\n")
                }
            }

        case "error":
            let severity = json["severity"] as? String ?? "error"
            let message = json["message"] as? String ?? "Unknown error"
            if severity == "error" {
                onOutput?("❌ \(message)\n")
            } else {
                onOutput?("⚠️ \(message)\n")
            }

        default:
            break
        }
    }

    // MARK: - Private

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
        let home = realHome.isEmpty ? (env["HOME"] ?? NSHomeDirectory()) : realHome
        env["HOME"] = home

        var extraPaths: [String] = []
        let candidates = [
            "/opt/homebrew/bin",
            "\(home)/.local/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims",
        ]
        for p in candidates where FileManager.default.fileExists(atPath: p) {
            extraPaths.append(p)
        }
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                let binPath = "\(nvmDir)/\(v)/bin"
                if FileManager.default.fileExists(atPath: binPath) {
                    extraPaths.append(binPath)
                }
            }
        }
        let fnmDir = "\(home)/.local/share/fnm/node-versions"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: fnmDir) {
            for v in versions {
                let binPath = "\(fnmDir)/\(v)/installation/bin"
                if FileManager.default.fileExists(atPath: binPath) {
                    extraPaths.append(binPath)
                }
            }
        }
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")

        if let key = apiKey, let envVar = engineType.envKeyName {
            env[envVar] = key
        }
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"

        return env
    }

    /// Sanitize user message to prevent CLI flag injection.
    /// Process arguments don't go through a shell, but the message could still
    /// inject flags into the target CLI (e.g., --system-prompt for Gemini).
    private func sanitizeMessage(_ message: String) -> String {
        var msg = message
        // Strip leading dashes that could be interpreted as CLI flags
        while msg.hasPrefix("-") {
            msg = String(msg.dropFirst())
        }
        // Strip null bytes which can truncate strings in C-based CLIs
        msg = msg.replacingOccurrences(of: "\0", with: "")
        // Limit message length to prevent memory abuse (256KB is generous for any prompt)
        let maxLength = 256 * 1024
        if msg.count > maxLength {
            msg = String(msg.prefix(maxLength))
        }
        return msg.trimmingCharacters(in: .whitespaces)
    }

    /// Build CLI arguments per engine.
    /// Uses `--` (end-of-options marker) before positional arguments where supported
    /// to prevent message content from being interpreted as flags.
    private func argsForEngine(message: String) -> [String] {
        let safeMessage = sanitizeMessage(message)
        switch engineType {
        case .gemini:
            // gemini -p "prompt" --output-format stream-json [--yolo | --approval-mode auto_edit]
            // -p takes the next arg as the prompt value, so safeMessage is already positional to -p
            var args = ["-p", safeMessage, "--output-format", "stream-json"]
            if permissionMode == .dangerous {
                args.append("--yolo")
            } else {
                args.append(contentsOf: ["--approval-mode", "auto_edit"])
            }
            return args
        case .codex:
            // Codex is handled by CodexSession — this fallback should not be reached
            // Use `--` to prevent message from being parsed as flags
            return ["--", safeMessage]
        case .aider:
            var args = ["--message", safeMessage]
            if permissionMode != .dangerous {
                args.append(contentsOf: ["--no-auto-commits", "--no-git"])
            }
            return args
        case .cursor:
            return ["--", safeMessage]
        case .windsurf:
            return ["--", safeMessage]
        case .amp:
            return ["--prompt", safeMessage]
        case .cline:
            return ["--prompt", safeMessage]
        case .copilot:
            return ["copilot", "--", safeMessage]
        case .custom, .claude:
            return ["--", safeMessage]
        }
    }

    /// Strips ANSI escape sequences from output.
    nonisolated static func stripAnsi(_ input: String) -> String {
        var result = input
        let esc = "\u{1b}"

        // Strip CSI sequences
        result = result.replacingOccurrences(
            of: "\(esc)\\[[0-9;?]*[A-Za-z@-~]",
            with: "",
            options: .regularExpression
        )
        // Strip OSC sequences
        result = result.replacingOccurrences(
            of: "\(esc)\\][^\u{07}\(esc)]*(?:\u{07}|\(esc)\\\\)",
            with: "",
            options: .regularExpression
        )
        // Strip remaining ESC
        result = result.replacingOccurrences(of: esc, with: "")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findCLI() -> String {
        if let path = AgentDetector.agentPath(for: engineType) {
            return path
        }
        return "/usr/bin/env"
    }
}
