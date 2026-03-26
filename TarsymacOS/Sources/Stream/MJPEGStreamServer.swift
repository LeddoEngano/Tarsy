import Foundation
import Network
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

actor MJPEGStreamServer {
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    private let port: UInt16
    private let boundary = "tarsyframe"
    private var relaySendInFlight = false
    // Track connections with errors to stop sending immediately (before actor processes removal)
    private let _deadConnections = OSAllocatedUnfairLock(initialState: Set<String>())

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

    private var jpegQuality: CGFloat = 0.6
    private var maxFrameSize: Int = 200_000
    // Thread-safe quality value for nonisolated encoding
    private let _currentQuality = OSAllocatedUnfairLock(initialState: CGFloat(0.6))

    func setQuality(jpegQuality: CGFloat, maxFrameSize: Int) {
        self.jpegQuality = jpegQuality
        self.maxFrameSize = maxFrameSize
        _currentQuality.withLock { $0 = jpegQuality }
    }

    /// Encode JPEG off-actor — no actor hop needed, runs on caller's thread
    nonisolated func encodeJPEG(_ cgImage: CGImage) -> Data? {
        let quality = _currentQuality.withLock { $0 }
        return Self.jpegEncodeStatic(cgImage, quality: quality)
    }

    /// Send pre-encoded JPEG data to local MJPEG clients
    func sendEncodedFrame(_ jpegData: Data) {
        guard !connections.isEmpty else { return }

        let header = "--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpegData.count)\r\n\r\n"
        guard let headerData = header.data(using: .ascii) else { return }

        var frameData = Data()
        frameData.reserveCapacity(headerData.count + jpegData.count + 4)
        frameData.append(headerData)
        frameData.append(jpegData)
        frameData.append("\r\n".data(using: .ascii)!)

        let deadConns = _deadConnections.withLock { $0 }
        for (id, connection) in connections where !deadConns.contains(id) {
            connection.send(content: frameData, completion: .contentProcessed { [weak self] error in
                if let error {
                    // Mark as dead immediately (lock-based, no actor hop)
                    self?._deadConnections.withLock { $0.insert(id) }
                    print("[MJPEG] Send error for \(id): \(error)")
                    Task { await self?.removeConnection(id) }
                }
            })
        }
    }

    /// Legacy: Encode + send in one call (for backwards compat)
    func sendFrame(_ cgImage: CGImage) -> Data? {
        guard let jpegData = jpegEncodeStatic(cgImage, quality: jpegQuality) else { return nil }
        sendEncodedFrame(jpegData)
        return jpegData
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
        guard connections[id] != nil else { return } // Already removed
        connections[id]?.cancel()
        connections.removeValue(forKey: id)
        _deadConnections.withLock { $0.remove(id) }
        print("[MJPEG] Client disconnected: \(id) (total: \(connections.count))")
    }

    /// Check if relay is ready for a new frame (not still sending the previous one)
    var isRelayReady: Bool { !relaySendInFlight }

    func markRelaySending() { relaySendInFlight = true }
    func markRelaySent() { relaySendInFlight = false }

    private nonisolated static func jpegEncodeStatic(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func jpegEncodeStatic(_ image: CGImage, quality: CGFloat) -> Data? {
        Self.jpegEncodeStatic(image, quality: quality)
    }
}
