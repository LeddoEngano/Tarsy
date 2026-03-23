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

    // Dev Server
    case devServerStart = "devserver:start"
    case devServerStop = "devserver:stop"
    case devServerStatus = "devserver:status"

    // Browser
    case browserOpenUrl = "browser:open_url"

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
