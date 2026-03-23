import Foundation

public enum WSMessageType: String, Codable, Sendable {
    // Workspace
    case workspaceList = "workspace:list"
    case workspaceCreate = "workspace:create"
    case workspaceStart = "workspace:start"
    case workspaceStop = "workspace:stop"
    case workspaceStatus = "workspace:status"

    // Stream
    case streamStart = "stream:start"
    case streamStop = "stream:stop"

    // Terminal
    case terminalCreate = "terminal:create"
    case terminalInput = "terminal:input"
    case terminalOutput = "terminal:output"
    case terminalClose = "terminal:close"

    // System
    case auth
    case ping
    case pong
    case error
}

public struct WSMessage: Codable, Sendable {
    public let type: WSMessageType
    public let payload: [String: String]?
    public let id: String

    public init(type: WSMessageType, payload: [String: String]? = nil, id: String = UUID().uuidString) {
        self.type = type
        self.payload = payload
        self.id = id
    }
}
