import Foundation
import TarsyShared

actor ClaudeCodeSession: AIEngine {
    let id: String
    let engineType: AIEngineType = .claude
    let workspacePath: String
    let aiContext: String?
    let permissionMode: AgentPermissionConfig.PermissionMode
    private var process: Process?
    private var stdinPipe: Pipe?
    private var isRunning = false
    private var sessionId: String?

    private var onOutput: (@Sendable (String) -> Void)?
    private var onComplete: (@Sendable (String) -> Void)?
    private var onAskUser: (@Sendable (String, [String]) -> Void)?
    private var onPermissionRequest: (@Sendable (String, String, [String: Any]) -> Void)?
    private var onStatusUpdate: (@Sendable (String, Int, Int, Int) -> Void)?  // (model, input, output, contextWindow)
    private var onSessionId: (@Sendable (String) -> Void)?
    private var pendingAskUser = false // Track if last turn ended with AskUserQuestion
    private var lastInputTokens: Int = 0  // Latest turn's total input (includes cache tokens)
    private var lastOutputTokens: Int = 0  // Latest turn's output tokens
    private var lastModel: String = ""  // Last known model name
    private var lastContextWindow: Int = 0  // Context window from modelUsage
    private var lineBuffer: String = "" // Accumulates partial JSON lines between reads
    // Permission protocol state
    private var pendingPermissions: [String: [String: Any]] = [:]  // requestId -> tool input
    private var alwaysAllowedTools: Set<String> = []  // Session-level auto-approved tools

    init(id: String, workspacePath: String, aiContext: String? = nil, permissionMode: AgentPermissionConfig.PermissionMode = .dangerous) {
        self.id = id
        self.workspacePath = workspacePath
        self.aiContext = aiContext
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

    func setPermissionHandler(_ handler: @escaping @Sendable (String, String, [String: Any]) -> Void) {
        self.onPermissionRequest = handler
    }

    func setStatusHandler(_ handler: @escaping @Sendable (String, Int, Int, Int) -> Void) {
        self.onStatusUpdate = handler
    }

    func setSessionIdHandler(_ handler: @escaping @Sendable (String) -> Void) {
        self.onSessionId = handler
    }

    func start() throws {
        let expandedPath = (workspacePath as NSString).expandingTildeInPath
        let claudePath = findClaudeCLI()

        print("[ClaudeCode] Starting bidirectional session \(id) at \(expandedPath)")

        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose"
        ]

        if permissionMode == .dangerous {
            args.insert("--dangerously-skip-permissions", at: 1)
        } else {
            // Enable stdio-based permission prompts for remote approval from iOS
            args.append(contentsOf: ["--permission-prompt-tool", "stdio"])
        }

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
        // Fix sandbox HOME — use real user home for child processes
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
        if !realHome.isEmpty {
            env["HOME"] = realHome
        }
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Process stream-json output line by line with buffering.
        // Pipe reads can split a JSON line across multiple calls, so we
        // accumulate partial data and only process complete lines (\n-terminated).
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.appendAndProcessLines(text) }
        }

        stderr.fileHandleForReading.readabilityHandler = { _ in }

        proc.terminationHandler = { [weak self] _ in
            Task { await self?.flushLineBuffer(); await self?.handleExit() }
        }

        try proc.run()

        self.process = proc
        self.stdinPipe = stdin
        self.isRunning = true

        print("[ClaudeCode] Session \(id) started with PID \(proc.processIdentifier)")
        onOutput?("\(AIEngineType.claude.readyMessage)\n")
    }

    func sendMessage(_ message: String) {
        sendMessage(message, imagesJson: nil)
    }

    func sendMessage(_ message: String, imagesJson: String?) {
        guard isRunning, let pipe = stdinPipe else {
            print("[ClaudeCode] Cannot send — process not running")
            return
        }

        print("[ClaudeCode] Sending message (isRunning=\(isRunning), hasImages=\(imagesJson != nil)): \(message.prefix(80))...")

        // Build content: if images are provided, use multimodal content blocks
        let content: Any
        if let imagesJson = imagesJson,
           let imagesData = imagesJson.data(using: .utf8),
           let base64Strings = try? JSONSerialization.jsonObject(with: imagesData) as? [String],
           !base64Strings.isEmpty {
            var blocks: [[String: Any]] = []
            // Add image blocks first
            for b64 in base64Strings {
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": b64
                    ]
                ])
            }
            // Add text block
            if !message.isEmpty {
                blocks.append(["type": "text", "text": message])
            }
            content = blocks
        } else {
            content = message
        }

        let msg: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content]
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
        isRunning = false
        lineBuffer = ""
        stdinPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        stdinPipe = nil
    }

    // MARK: - Line Buffering

    /// Appends raw text to the line buffer and processes any complete lines.
    private func appendAndProcessLines(_ text: String) {
        lineBuffer += text
        while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIndex)...])
            guard !line.isEmpty else { continue }
            handleStreamEvent(line)
        }
    }

    /// Flush any remaining partial line in the buffer (called on process exit).
    private func flushLineBuffer() {
        let remaining = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        lineBuffer = ""
        guard !remaining.isEmpty else { return }
        handleStreamEvent(remaining)
    }

    // MARK: - Stream Event Handling

    private func handleStreamEvent(_ jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "assistant":
            pendingAskUser = false // Reset at start of new turn
            if let message = json["message"] as? [String: Any] {
                // Extract model info and usage (including cache tokens)
                if let model = message["model"] as? String {
                    lastModel = model
                    let usage = message["usage"] as? [String: Any]
                    let inputTokens = (usage?["input_tokens"] as? Int ?? 0)
                        + (usage?["cache_creation_input_tokens"] as? Int ?? 0)
                        + (usage?["cache_read_input_tokens"] as? Int ?? 0)
                    let outputTokens = usage?["output_tokens"] as? Int ?? 0
                    // Replace (not accumulate) — each turn's input already includes full conversation history
                    lastInputTokens = inputTokens
                    lastOutputTokens = outputTokens
                    onStatusUpdate?(model, lastInputTokens, lastOutputTokens, lastContextWindow)
                }

                if let content = message["content"] as? [[String: Any]] {
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
            }

        case "result":
            if let sid = json["session_id"] as? String {
                sessionId = sid
            }
            // Use modelUsage for most accurate token and context window data
            if let modelUsage = json["modelUsage"] as? [String: Any],
               let firstEntry = modelUsage.max(by: {
                   (($0.value as? [String: Any])?["inputTokens"] as? Int ?? 0) <
                   (($1.value as? [String: Any])?["inputTokens"] as? Int ?? 0)
               }),
               let data = firstEntry.value as? [String: Any] {
                let inputTokens = (data["inputTokens"] as? Int ?? 0)
                    + (data["cacheReadInputTokens"] as? Int ?? 0)
                    + (data["cacheCreationInputTokens"] as? Int ?? 0)
                let outputTokens = data["outputTokens"] as? Int ?? 0
                lastInputTokens = inputTokens
                lastOutputTokens = outputTokens
                if let cw = data["contextWindow"] as? Int { lastContextWindow = cw }
                // Extract clean model name from key (e.g., "claude-opus-4-6[1m]" → "claude-opus-4-6")
                let cleanModel = firstEntry.key.replacingOccurrences(of: "\\[.*\\]", with: "", options: .regularExpression)
                if !cleanModel.isEmpty { lastModel = cleanModel }
                onStatusUpdate?(lastModel, lastInputTokens, lastOutputTokens, lastContextWindow)
            } else if let usage = json["usage"] as? [String: Any] {
                // Fallback to top-level usage
                let inputTokens = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                let outputTokens = usage["output_tokens"] as? Int ?? 0
                lastInputTokens = inputTokens
                lastOutputTokens = outputTokens
                onStatusUpdate?(lastModel, lastInputTokens, lastOutputTokens, lastContextWindow)
            }
            // Result means the agent finished processing this message
            // But NOT if the turn ended with AskUserQuestion (agent is waiting for user input)
            if !pendingAskUser {
                let resultText = json["result"] as? String ?? "Task completed"
                onComplete?(resultText)
            }

        case "system":
            if let subtype = json["subtype"] as? String, subtype == "init" {
                if let sid = json["session_id"] as? String {
                    sessionId = sid
                    print("[ClaudeCode] Session initialized: \(sid)")
                    onSessionId?(sid)
                }
            }

        case "control_request":
            handleControlRequest(json)

        default:
            break
        }
    }

    private func handleToolUse(_ block: [String: Any]) {
        guard let name = block["name"] as? String else { return }

        if name == "AskUserQuestion" {
            pendingAskUser = true
            if let input = block["input"] as? [String: Any] {
                // Build a structured questions array to send to iOS
                var questionsPayload: [[String: Any]] = []

                if let questions = input["questions"] as? [[String: Any]] {
                    for q in questions {
                        let question = q["question"] as? String ?? ""
                        let header = q["header"] as? String ?? ""
                        let multiSelect = q["multiSelect"] as? Bool ?? false
                        var optionLabels: [String] = []

                        if let opts = q["options"] as? [[String: Any]] {
                            optionLabels = opts.compactMap { $0["label"] as? String }
                        } else if let opts = q["options"] as? [String] {
                            optionLabels = opts
                        }

                        questionsPayload.append([
                            "question": question,
                            "header": header,
                            "options": optionLabels,
                            "multiSelect": multiSelect
                        ])
                    }
                } else {
                    // Flat structure fallback
                    let question = input["question"] as? String ?? "Question from Claude"
                    var optionLabels: [String] = []
                    if let opts = input["options"] as? [String] { optionLabels = opts }
                    else if let opts = input["options"] as? [[String: Any]] {
                        optionLabels = opts.compactMap { $0["label"] as? String }
                    }
                    questionsPayload.append([
                        "question": question,
                        "header": "",
                        "options": optionLabels,
                        "multiSelect": false
                    ])
                }

                print("[ClaudeCode] AskUserQuestion: \(questionsPayload.count) questions")

                // Send all questions as JSON to iOS via onAskUser
                if let jsonData = try? JSONSerialization.data(withJSONObject: questionsPayload),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    onAskUser?(jsonStr, [])
                }
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

    // MARK: - Permission Protocol (control_request / control_response)

    private func handleControlRequest(_ json: [String: Any]) {
        guard let requestId = json["request_id"] as? String,
              let request = json["request"] as? [String: Any],
              let toolName = request["tool_name"] as? String,
              let input = request["input"] as? [String: Any] else { return }

        let reason = request["decision_reason"] as? String ?? ""
        print("[ClaudeCode] control_request: \(toolName) — \(reason)")

        // Auto-approve if tool was "Always Allowed" this session
        if alwaysAllowedTools.contains(toolName) {
            print("[ClaudeCode] Auto-approving \(toolName) (always allowed)")
            sendControlResponse(requestId: requestId, allow: true, input: input)
            return
        }

        // Store pending permission with metadata for later response
        var storedInput = input
        storedInput["_decision_reason"] = reason
        storedInput["_tool_name"] = toolName
        pendingPermissions[requestId] = storedInput

        // Forward to iOS via handler
        onPermissionRequest?(requestId, toolName, storedInput)
    }

    func respondToPermission(requestId: String, answer: String) {
        guard isRunning, let pipe = stdinPipe else { return }

        let stored = pendingPermissions[requestId]
        // Clean input: remove injected metadata fields
        var cleanInput = stored ?? [:]
        let toolName = cleanInput.removeValue(forKey: "_tool_name") as? String
        cleanInput.removeValue(forKey: "_decision_reason")

        print("[ClaudeCode] Permission response: \(answer) for request \(requestId)")

        if answer.contains("Deny") {
            sendControlResponse(requestId: requestId, allow: false, input: nil)
        } else {
            sendControlResponse(requestId: requestId, allow: true, input: cleanInput)
            // "Always Allow" — remember tool for this session
            if answer.contains("Always"), let name = toolName {
                alwaysAllowedTools.insert(name)
                print("[ClaudeCode] Added \(name) to always-allowed tools")
            }
        }
        pendingPermissions.removeValue(forKey: requestId)
    }

    private func sendControlResponse(requestId: String, allow: Bool, input: [String: Any]?) {
        guard let pipe = stdinPipe else { return }

        let response: [String: Any]
        if allow {
            response = [
                "type": "control_response",
                "request_id": requestId,
                "response": [
                    "behavior": "allow",
                    "updatedInput": input ?? [:]
                ] as [String: Any]
            ]
        } else {
            response = [
                "type": "control_response",
                "request_id": requestId,
                "response": [
                    "behavior": "deny",
                    "message": "User denied this action"
                ] as [String: Any]
            ]
        }

        if let data = try? JSONSerialization.data(withJSONObject: response),
           var jsonStr = String(data: data, encoding: .utf8) {
            jsonStr += "\n"
            if let bytes = jsonStr.data(using: .utf8) {
                pipe.fileHandleForWriting.write(bytes)
            }
        }
    }

    private func handleExit() {
        isRunning = false
        onComplete?("Session ended")
        print("[ClaudeCode] Session \(id) exited")
    }

    private func findClaudeCLI() -> String {
        // Use real home, not sandbox container
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
        let home = realHome.isEmpty ? NSHomeDirectory() : realHome
        let paths = [
            "/opt/homebrew/bin/claude",
            "\(home)/.local/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",  // also check sandbox path
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        print("[ClaudeCode] WARNING: claude CLI not found in any of: \(paths)")
        return "/opt/homebrew/bin/claude"
    }
}
