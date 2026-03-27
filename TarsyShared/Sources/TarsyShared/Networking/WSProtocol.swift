import Foundation

public enum WSAction: String, Codable, Sendable {
    // Workspace
    case workspaceList = "workspace:list"
    case workspaceCreate = "workspace:create"
    case workspaceStart = "workspace:start"
    case workspaceStop = "workspace:stop"
    case workspaceStatus = "workspace:status"
    case workspaceUpdate = "workspace:update"
    case workspaceScanRepos = "workspace:scan_repos"
    case workspaceScanResult = "workspace:scan_result"

    // Stream
    case streamStart = "stream:start"
    case streamStop = "stream:stop"
    case streamFrame = "stream:frame"

    // Remote Input
    case remoteTap = "remote:tap"
    case remoteDoubleTap = "remote:double_tap"
    case remoteLongPress = "remote:long_press"
    case remoteScroll = "remote:scroll"
    case remoteDrag = "remote:drag"
    case remoteScrollStart = "remote:scroll_start"
    case remoteScrollEnd = "remote:scroll_end"
    case remotePinch = "remote:pinch"
    case remotePinchStart = "remote:pinch_start"
    case remotePinchEnd = "remote:pinch_end"
    case remoteKeyboard = "remote:keyboard"
    case remoteButton = "remote:button"
    case screenshotRequest = "screenshot:request"
    case screenshotResult = "screenshot:result"

    // Dev Server
    case devServerStart = "devserver:start"
    case devServerStop = "devserver:stop"
    case devServerStatus = "devserver:status"

    // Browser
    case browserOpenUrl = "browser:open_url"
    case browserBack = "browser:back"
    case browserForward = "browser:forward"
    case browserRefresh = "browser:refresh"
    case browserMobileViewport = "browser:mobile_viewport"
    case browserDesktopViewport = "browser:desktop_viewport"
    case browserTabList = "browser:tab_list"
    case browserTabListResult = "browser:tab_list_result"
    case browserTabSwitch = "browser:tab_switch"
    case browserTabClose = "browser:tab_close"

    // HTTP Proxy (WKWebView tunnel)
    case proxyDetectPorts = "proxy:detect_ports"
    case proxyDetectPortsResult = "proxy:detect_ports_result"
    case proxyRequest = "proxy:request"
    case proxyResponse = "proxy:response"

    // Terminal
    case terminalCreate = "terminal:create"
    case terminalInput = "terminal:input"
    case terminalOutput = "terminal:output"
    case terminalClose = "terminal:close"
    case terminalList = "terminal:list"

    // Claude Code
    case claudeCreate = "claude:create"
    case claudeMessage = "claude:message"
    case claudeOutput = "claude:output"
    case claudeComplete = "claude:complete"
    case claudeClose = "claude:close"
    case claudeAskUser = "claude:ask_user"
    case claudeUserResponse = "claude:user_response"

    // OpenClaw
    case openclawStatus = "openclaw:status"
    case openclawMessage = "openclaw:message"
    case openclawOutput = "openclaw:output"
    case openclawComplete = "openclaw:complete"

    // Generic Engine (multi-provider)
    case engineCreate = "engine:create"
    case engineMessage = "engine:message"
    case engineOutput = "engine:output"
    case engineComplete = "engine:complete"
    case engineClose = "engine:close"
    case engineAskUser = "engine:ask_user"
    case engineUserResponse = "engine:user_response"

    // Git
    case gitCheckpoint = "git:checkpoint"
    case gitCheckpointResult = "git:checkpoint_result"
    case gitDiff = "git:diff"
    case gitDiffResult = "git:diff_result"
    case gitRollback = "git:rollback"
    case gitRollbackResult = "git:rollback_result"
    case gitHistory = "git:history"
    case gitHistoryResult = "git:history_result"
    case gitFileDiff = "git:file_diff"
    case gitFileDiffResult = "git:file_diff_result"
    case gitBranches = "git:branches"
    case gitBranchesResult = "git:branches_result"
    case gitCheckout = "git:checkout"
    case gitCheckoutResult = "git:checkout_result"
    case gitPull = "git:pull"
    case gitPullResult = "git:pull_result"

    // File Explorer
    case fileTree = "file:tree"
    case fileTreeResult = "file:tree_result"
    case fileRead = "file:read"
    case fileReadResult = "file:read_result"

    // Engine Status (model, tokens, context %)
    case engineStatus = "engine:status"

    // MCP Store
    case mcpList = "mcp:list"
    case mcpListResult = "mcp:list_result"
    case mcpHealthCheck = "mcp:health_check"
    case mcpHealthResult = "mcp:health_result"

    // Relay
    case relayMachineOnline = "relay:machine_online"
    case relayMachineOffline = "relay:machine_offline"
    case relayStreamFrame = "relay:stream_frame"

    // Sudo
    case sudoRequest = "sudo:request"
    case sudoResponse = "sudo:response"
    case sudoResult = "sudo:result"

    // Agent Detection
    case agentsDetected = "agents:detected"

    // Agent Settings
    case agentSettings = "agent:settings"
    case agentSettingsUpdate = "agent:settings_update"

    // Repo Analysis
    case repoAnalyze = "repo:analyze"
    case repoAnalysis = "repo:analysis"

    // AI Project Wizard
    case wizardStart = "wizard:start"
    case wizardResponse = "wizard:response"
    case wizardExecute = "wizard:execute"
    case wizardResult = "wizard:result"
    case wizardGhDetected = "wizard:gh_detected"

    // UltraContext
    case ultracontextStatus = "ultracontext:status"

    // System
    case auth
    case authSuccess = "auth:success"
    case authFail = "auth:fail"
    case ping
    case pong
    case error
}

public struct WSPacket: Codable, Sendable {
    public let id: String
    public let action: WSAction
    public let payload: [String: String]?
    public let timestamp: Date

    public init(action: WSAction, payload: [String: String]? = nil, id: String = UUID().uuidString) {
        self.id = id
        self.action = action
        self.payload = payload
        self.timestamp = Date()
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> WSPacket {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WSPacket.self, from: data)
    }
}
