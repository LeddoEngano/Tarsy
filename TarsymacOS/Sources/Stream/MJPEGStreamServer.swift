import Foundation
import Network
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

actor MJPEGStreamServer {
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    private let port: UInt16
    private let boundary = "tarsyframe"

    init(port: UInt16 = 8643) {
        self.port = port
    }

    func start() throws {
        let parameters = NWParameters.tcp
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        listener?.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleConnection(connection)
            }
        }

        listener?.start(queue: .global(qos: .userInitiated))
        print("[MJPEG] Streaming on port \(port)")
    }

    func stop() {
        listener?.cancel()
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()
        print("[MJPEG] Stopped")
    }

    func sendFrame(_ cgImage: CGImage) {
        guard !connections.isEmpty else { return }
        guard let jpegData = jpegEncode(cgImage, quality: 0.6) else { return }

        let header = "--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpegData.count)\r\n\r\n"
        guard let headerData = header.data(using: .ascii) else { return }

        var frameData = Data()
        frameData.append(headerData)
        frameData.append(jpegData)
        frameData.append("\r\n".data(using: .ascii)!)

        for (id, connection) in connections {
            connection.send(content: frameData, completion: .contentProcessed { [weak self] error in
                if let error {
                    print("[MJPEG] Send error for \(id): \(error)")
                    Task { await self?.removeConnection(id) }
                }
            })
        }
    }

    var clientCount: Int {
        connections.count
    }

    private func handleConnection(_ connection: NWConnection) {
        let id = UUID().uuidString
        connection.start(queue: .global(qos: .userInitiated))

        // Read the HTTP request first
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            Task {
                guard let self else { return }
                // Send HTTP response headers
                let response = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=\(self.boundary)\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
                guard let responseData = response.data(using: .ascii) else { return }

                connection.send(content: responseData, completion: .contentProcessed { error in
                    if let error {
                        print("[MJPEG] Failed to send headers: \(error)")
                    }
                })

                await self.addConnection(id, connection)
            }
        }
    }

    private func addConnection(_ id: String, _ connection: NWConnection) {
        connections[id] = connection
        print("[MJPEG] Client connected: \(id) (total: \(connections.count))")
    }

    private func removeConnection(_ id: String) {
        connections[id]?.cancel()
        connections.removeValue(forKey: id)
        print("[MJPEG] Client disconnected: \(id) (total: \(connections.count))")
    }

    private func jpegEncode(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
