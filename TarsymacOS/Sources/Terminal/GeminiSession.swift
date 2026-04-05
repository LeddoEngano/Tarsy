import Foundation
import TarsyShared

/// Dedicated Gemini CLI session using the ACP (Agent Client Protocol) JSON-RPC mode.
/// Provides bidirectional communication: streaming output, ask-user questions,
/// tool approval forwarding, and token tracking.
actor GeminiSession: AIEngine {
    let id: String
    let engineType: AIEngineType = .gemini
    let workspacePath: String
    let permissionMode: AgentPermissionConfig.PermissionMode

    private var process: Process?
    private var stdinPipe: Pipe?
    private var isRunning = false
    private var sessionId: String?
    private var nextRequestId: Int = 100  // start at 100 to avoid collision with server request IDs (0, 1, ...)
    private var lineBuffer: String = ""

    private var onOutput: (@Sendable (String) -> Void)?
    private var onComplete: (@Sendable (String) -> Void)?
    private var onAskUser: (@Sendable (String, [String]) -> Void)?
    private var onStatusUpdate: (@Sendable (String, Int, Int, Int) -> Void)?

    // JSON-RPC state: track our outgoing requests
    private var pendingRequests: [Int: String] = [:]  // id -> method

    // Permission state: server requests awaiting iOS user response
    private var pendingPermissions: [Int: PendingPermission] = [:]

    // Message queuing during handshake / ask-user
    private var pendingFirstMessage: String?
    private var pendingAnswerMessage: String?

    // Token tracking
    private var lastModel: String = "gemini"
    private var lastContextWindow: Int = 1_000_000

    // Lifecycle state machine
    private enum SessionState {
        case launching
        case initializing
        case authenticating
        case creatingSession
        case settingMode
        case ready
        case prompting
    }
    private var state: SessionState = .launching

    private struct PendingPermission {
        let rpcId: Int
        let toolCallId: String
        let isAskUser: Bool
        let title: String
    }

    private func log(_ message: String) {
        NSLog("[GeminiSession:\(id.prefix(8))] \(message)")
    }

    init(id: String, workspacePath: String, permissionMode: AgentPermissionConfig.PermissionMode = .dangerous) {
        self.id = id
        self.workspacePath = workspacePath
        self.permissionMode = permissionMode
        NSLog("[GeminiSession:\(id.prefix(8))] init permissionMode=\(permissionMode.rawValue) workspace=\(workspacePath)")
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
        log("askUser handler set")
    }

    func setStatusHandler(_ handler: @escaping @Sendable (String, Int, Int, Int) -> Void) {
        self.onStatusUpdate = handler
    }

    // MARK: - Lifecycle

    func start() throws {
        let expandedPath = (workspacePath as NSString).expandingTildeInPath
        let geminiPath = findGeminiCLI()

        log("start: geminiPath=\(geminiPath) expandedPath=\(expandedPath)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: geminiPath)
        proc.arguments = ["--acp"]
        proc.currentDirectoryURL = URL(fileURLWithPath: expandedPath)
        proc.environment = buildEnvironment()

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.appendAndProcessLines(text) }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            NSLog("[GeminiSession:stderr] \(text)")
            // Gemini CLI outputs debug logs to stderr in ACP mode — ignore them
        }

        proc.terminationHandler = { [weak self] proc in
            NSLog("[GeminiSession] process terminated with status \(proc.terminationStatus)")
            Task { await self?.flushLineBuffer(); await self?.handleExit() }
        }

        try proc.run()
        log("start: process launched pid=\(proc.processIdentifier)")

        self.process = proc
        self.stdinPipe = stdin
        self.isRunning = true
        self.state = .initializing

        onOutput?("\(AIEngineType.gemini.readyMessage)\n")

        // Start ACP handshake
        sendRequest(method: "initialize", params: [
            "clientInfo": [
                "name": "tarsy_macos",
                "version": "1.0"
            ] as [String: Any],
            "protocolVersion": 1
        ])
    }

    func sendMessage(_ message: String) {
        guard isRunning else {
            log("sendMessage: dropped — not running")
            return
        }

        log("sendMessage: state=\(state) sessionId=\(sessionId ?? "nil") msg=\(message.prefix(100))")

        if state != .ready {
            // Session not ready yet — queue the message
            pendingFirstMessage = message
            return
        }

        guard let sid = sessionId else {
            log("sendMessage: no sessionId, queueing")
            pendingFirstMessage = message
            return
        }

        state = .prompting
        sendRequest(method: "session/prompt", params: [
            "sessionId": sid,
            "prompt": [["type": "text", "text": message]]
        ])
    }

    func respondToQuestion(_ answer: String) {
        guard isRunning else {
            log("respondToQuestion: dropped — not running")
            return
        }

        log("respondToQuestion: answer=\(answer.prefix(100)) pendingPermissions=\(pendingPermissions.count)")

        // Find the most recent pending permission
        if let (rpcId, pending) = pendingPermissions.first {
            respondToPermission(rpcId: rpcId, pending: pending, answer: answer)
            return
        }

        // No pending permission — treat as a new message
        sendMessage(answer)
    }

    /// Called when iOS sends a structured answer with permission metadata.
    func respondToGeminiPermission(rpcId: Int, answer: String) {
        log("respondToGeminiPermission: rpcId=\(rpcId) answer=\(answer.prefix(100))")

        if let pending = pendingPermissions[rpcId] {
            respondToPermission(rpcId: rpcId, pending: pending, answer: answer)
        } else {
            log("respondToGeminiPermission: no pending permission for rpcId=\(rpcId)")
            // Fallback: treat as a new message
            sendMessage(answer)
        }
    }

    func terminate() {
        log("terminate: isRunning=\(isRunning)")
        guard isRunning else { return }
        isRunning = false

        lineBuffer = ""
        pendingPermissions.removeAll()

        stdinPipe?.fileHandleForWriting.closeFile()

        let proc = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if proc?.isRunning == true {
                proc?.terminate()
            }
        }
    }

    // MARK: - JSON-RPC Wire Protocol

    private func sendRequest(method: String, params: [String: Any]) {
        guard let pipe = stdinPipe else {
            log("sendRequest: no stdin pipe for method=\(method)")
            return
        }
        let id = nextRequestId
        nextRequestId += 1
        pendingRequests[id] = method

        log(">>> request id=\(id) method=\(method)")

        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        writeJSON(msg, to: pipe)
    }

    private func sendResponse(id: Int, result: Any) {
        guard let pipe = stdinPipe else { return }
        log(">>> response id=\(id)")
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        writeJSON(msg, to: pipe)
    }

    private func writeJSON(_ obj: [String: Any], to pipe: Pipe) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var jsonStr = String(data: data, encoding: .utf8) else {
            log("writeJSON: serialization failed")
            return
        }
        jsonStr += "\n"
        if let bytes = jsonStr.data(using: .utf8) {
            pipe.fileHandleForWriting.write(bytes)
        }
    }

    // MARK: - Line Buffering

    private func appendAndProcessLines(_ text: String) {
        lineBuffer += text
        while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIndex)...])
            guard !line.isEmpty else { continue }
            handleMessage(line)
        }
    }

    private func flushLineBuffer() {
        let remaining = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        lineBuffer = ""
        guard !remaining.isEmpty else { return }
        handleMessage(remaining)
    }

    // MARK: - Message Routing

    private func handleMessage(_ jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Non-JSON line — Gemini ACP can output debug text to stdout (known bug)
            log("<<< non-JSON line: \(jsonLine.prefix(200))")
            return
        }

        if let id = json["id"], json["result"] != nil {
            // Response to one of our requests
            guard let reqId = parseRequestId(id) else {
                log("<<< response with unparseable id: \(id)")
                return
            }
            let method = pendingRequests[reqId] ?? "?"
            log("<<< response id=\(reqId) for method=\(method)")
            handleResponse(id: reqId, result: json["result"]!)
        } else if let id = json["id"], let method = json["method"] as? String {
            // Server request — needs our response
            guard let reqId = parseRequestId(id) else {
                log("<<< server request with unparseable id: \(id)")
                return
            }
            let params = json["params"] as? [String: Any] ?? [:]
            log("<<< server request id=\(reqId) method=\(method)")
            handleServerRequest(id: reqId, method: method, params: params)
        } else if let id = json["id"], let error = json["error"] as? [String: Any] {
            // Error response
            let message = error["message"] as? String ?? "Unknown error"
            log("<<< error id=\(id) message=\(message)")
            onOutput?("❌ \(message)\n")
            if let reqId = parseRequestId(id) { pendingRequests.removeValue(forKey: reqId) }
        } else if let method = json["method"] as? String {
            // Server notification (no id)
            let params = json["params"] as? [String: Any] ?? [:]
            handleNotification(method: method, params: params)
        } else {
            log("<<< unrecognized message: \(jsonLine.prefix(300))")
        }
    }

    private func parseRequestId(_ id: Any) -> Int? {
        if let intId = id as? Int { return intId }
        if let strId = id as? String { return Int(strId) }
        return nil
    }

    // MARK: - Handle Responses (to our requests)

    private func handleResponse(id: Int, result: Any) {
        guard let method = pendingRequests.removeValue(forKey: id) else {
            log("handleResponse: no pending request for id=\(id)")
            return
        }

        switch method {
        case "initialize":
            log("handleResponse: initialized — sending authenticate")
            state = .authenticating
            sendRequest(method: "authenticate", params: [
                "methodId": "oauth-personal"
            ])

        case "authenticate":
            log("handleResponse: authenticated — creating session")
            state = .creatingSession
            let expandedPath = (workspacePath as NSString).expandingTildeInPath
            sendRequest(method: "session/new", params: [
                "cwd": expandedPath,
                "mcpServers": [] as [Any]
            ])

        case "session/new":
            if let dict = result as? [String: Any],
               let sid = dict["sessionId"] as? String {
                sessionId = sid
                log("handleResponse: session created id=\(sid)")

                // Extract model info
                if let models = dict["models"] as? [String: Any],
                   let currentModel = models["currentModelId"] as? String {
                    lastModel = currentModel
                }

                // Set mode based on permission config
                state = .settingMode
                let modeId = permissionMode == .dangerous ? "yolo" : "default"
                sendRequest(method: "session/set_mode", params: [
                    "sessionId": sid,
                    "modeId": modeId
                ])
            } else {
                log("handleResponse: session/new — could not parse sessionId")
                onOutput?("❌ Failed to create Gemini session\n")
            }

        case "session/set_mode":
            log("handleResponse: mode set — session ready")
            state = .ready
            if let msg = pendingFirstMessage {
                pendingFirstMessage = nil
                sendMessage(msg)
            }

        case "session/prompt":
            log("handleResponse: prompt completed")
            state = .ready

            // Extract token stats from result
            if let dict = result as? [String: Any],
               let stats = dict["stats"] as? [String: Any] {
                let inputTokens = stats["inputTokens"] as? Int ?? stats["input_tokens"] as? Int ?? 0
                let outputTokens = stats["outputTokens"] as? Int ?? stats["output_tokens"] as? Int ?? 0
                if let model = stats["model"] as? String { lastModel = model }
                onStatusUpdate?(lastModel, inputTokens, outputTokens, lastContextWindow)
            }

            onComplete?("")

            // If user answered an ask-user question, send their answer as follow-up prompt
            if let msg = pendingAnswerMessage {
                pendingAnswerMessage = nil
                sendMessage(msg)
            }

        default:
            log("handleResponse: unhandled method=\(method)")
        }
    }

    // MARK: - Handle Server Requests (permissions, ask-user)

    private func handleServerRequest(id: Int, method: String, params: [String: Any]) {
        log("handleServerRequest: id=\(id) method=\(method)")

        switch method {
        case "session/request_permission":
            handlePermissionRequest(id: id, params: params)
        default:
            // Unknown server request — auto-accept in dangerous mode
            log("handleServerRequest: unhandled method=\(method)")
            if permissionMode == .dangerous {
                sendResponse(id: id, result: [
                    "outcome": ["outcome": "selected", "optionId": "proceed_once"]
                ] as [String: Any])
            }
        }
    }

    private func handlePermissionRequest(id: Int, params: [String: Any]) {
        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        let toolCallId = toolCall["toolCallId"] as? String ?? ""
        let title = toolCall["title"] as? String ?? ""
        let content = toolCall["content"] as? [[String: Any]] ?? []
        let isAskUser = toolCallId.hasPrefix("ask_user-")

        log("handlePermissionRequest: id=\(id) toolCallId=\(toolCallId) isAskUser=\(isAskUser) title=\(title.prefix(100))")

        // Store pending permission
        pendingPermissions[id] = PendingPermission(
            rpcId: id,
            toolCallId: toolCallId,
            isAskUser: isAskUser,
            title: title
        )

        if isAskUser {
            // Extract question from title: "Asking user: Which language do you prefer?"
            let question = title.hasPrefix("Asking user: ")
                ? String(title.dropFirst("Asking user: ".count))
                : title

            let questionsPayload: [[String: Any]] = [[
                "question": question,
                "header": "",
                "options": [] as [String],  // ACP doesn't expose ask-user options
                "multiSelect": false,
                "_permissionRpcId": id,
                "_isGeminiPermission": true
            ]]
            if let jsonData = try? JSONSerialization.data(withJSONObject: questionsPayload),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                log("handlePermissionRequest: forwarding ask-user to iOS")
                onAskUser?(jsonStr, [])
            }
        } else if permissionMode == .dangerous {
            // Auto-approve tool executions in dangerous mode
            log("handlePermissionRequest: auto-approving (dangerous mode)")
            pendingPermissions.removeValue(forKey: id)
            sendResponse(id: id, result: [
                "outcome": ["outcome": "selected", "optionId": "proceed_once"]
            ] as [String: Any])
        } else {
            // Safe mode: forward tool approval to iOS
            var descriptionText = title
            // Include content details if available
            for item in content {
                if let contentObj = item["content"] as? [String: Any],
                   let text = contentObj["text"] as? String {
                    descriptionText += "\n\n\(text)"
                }
            }

            let questionsPayload: [[String: Any]] = [[
                "question": descriptionText,
                "header": "Tool Approval",
                "options": ["Allow", "Always Allow", "Deny"],
                "multiSelect": false,
                "_permissionRpcId": id,
                "_isGeminiPermission": true
            ]]
            if let jsonData = try? JSONSerialization.data(withJSONObject: questionsPayload),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                log("handlePermissionRequest: forwarding tool approval to iOS")
                onAskUser?(jsonStr, [])
            }
        }
    }

    // MARK: - Permission Response

    private func respondToPermission(rpcId: Int, pending: PendingPermission, answer: String) {
        pendingPermissions.removeValue(forKey: rpcId)

        if pending.isAskUser {
            log("respondToPermission: ask-user rpcId=\(rpcId) — approving + queueing answer")
            // Approve the ask-user permission
            sendResponse(id: rpcId, result: [
                "outcome": ["outcome": "selected", "optionId": "proceed_once"]
            ] as [String: Any])
            // Queue user's answer to send after current prompt completes
            // (ask-user tool will complete with "User submitted without answering",
            //  then the prompt finishes, and we send the answer as a follow-up)
            pendingAnswerMessage = answer
        } else {
            // Tool approval: map answer to optionId
            let lower = answer.lowercased()
            if lower.contains("deny") || lower.contains("cancel") || lower.contains("reject") {
                log("respondToPermission: tool denied rpcId=\(rpcId)")
                sendResponse(id: rpcId, result: [
                    "outcome": ["outcome": "cancelled"]
                ] as [String: Any])
            } else if lower.contains("always") {
                log("respondToPermission: tool always-allow rpcId=\(rpcId)")
                sendResponse(id: rpcId, result: [
                    "outcome": ["outcome": "selected", "optionId": "proceed_always"]
                ] as [String: Any])
            } else {
                log("respondToPermission: tool allow-once rpcId=\(rpcId)")
                sendResponse(id: rpcId, result: [
                    "outcome": ["outcome": "selected", "optionId": "proceed_once"]
                ] as [String: Any])
            }
        }
    }

    // MARK: - Handle Notifications (streaming events)

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "session/update":
            guard let update = params["update"] as? [String: Any],
                  let updateType = update["sessionUpdate"] as? String else {
                return
            }
            handleSessionUpdate(type: updateType, update: update)

        default:
            log("notification: unhandled method=\(method)")
        }
    }

    private func handleSessionUpdate(type: String, update: [String: Any]) {
        switch type {
        case "agent_message_chunk":
            if let content = update["content"] as? [String: Any],
               let text = content["text"] as? String, !text.isEmpty {
                onOutput?(text)
            }

        case "agent_thought_chunk":
            if let content = update["content"] as? [String: Any],
               let text = content["text"] as? String, !text.isEmpty {
                onOutput?("💭 \(text)")
            }

        case "tool_call_update":
            let toolCallId = update["toolCallId"] as? String ?? ""
            let status = update["status"] as? String ?? ""
            let content = update["content"] as? [[String: Any]] ?? []

            // Don't output ask-user tool noise
            if toolCallId.hasPrefix("ask_user-") { return }

            if status == "started" {
                onOutput?("🔧 \(toolCallId)\n")
            } else if status == "failed" {
                for item in content {
                    if let contentObj = item["content"] as? [String: Any],
                       let text = contentObj["text"] as? String {
                        onOutput?("⚠️ \(text)\n")
                    }
                }
            }

        case "available_commands_update":
            break // ignore

        default:
            break
        }
    }

    // MARK: - Exit

    private func handleExit() {
        log("handleExit: session ended")
        isRunning = false
        sessionId = nil
        state = .launching
        pendingPermissions.removeAll()
        onComplete?("Session ended")
    }

    // MARK: - Environment & CLI Path

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
        let home = realHome.isEmpty ? (env["HOME"] ?? NSHomeDirectory()) : realHome
        env["HOME"] = home

        var extraPaths: [String] = []
        let candidates = [
            "/opt/homebrew/bin", "\(home)/.local/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin",
            "\(home)/.volta/bin", "\(home)/.asdf/shims", "\(home)/.local/share/mise/shims",
        ]
        for p in candidates where FileManager.default.fileExists(atPath: p) {
            extraPaths.append(p)
        }
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                let binPath = "\(nvmDir)/\(v)/bin"
                if FileManager.default.fileExists(atPath: binPath) { extraPaths.append(binPath) }
            }
        }
        let fnmDir = "\(home)/.local/share/fnm/node-versions"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: fnmDir) {
            for v in versions {
                let binPath = "\(fnmDir)/\(v)/installation/bin"
                if FileManager.default.fileExists(atPath: binPath) { extraPaths.append(binPath) }
            }
        }
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"

        return env
    }

    private func findGeminiCLI() -> String {
        if let path = AgentDetector.agentPath(for: .gemini) {
            log("findGeminiCLI: using AgentDetector path=\(path)")
            return path
        }
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
        let home = realHome.isEmpty ? NSHomeDirectory() : realHome
        let paths = [
            "/opt/homebrew/bin/gemini",
            "\(home)/.local/bin/gemini",
            "/usr/local/bin/gemini",
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                log("findGeminiCLI: found at \(path)")
                return path
            }
        }
        log("findGeminiCLI: not found, defaulting to /opt/homebrew/bin/gemini")
        return "/opt/homebrew/bin/gemini"
    }
}
