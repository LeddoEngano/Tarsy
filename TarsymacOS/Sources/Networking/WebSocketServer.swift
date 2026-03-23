import Foundation
import Network
import TarsyShared

actor WebSocketServer {
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    private let port: UInt16
    private let validateToken: @Sendable (String) async -> Bool

    private var onPacketReceived: (@Sendable (String, WSPacket) async -> Void)?
    private var onClientConnected: (@Sendable (String) -> Void)?
    private var onClientDisconnected: (@Sendable (String) -> Void)?

    init(port: UInt16 = TarsyConfig.websocketPort, validateToken: @escaping @Sendable (String) async -> Bool) {
        self.port = port
        self.validateToken = validateToken
    }

    func setHandlers(
        onPacket: @escaping @Sendable (String, WSPacket) async -> Void,
        onConnect: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable (String) -> Void
    ) {
        self.onPacketReceived = onPacket
        self.onClientConnected = onConnect
        self.onClientDisconnected = onDisconnect
    }

    func start() throws {
        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleNewConnection(connection)
            }
        }
        listener?.start(queue: .global(qos: .userInitiated))
        print("[WSServer] Listening on port \(port)")
    }

    func stop() {
        listener?.cancel()
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        print("[WSServer] Stopped")
    }

    func send(_ packet: WSPacket, to clientId: String) {
        guard let connection = connections[clientId],
              let data = try? packet.encode() else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    func broadcast(_ packet: WSPacket) {
        for clientId in connections.keys {
            send(packet, to: clientId)
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let clientId = UUID().uuidString
        connections[clientId] = connection

        connection.start(queue: .global(qos: .userInitiated))
        receiveLoop(connection: connection, clientId: clientId, authenticated: false)

        print("[WSServer] Client connected: \(clientId)")
    }

    private func receiveLoop(connection: NWConnection, clientId: String, authenticated: Bool) {
        connection.receiveMessage { [weak self] content, context, _, error in
            Task {
                guard let self else { return }

                if let error {
                    print("[WSServer] Receive error: \(error)")
                    await self.removeConnection(clientId)
                    return
                }

                if let data = content, let packet = try? WSPacket.decode(from: data) {
                    if !authenticated {
                        if packet.action == .auth, let token = packet.payload?["token"] {
                            let valid = await self.validateToken(token)
                            if valid {
                                await self.send(WSPacket(action: .authSuccess), to: clientId)
                                await self.onClientConnected?(clientId)
                                await self.receiveLoop(connection: connection, clientId: clientId, authenticated: true)
                            } else {
                                await self.send(WSPacket(action: .authFail), to: clientId)
                                await self.removeConnection(clientId)
                            }
                        } else {
                            await self.send(WSPacket(action: .authFail, payload: ["reason": "not authenticated"]), to: clientId)
                        }
                        return
                    }

                    if packet.action == .ping {
                        await self.send(WSPacket(action: .pong, id: packet.id), to: clientId)
                        await self.receiveLoop(connection: connection, clientId: clientId, authenticated: true)
                        return
                    }

                    await self.onPacketReceived?(clientId, packet)
                    await self.receiveLoop(connection: connection, clientId: clientId, authenticated: true)
                }
            }
        }
    }

    private func removeConnection(_ clientId: String) {
        connections[clientId]?.cancel()
        connections.removeValue(forKey: clientId)
        onClientDisconnected?(clientId)
        print("[WSServer] Client disconnected: \(clientId)")
    }
}
