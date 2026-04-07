import Foundation
import TarsyShared

/// Dedicated Codex CLI session using the app-server JSON-RPC protocol.
/// Provides bidirectional communication: streaming output, approval requests,
/// user input questions, and token tracking — matching ClaudeCodeSession's capabilities.
actor CodexSession: AIEngine {
    let id: String
    let engineType: AIEngineType = .codex
    let workspacePath: String
    let permissionMode: AgentPermissionConfig.PermissionMode

    private var process: Process?
    private var stdinPipe: Pipe?
    private var isRunning = false
    private var threadId: String?
    private var nextRequestId: Int = 1
    private var lineBuffer: String = ""

    private var onOutput: (@Sendable (String) -> Void)?
    private var onComplete: (@Sendable (String) -> Void)?
    private var onAskUser: (@Sendable (String, [String]) -> Void)?
    private var onStatusUpdate: (@Sendable (String, Int, Int, Int) -> Void)?

    // Track pending client requests (our requests to server)
    private var pendingRequests: [Int: String] = [:]  // id -> method

    // Turn state tracking
    private var activeTurnId: String?
    private var pendingFirstMessage: String?
    private var pendingMessageAfterInterrupt: String?

    // Approval tracking: per-requestId to handle concurrent approvals
    private var pendingApprovalTypes: [Int: String] = [:]  // approvalId -> approvalType

    // Agent message buffering — all agentMessage content is treated as activity narration
    // during streaming. Only the final message (no tool calls after it) gets promoted to chat.
    private var agentMessageBuffer: String = ""
    private var lastAgentMessageContent: String = ""
    private var hadToolAfterLastMessage: Bool = false

    // Token tracking
    private var lastModel: String = "codex"
    private var lastInputTokens: Int = 0
    private var lastOutputTokens: Int = 0
    private var lastContextWindow: Int = 0

    private func log(_ message: String) {
        NSLog("[CodexSession:\(id.prefix(8))] \(message)")
    }

    init(id: String, workspacePath: String, permissionMode: AgentPermissionConfig.PermissionMode = .dangerous) {
        self.id = id
        self.workspacePath = workspacePath
        self.permissionMode = permissionMode
        NSLog("[CodexSession:\(id.prefix(8))] init permissionMode=\(permissionMode.rawValue) workspace=\(workspacePath)")
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
        let codexPath = findCodexCLI()

        log("start: codexPath=\(codexPath) expandedPath=\(expandedPath)")

        let args = ["app-server", "--listen", "stdio://"]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: codexPath)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: expandedPath)

        var env = ProcessInfo.processInfo.environment
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
        if !realHome.isEmpty { env["HOME"] = realHome }
        let home = realHome.isEmpty ? (env["HOME"] ?? NSHomeDirectory()) : realHome

        // Enrich PATH
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
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        proc.environment = env

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
            NSLog("[CodexSession:stderr] \(text)")
        }

        proc.terminationHandler = { [weak self] proc in
            NSLog("[CodexSession] process terminated with status \(proc.terminationStatus)")
            Task { await self?.flushLineBuffer(); await self?.handleExit() }
        }

        try proc.run()
        log("start: process launched pid=\(proc.processIdentifier)")

        self.process = proc
        self.stdinPipe = stdin
        self.isRunning = true

        onOutput?("\(AIEngineType.codex.readyMessage)\n")

        // Send initialize request
        sendRequest(method: "initialize", params: [
            "clientInfo": [
                "name": "tarsy_macos",
                "version": "1.0"
            ] as [String: Any]
        ])
    }

    func sendMessage(_ message: String) {
        guard isRunning else {
            log("sendMessage: dropped — not running")
            return
        }

        log("sendMessage: threadId=\(threadId ?? "nil") activeTurnId=\(activeTurnId ?? "nil") msg=\(message.prefix(100))")

        if threadId == nil {
            // First message — start thread, then send turn after response
            let expandedPath = (workspacePath as NSString).expandingTildeInPath
            var threadParams: [String: Any] = [
                "cwd": expandedPath
            ]

            // sandbox + approvalPolicy work together:
            // - sandbox defines what the agent CAN do without approval
            // - approvalPolicy defines what happens when an action exceeds the sandbox
            // Sandbox values: read-only, workspace-write, danger-full-access
            // Approval values: never, on-request, untrusted
            if permissionMode == .dangerous {
                threadParams["approvalPolicy"] = "never"
                threadParams["sandbox"] = "danger-full-access"
            } else {
                threadParams["approvalPolicy"] = "on-request"
                threadParams["sandbox"] = "read-only"
            }

            log("sendMessage: starting thread approvalPolicy=\(threadParams["approvalPolicy"] ?? "?") sandbox=\(threadParams["sandbox"] ?? "?") permissionMode=\(permissionMode.rawValue)")

            pendingFirstMessage = message
            sendRequest(method: "thread/start", params: threadParams)
            return
        }

        guard let tid = threadId else { return }

        if let activeTurn = activeTurnId {
            // Turn is active — interrupt it first, then send new message after
            log("sendMessage: interrupting active turn \(activeTurn)")
            pendingMessageAfterInterrupt = message
            sendRequest(method: "turn/interrupt", params: [
                "threadId": tid,
                "turnId": activeTurn
            ])
        } else {
            // No active turn — start a new one
            startTurn(threadId: tid, message: message)
        }
    }

    func respondToQuestion(_ answer: String) {
        guard isRunning, let tid = threadId else {
            log("respondToQuestion: dropped — running=\(isRunning) threadId=\(threadId ?? "nil")")
            return
        }

        log("respondToQuestion: answer=\(answer.prefix(100)) activeTurnId=\(activeTurnId ?? "nil")")

        if activeTurnId != nil {
            // Turn is active — use turn/steer to inject follow-up
            sendRequest(method: "turn/steer", params: [
                "threadId": tid,
                "input": [["type": "text", "text": answer]],
                "expectedTurnId": activeTurnId!
            ])
        } else {
            // No active turn — start a new one
            startTurn(threadId: tid, message: answer)
        }
    }

    /// Called when iOS sends an answer to an approval question.
    func handleApprovalAnswer(_ answer: String) {
        log("handleApprovalAnswer: \(answer.prefix(200))")

        // Parse structured response from DaemonManager
        if let data = answer.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let approvalId = parsed["_approvalId"] as? Int {
            let approvalType = parsed["_approvalType"] as? String
                ?? pendingApprovalTypes.removeValue(forKey: approvalId)
                ?? "command"
            let selectedOption = parsed["answer"] as? String ?? "Deny"
            log("handleApprovalAnswer: approvalId=\(approvalId) type=\(approvalType) option=\(selectedOption)")
            respondToApprovalWithOption(id: approvalId, type: approvalType, option: selectedOption, rawAnswer: answer)
            return
        }

        log("handleApprovalAnswer: failed to parse structured response, falling back")
    }

    func interrupt() {
        process?.interrupt()
    }

    func terminate() {
        log("terminate: isRunning=\(isRunning) activeTurnId=\(activeTurnId ?? "nil")")
        guard isRunning else { return }
        isRunning = false

        // Graceful: interrupt active turn first, then close stdin
        if let tid = threadId, let turnId = activeTurnId {
            sendRequest(method: "turn/interrupt", params: [
                "threadId": tid,
                "turnId": turnId
            ])
        }

        // Give the process a moment to handle the interrupt, then close
        lineBuffer = ""
        pendingApprovalTypes.removeAll()

        // Close stdin to signal EOF — the server will shut down gracefully
        stdinPipe?.fileHandleForWriting.closeFile()

        // Set a watchdog: if process doesn't exit in 3s, force kill
        let proc = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if proc?.isRunning == true {
                proc?.terminate()
            }
        }
    }

    // MARK: - Turn Management

    private func startTurn(threadId: String, message: String) {
        log("startTurn: threadId=\(threadId) msg=\(message.prefix(80))")
        sendRequest(method: "turn/start", params: [
            "threadId": threadId,
            "input": [["type": "text", "text": message]]
        ])
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

        let msg: [String: Any] = ["id": id, "method": method, "params": params]
        writeJSON(msg, to: pipe)
    }

    private func sendNotification(method: String, params: [String: Any]? = nil) {
        guard let pipe = stdinPipe else { return }
        log(">>> notification method=\(method)")
        var msg: [String: Any] = ["method": method]
        if let params { msg["params"] = params }
        writeJSON(msg, to: pipe)
    }

    private func sendResponse(id: Int, result: [String: Any]) {
        guard let pipe = stdinPipe else { return }
        log(">>> response id=\(id) result=\(result)")
        let msg: [String: Any] = ["id": id, "result": result]
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
            // Server request (approval) — needs our response
            guard let reqId = parseRequestId(id) else {
                log("<<< server request with unparseable id: \(id)")
                return
            }
            let params = json["params"] as? [String: Any] ?? [:]
            log("<<< server request id=\(reqId) method=\(method) paramKeys=\(params.keys.sorted())")
            handleServerRequest(id: reqId, method: method, params: params)
        } else if let id = json["id"], let error = json["error"] as? [String: Any] {
            // Error response
            let code = error["code"] as? Int
            let message = error["message"] as? String ?? "Unknown error"
            log("<<< error id=\(id) code=\(code ?? 0) message=\(message)")
            onOutput?("❌ \(message)\n")
            if let reqId = parseRequestId(id) { pendingRequests.removeValue(forKey: reqId) }
        } else if let method = json["method"] as? String {
            // Server notification (no id = one-way)
            let params = json["params"] as? [String: Any] ?? [:]
            log("<<< notification method=\(method)")
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
            log("handleResponse: initialized OK")
            sendNotification(method: "initialized")

        case "thread/start":
            if let dict = result as? [String: Any],
               let thread = dict["thread"] as? [String: Any],
               let tid = thread["id"] as? String {
                threadId = tid
                if let model = dict["model"] as? String {
                    lastModel = model
                }
                log("handleResponse: thread started id=\(tid) model=\(lastModel)")
                if let msg = pendingFirstMessage {
                    pendingFirstMessage = nil
                    startTurn(threadId: tid, message: msg)
                }
            } else {
                log("handleResponse: thread/start — could not parse thread id from result")
            }

        case "turn/start":
            // Turn started — extract turn ID for state tracking
            if let dict = result as? [String: Any],
               let turn = dict["turn"] as? [String: Any],
               let turnId = turn["id"] as? String {
                activeTurnId = turnId
                log("handleResponse: turn started id=\(turnId)")
            } else {
                log("handleResponse: turn/start — could not parse turn id from result")
            }

        case "turn/interrupt":
            // Turn interrupted — now send the pending message if any
            log("handleResponse: turn interrupted, pendingMessage=\(pendingMessageAfterInterrupt != nil)")
            activeTurnId = nil
            if let msg = pendingMessageAfterInterrupt, let tid = threadId {
                pendingMessageAfterInterrupt = nil
                startTurn(threadId: tid, message: msg)
            }

        case "turn/steer":
            log("handleResponse: turn/steer OK")

        default:
            log("handleResponse: unhandled method=\(method)")
        }
    }

    // MARK: - Handle Server Requests (approvals, questions)

    private func handleServerRequest(id: Int, method: String, params: [String: Any]) {
        log("handleServerRequest: id=\(id) method=\(method) permissionMode=\(permissionMode.rawValue)")

        // Log full params for debugging (truncated for large payloads)
        if let paramsData = try? JSONSerialization.data(withJSONObject: params),
           let paramsStr = String(data: paramsData, encoding: .utf8) {
            log("handleServerRequest: params=\(paramsStr.prefix(500))")
        }

        switch method {
        case "item/commandExecution/requestApproval":
            handleCommandApproval(id: id, params: params)

        case "item/fileChange/requestApproval":
            handleFileChangeApproval(id: id, params: params)

        case "item/tool/requestUserInput":
            handleUserInputRequest(id: id, params: params)

        case "mcpServer/elicitation/request":
            handleElicitationRequest(id: id, params: params)

        case "item/permissions/requestApproval":
            if permissionMode == .dangerous {
                log("handleServerRequest: auto-accepting permissions (dangerous mode)")
                sendResponse(id: id, result: ["decision": "accept"])
            } else {
                let reason = params["reason"] as? String ?? "Codex is requesting additional permissions"
                pendingApprovalTypes[id] = "permissions"
                let questionsPayload: [[String: Any]] = [[
                    "question": reason,
                    "header": "Permission Request",
                    "options": ["Allow", "Deny"],
                    "multiSelect": false,
                    "_approvalId": id,
                    "_approvalType": "permissions"
                ]]
                log("handleServerRequest: forwarding permissions question to iOS")
                sendApprovalQuestion(questionsPayload)
            }

        default:
            log("handleServerRequest: UNHANDLED method=\(method) — this is a catch-all")
            if permissionMode == .dangerous {
                log("handleServerRequest: auto-accepting unknown request (dangerous mode)")
                sendResponse(id: id, result: ["decision": "accept"])
            } else {
                // Unknown server request in safe mode — forward as question instead of auto-accepting
                let description = (params["command"] as? String)
                    ?? (params["reason"] as? String)
                    ?? (params["message"] as? String)
                    ?? "Codex is requesting approval"
                pendingApprovalTypes[id] = "unknown"
                let questionsPayload: [[String: Any]] = [[
                    "question": "\(description)\n\n(method: \(method))",
                    "header": "Approval Request",
                    "options": ["Allow", "Deny"],
                    "multiSelect": false,
                    "_approvalId": id,
                    "_approvalType": "unknown"
                ]]
                log("handleServerRequest: forwarding unknown request as question to iOS")
                sendApprovalQuestion(questionsPayload)
            }
        }
    }

    private func handleCommandApproval(id: Int, params: [String: Any]) {
        let command = params["command"] as? String ?? "Unknown command"
        let reason = params["reason"] as? String
        let cwd = params["cwd"] as? String
        log("handleCommandApproval: id=\(id) command=\(command.prefix(100)) permissionMode=\(permissionMode.rawValue)")

        if permissionMode == .dangerous {
            log("handleCommandApproval: auto-accepting (dangerous mode)")
            sendResponse(id: id, result: ["decision": "accept"])
            return
        }

        var questionText = "Codex wants to run:\n\n`\(command)`"
        if let cwd { questionText += "\nin \(cwd)" }
        if let reason { questionText += "\n\nReason: \(reason)" }

        pendingApprovalTypes[id] = "command"
        let questionsPayload: [[String: Any]] = [[
            "question": questionText,
            "header": "Command Approval",
            "options": ["Allow", "Allow for Session", "Deny", "Cancel"],
            "multiSelect": false,
            "_approvalId": id,
            "_approvalType": "command"
        ]]
        log("handleCommandApproval: forwarding question to iOS")
        sendApprovalQuestion(questionsPayload)
    }

    private func handleFileChangeApproval(id: Int, params: [String: Any]) {
        let reason = params["reason"] as? String ?? "Codex wants to modify files"
        log("handleFileChangeApproval: id=\(id) reason=\(reason.prefix(100)) permissionMode=\(permissionMode.rawValue)")

        if permissionMode == .dangerous {
            log("handleFileChangeApproval: auto-accepting (dangerous mode)")
            sendResponse(id: id, result: ["decision": "accept"])
            return
        }

        pendingApprovalTypes[id] = "fileChange"
        let questionsPayload: [[String: Any]] = [[
            "question": reason,
            "header": "File Change Approval",
            "options": ["Allow", "Allow for Session", "Deny", "Cancel"],
            "multiSelect": false,
            "_approvalId": id,
            "_approvalType": "fileChange"
        ]]
        log("handleFileChangeApproval: forwarding question to iOS")
        sendApprovalQuestion(questionsPayload)
    }

    private func handleUserInputRequest(id: Int, params: [String: Any]) {
        log("handleUserInputRequest: id=\(id) paramKeys=\(params.keys.sorted())")

        guard let questions = params["questions"] as? [[String: Any]] else {
            log("handleUserInputRequest: no questions array in params, sending empty answers")
            sendResponse(id: id, result: ["answers": [:] as [String: Any]])
            return
        }

        log("handleUserInputRequest: \(questions.count) question(s)")

        pendingApprovalTypes[id] = "userInput"
        var questionsPayload: [[String: Any]] = []
        for q in questions {
            let qId = q["id"] as? String ?? UUID().uuidString
            let question = q["question"] as? String ?? ""
            let header = q["header"] as? String ?? ""
            let isSecret = q["isSecret"] as? Bool ?? false

            var optionLabels: [String] = []
            if let opts = q["options"] as? [[String: Any]] {
                optionLabels = opts.compactMap { $0["label"] as? String }
            }

            log("handleUserInputRequest: q=\(question.prefix(80)) header=\(header) options=\(optionLabels)")

            questionsPayload.append([
                "question": question,
                "header": header,
                "options": optionLabels,
                "multiSelect": false,
                "isSecret": isSecret,
                "_approvalId": id,
                "_approvalType": "userInput",
                "_questionId": qId
            ])
        }
        sendApprovalQuestion(questionsPayload)
    }

    private func handleElicitationRequest(id: Int, params: [String: Any]) {
        let message = params["message"] as? String ?? "MCP server is requesting input"
        let serverName = params["serverName"] as? String ?? "MCP"
        log("handleElicitationRequest: id=\(id) server=\(serverName) message=\(message.prefix(100))")

        pendingApprovalTypes[id] = "elicitation"
        let questionsPayload: [[String: Any]] = [[
            "question": message,
            "header": "Input from \(serverName)",
            "options": ["Accept", "Decline", "Cancel"],
            "multiSelect": false,
            "_approvalId": id,
            "_approvalType": "elicitation"
        ]]
        sendApprovalQuestion(questionsPayload)
    }

    private func sendApprovalQuestion(_ questionsPayload: [[String: Any]]) {
        if let jsonData = try? JSONSerialization.data(withJSONObject: questionsPayload),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            log("sendApprovalQuestion: sending to iOS — hasHandler=\(onAskUser != nil) payload=\(jsonStr.prefix(300))")
            onAskUser?(jsonStr, [])
        } else {
            log("sendApprovalQuestion: JSON serialization failed")
        }
    }

    // MARK: - Approval Response

    private func respondToApprovalWithOption(id: Int, type: String, option: String, rawAnswer: String) {
        log("respondToApprovalWithOption: id=\(id) type=\(type) option=\(option)")
        pendingApprovalTypes.removeValue(forKey: id)

        // The option may be the raw answer text ("question: Allow") or just "Allow".
        // Use contains-based matching to handle both formats.
        let lower = option.lowercased()
        let decision: String
        if lower.contains("allow for session") || lower.contains("acceptforsession") {
            decision = "acceptForSession"
        } else if lower.contains("allow") || lower.contains("accept") {
            decision = "accept"
        } else if lower.contains("cancel") {
            decision = "cancel"
        } else if lower.contains("deny") || lower.contains("decline") {
            decision = "decline"
        } else {
            decision = "decline"
        }

        log("respondToApprovalWithOption: mapped decision=\(decision)")

        switch type {
        case "command", "fileChange", "permissions", "unknown":
            sendResponse(id: id, result: ["decision": decision])
        case "userInput":
            if let data = rawAnswer.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let questionId = parsed["_questionId"] as? String,
               let userAnswer = parsed["answer"] as? String {
                log("respondToApprovalWithOption: userInput questionId=\(questionId) answer=\(userAnswer.prefix(80))")
                sendResponse(id: id, result: [
                    "answers": [questionId: ["answers": [userAnswer]]]
                ])
            } else {
                log("respondToApprovalWithOption: userInput — failed to parse, sending empty answers")
                sendResponse(id: id, result: ["answers": [:] as [String: Any]])
            }
        case "elicitation":
            let action = decision == "accept" ? "accept" : decision == "cancel" ? "cancel" : "decline"
            log("respondToApprovalWithOption: elicitation action=\(action)")
            sendResponse(id: id, result: ["action": action])
        default:
            log("respondToApprovalWithOption: unknown type=\(type), sending decision")
            sendResponse(id: id, result: ["decision": decision])
        }
    }

    // MARK: - Handle Server Notifications (events)

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "turn/started":
            // Track active turn from notification (backup for when turn/start response is delayed)
            if let turn = params["turn"] as? [String: Any],
               let turnId = turn["id"] as? String {
                activeTurnId = turnId
                log("notification turn/started: turnId=\(turnId)")
            }

        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String, !delta.isEmpty {
                // ALL agentMessage content → activity narration during streaming.
                // The final message gets promoted to chat on turn/completed.
                agentMessageBuffer += delta
                lastAgentMessageContent += delta
                emitBufferedActivitySentences()
            }

        case "item/started":
            guard let item = params["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return }
            log("notification item/started: type=\(itemType)")
            if itemType == "agentMessage" {
                agentMessageBuffer = ""
                lastAgentMessageContent = ""
                hadToolAfterLastMessage = false
            }
            if itemType == "commandExecution" || itemType == "fileChange" {
                hadToolAfterLastMessage = true
            }
            // Log action details but don't send raw execution data to chat
            if itemType == "commandExecution", let cmd = item["command"] as? String {
                log("notification item/started: command=\(cmd)")
            } else if itemType == "fileChange", let changes = item["changes"] as? [[String: Any]] {
                for change in changes {
                    let path = change["path"] as? String ?? "?"
                    let kind = change["kind"] as? String ?? "update"
                    log("notification item/started: \(kind) \(path)")
                }
            }

        case "item/completed":
            guard let item = params["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return }
            log("notification item/completed: type=\(itemType)")
            if itemType == "agentMessage" {
                // Flush remaining buffer as activity
                let remaining = agentMessageBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !remaining.isEmpty {
                    onOutput?("📋 \(remaining)")
                }
                agentMessageBuffer = ""
            }
            if itemType == "commandExecution" {
                let exitCode = item["exitCode"] as? Int
                let status = item["status"] as? String ?? "completed"
                log("notification item/completed: command status=\(status) exitCode=\(exitCode ?? 0)")
            }

        case "item/commandExecution/outputDelta":
            // Command output — not sent to chat, too verbose for logs
            break

        case "item/fileChange/outputDelta":
            // File change diffs — not sent to chat, too verbose for logs
            break

        case "item/reasoning/summaryTextDelta":
            if let delta = params["delta"] as? String, !delta.isEmpty {
                onOutput?("💭 \(delta)")
            }

        case "turn/completed":
            activeTurnId = nil
            if let turn = params["turn"] as? [String: Any] {
                let status = turn["status"] as? String ?? "completed"
                log("notification turn/completed: status=\(status) hadToolAfterLastMessage=\(hadToolAfterLastMessage)")
                if status == "failed", let error = turn["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "Turn failed"
                    onOutput?("❌ \(message)\n")
                }
                // Promote the last agentMessage to chat if:
                // 1. Turn completed successfully (not interrupted/failed)
                // 2. No tool call happened after the last message (it's the "final answer")
                if status == "completed" && !hadToolAfterLastMessage {
                    let finalMessage = lastAgentMessageContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !finalMessage.isEmpty {
                        log("turn/completed: promoting final message to chat (\(finalMessage.count) chars)")
                        // Clear activity narration first so iOS doesn't show both
                        onOutput?("📋CLEAR")
                        onOutput?(finalMessage)
                    }
                }
            }
            lastAgentMessageContent = ""
            hadToolAfterLastMessage = false
            onComplete?("")

        case "thread/tokenUsage/updated":
            if let usage = params["tokenUsage"] as? [String: Any] {
                if let total = usage["total"] as? [String: Any] {
                    // Include inputTokens + cachedInputTokens: cached tokens still occupy
                    // the context window (cache is a billing optimization, not context one).
                    // The modelContextWindow from Codex is the true limit to compare against.
                    lastInputTokens = (total["inputTokens"] as? Int ?? 0)
                        + (total["cachedInputTokens"] as? Int ?? 0)
                    lastOutputTokens = total["outputTokens"] as? Int ?? 0
                }
                if let contextWindow = usage["modelContextWindow"] as? Int {
                    lastContextWindow = contextWindow
                }
                log("notification tokenUsage: input=\(lastInputTokens) output=\(lastOutputTokens) context=\(lastContextWindow)")
                onStatusUpdate?(lastModel, lastInputTokens, lastOutputTokens, lastContextWindow)
            }

        case "thread/status/changed":
            let status = params["status"] as? String ?? "?"
            log("notification thread/status/changed: \(status)")
            // Track idle state — clear activeTurnId if server says idle
            if status == "idle" {
                activeTurnId = nil
            }

        case "thread/name/updated":
            break

        case "error":
            if let error = params["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown error"
                let willRetry = params["willRetry"] as? Bool ?? false
                log("notification error: \(message) willRetry=\(willRetry)")
                if willRetry {
                    onOutput?("⚠️ \(message) (retrying...)\n")
                } else {
                    onOutput?("❌ \(message)\n")
                }
            }

        default:
            log("notification UNHANDLED: method=\(method)")
        }
    }

    // MARK: - Activity Buffering

    /// Emits complete sentences from the activity buffer with 📋 prefix.
    /// Splits on sentence boundaries: ". [A-Z]" (period+space+uppercase) or "\n".
    /// Requires uppercase after period to avoid splitting on abbreviations/decimals.
    private func emitBufferedActivitySentences() {
        while true {
            // Find earliest sentence boundary: ". [A-Z]" or "\n"
            let dotUpper = agentMessageBuffer.range(
                of: #"\. [A-Z\u{00C0}-\u{024F}`\"\[]"#,
                options: .regularExpression
            )
            let newline = agentMessageBuffer.range(of: "\n")

            let boundary: Range<String.Index>
            let isDot: Bool
            if let du = dotUpper, let nl = newline {
                if du.lowerBound < nl.lowerBound {
                    boundary = du; isDot = true
                } else {
                    boundary = nl; isDot = false
                }
            } else if let du = dotUpper {
                boundary = du; isDot = true
            } else if let nl = newline {
                boundary = nl; isDot = false
            } else {
                break
            }

            // For ". X": include the period in the sentence, leave "X..." in the buffer
            // For "\n": don't include the newline
            let sentenceEnd: String.Index
            let remainderStart: String.Index
            if isDot {
                sentenceEnd = agentMessageBuffer.index(after: boundary.lowerBound) // include "."
                remainderStart = agentMessageBuffer.index(boundary.lowerBound, offsetBy: 2) // skip ". ", keep "X"
            } else {
                sentenceEnd = boundary.lowerBound
                remainderStart = boundary.upperBound
            }

            let sentence = String(agentMessageBuffer[agentMessageBuffer.startIndex..<sentenceEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            agentMessageBuffer = String(agentMessageBuffer[remainderStart...])

            if !sentence.isEmpty {
                onOutput?("📋 \(sentence)")
            }
        }
    }

    // MARK: - Exit

    private func handleExit() {
        log("handleExit: session ended")
        isRunning = false
        activeTurnId = nil
        pendingApprovalTypes.removeAll()
        onComplete?("Session ended")
    }

    // MARK: - CLI Path Resolution

    private func findCodexCLI() -> String {
        if let path = AgentDetector.agentPath(for: .codex) {
            log("findCodexCLI: using AgentDetector path=\(path)")
            return path
        }
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
        let home = realHome.isEmpty ? NSHomeDirectory() : realHome
        let paths = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "\(home)/.local/bin/codex",
            "/usr/local/bin/codex",
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                log("findCodexCLI: found at \(path)")
                return path
            }
        }
        log("findCodexCLI: not found, defaulting to /opt/homebrew/bin/codex")
        return "/opt/homebrew/bin/codex"
    }
}
