import Foundation

actor InjectionServer {

    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var listenTask: Task<Void, Never>?
    private(set) var socketPath: String?
    private(set) var isClientConnected = false

    var onClientConnected: (@Sendable () async -> Void)?
    var onClientDisconnected: (@Sendable () async -> Void)?
    var onStatusReceived: (@Sendable (String) async -> Void)?

    // MARK: - Start

    func start() -> String {
        stop()

        let path = "/tmp/tarsy-hotreload-\(UUID().uuidString.prefix(8)).sock"
        socketPath = path

        // Remove stale socket file
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            socketPath = nil
            return ""
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            _ = path.withCString { strncpy(buf, $0, 104) }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &addr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, addrLen)
            }
        }) == 0 else {
            close(fd)
            socketPath = nil
            return ""
        }

        guard listen(fd, 1) == 0 else {
            close(fd)
            socketPath = nil
            return ""
        }

        listenFD = fd

        // Accept connections on background thread
        listenTask = Task.detached { [weak self] in
            await self?.acceptLoop()
        }

        return path
    }

    // MARK: - Stop

    func stop() {
        listenTask?.cancel()
        listenTask = nil

        if clientFD >= 0 {
            close(clientFD)
            clientFD = -1
            isClientConnected = false
        }
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        if let path = socketPath {
            unlink(path)
            socketPath = nil
        }
    }

    // MARK: - Send Commands

    func sendLoad(dylibPath: String) async -> Bool {
        guard clientFD >= 0 else { return false }
        let msg = "LOAD \(dylibPath)\n"
        return sendLine(msg)
    }

    func sendPing() -> Bool {
        guard clientFD >= 0 else { return false }
        return sendLine("PING\n")
    }

    // MARK: - Accept Loop

    private func acceptLoop() async {
        while !Task.isCancelled && listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            // Close previous client if any
            if clientFD >= 0 { close(clientFD) }
            clientFD = fd
            isClientConnected = true
            await onClientConnected?()

            // Read loop for this client
            await readLoop(fd: fd)

            // Client disconnected
            if clientFD == fd {
                clientFD = -1
                isClientConnected = false
                await onClientDisconnected?()
            }
        }
    }

    private func readLoop(fd: Int32) async {
        var buffer = [CChar](repeating: 0, count: 8192)
        var lineBuffer = ""

        while !Task.isCancelled {
            let n = read(fd, &buffer, buffer.count - 1)
            if n <= 0 { break }
            buffer[n] = 0

            lineBuffer += String(cString: buffer)

            // Process complete lines
            while let newline = lineBuffer.firstIndex(of: "\n") {
                let line = String(lineBuffer[..<newline])
                lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])

                if !line.isEmpty {
                    await onStatusReceived?(line)
                }
            }
        }
    }

    // MARK: - Helpers

    private func sendLine(_ line: String) -> Bool {
        guard clientFD >= 0 else { return false }
        let data = Array(line.utf8)
        var sent = 0
        while sent < data.count {
            let n = write(clientFD, data[sent...].withUnsafeBufferPointer { $0.baseAddress! }, data.count - sent)
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}
