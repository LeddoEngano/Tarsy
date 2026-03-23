import Foundation

public enum WSAction: String, Codable, Sendable {
    // Workspace
    case workspaceList = "workspace:list"
    case workspaceCreate = "workspace:create"
    case workspaceStart = "workspace:start"
    case workspaceStop = "workspace:stop"
    case workspaceStatus = "workspace:status"
    case workspaceUpdate = "workspace:update"

    // Stream
    case streamStart = "stream:start"
    case streamStop = "stream:stop"
    case streamFrame = "stream:frame"

    // Terminal
    case terminalCreate = "terminal:create"
    case terminalInput = "terminal:input"
    case terminalOutput = "terminal:output"
    case terminalClose = "terminal:close"
    case terminalList = "terminal:list"

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
