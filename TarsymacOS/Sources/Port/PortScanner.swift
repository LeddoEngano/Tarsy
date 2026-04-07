import Foundation

// MARK: - Scanned Port Model

struct ScannedPort: Sendable {
    let port: Int
    let pid: Int
    let processName: String
    let workingDirectory: String?
    let framework: PortFramework?
}

enum PortFramework: String, Sendable, CaseIterable {
    case nextjs, vite, cra, angular, nuxt, remix, astro, svelte
    case express, fastify, django, flask, rails, phoenix
    case golang, cargo, gradle, docker
    case unknown

    static func detect(from processName: String) -> PortFramework? {
        let lower = processName.lowercased()
        if lower.contains("next-server") || lower.contains("next-router") { return .nextjs }
        if lower.contains("vite") { return .vite }
        if lower.contains("react-scripts") { return .cra }
        if lower.contains("angular") || lower.contains("ng") && lower.contains("serve") { return .angular }
        if lower.contains("nuxt") { return .nuxt }
        if lower.contains("remix") { return .remix }
        if lower.contains("astro") { return .astro }
        if lower.contains("svelte") || lower.contains("sveltekit") { return .svelte }
        if lower.contains("express") { return .express }
        if lower.contains("fastify") { return .fastify }
        if lower.contains("django") || lower.contains("manage.py") { return .django }
        if lower.contains("flask") || lower.contains("uvicorn") || lower.contains("gunicorn") { return .flask }
        if lower.contains("rails") || lower.contains("puma") { return .rails }
        if lower.contains("phoenix") || lower.contains("mix") { return .phoenix }
        if lower.contains("docker") { return .docker }
        return nil
    }
}

// MARK: - Port Scanner

enum PortScanner {

    /// Known dev server process names for filtering
    private static let devServerProcessNames: Set<String> = [
        "node", "next-server", "next-router-worker", "vite",
        "bun", "deno", "python", "python3", "ruby", "php",
        "uvicorn", "gunicorn", "puma", "cargo", "go",
        "java", "gradle", "dotnet", "mix", "beam.smp"
    ]

    /// Common dev server ports for fallback scanning
    static let commonDevPorts: Set<Int> = [
        3000, 3001, 3002, 4000, 4200, 5000, 5173, 5174, 8000, 8080, 8888
    ]

    // MARK: - Port Checking (IPv4 + IPv6)

    /// Check if a port is listening on IPv4 OR IPv6 (fixes Bug #6)
    static func isPortListening(port: UInt16) -> Bool {
        isPortListeningIPv4(port: port) || isPortListeningIPv6(port: port)
    }

    static func isPortListeningIPv4(port: UInt16, host: String = "127.0.0.1") -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 { return true }

        var pollFd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pollFd, 1, 200)
        return pollResult > 0 && (pollFd.revents & Int16(POLLOUT)) != 0
    }

    static func isPortListeningIPv6(port: UInt16) -> Bool {
        let sock = socket(AF_INET6, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_loopback

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }

        if result == 0 { return true }

        var pollFd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pollFd, 1, 200)
        return pollResult > 0 && (pollFd.revents & Int16(POLLOUT)) != 0
    }

    // MARK: - Async HTTP Check (fixes Bug #12)

    /// Check if a port responds to HTTP. Uses async URLSession instead of DispatchSemaphore.
    static func isHTTPResponding(port: UInt16, host: String = "127.0.0.1") async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...599).contains(http.statusCode) {
                return true
            }
        } catch {}
        // Fallback: try IPv6 if IPv4 failed
        if host == "127.0.0.1" {
            guard let url6 = URL(string: "http://[::1]:\(port)/") else { return false }
            var req6 = URLRequest(url: url6, timeoutInterval: 2)
            req6.httpMethod = "HEAD"
            do {
                let (_, response) = try await URLSession.shared.data(for: req6)
                if let http = response as? HTTPURLResponse, (200...599).contains(http.statusCode) {
                    return true
                }
            } catch {}
        }
        return false
    }

    // MARK: - Wait for Port State

    /// Poll until a port is freed (for verified stop, Bug #9)
    static func waitForPortFreed(port: UInt16, timeout: TimeInterval = 5.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isPortListening(port: port) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Poll until a port starts listening (for startup confirmation)
    static func waitForPortListening(port: UInt16, timeout: TimeInterval = 30.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isPortListening(port: port) { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    // MARK: - Batched Port Scanning (fixes Bug #7)

    /// Scan all listening TCP ports in two batched system calls.
    /// 1) lsof -iTCP -sTCP:LISTEN to get all listeners with PIDs
    /// 2) lsof -d cwd -p pid1,pid2,... to get working directories in one call
    static func scanAllListeningPorts() async -> [ScannedPort] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Step 1: Get all listening TCP ports
                let (listeners, exitCode) = runProcess(
                    "/usr/sbin/lsof",
                    arguments: ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "pcn"]
                )
                guard exitCode == 0 else {
                    continuation.resume(returning: [])
                    return
                }

                // Parse lsof output: p=pid, c=command, n=address
                var rawEntries: [(pid: Int, name: String, port: Int)] = []
                var currentPid = 0
                var currentName = ""

                for line in listeners.components(separatedBy: "\n") {
                    if line.hasPrefix("p") {
                        currentPid = Int(String(line.dropFirst())) ?? 0
                    } else if line.hasPrefix("c") {
                        currentName = String(line.dropFirst())
                    } else if line.hasPrefix("n") {
                        let addr = String(line.dropFirst())
                        if let colonIdx = addr.lastIndex(of: ":") {
                            let portStr = String(addr[addr.index(after: colonIdx)...])
                            if let port = Int(portStr), port >= 1024, port < 65535 {
                                rawEntries.append((pid: currentPid, name: currentName, port: port))
                            }
                        }
                    }
                }

                // Deduplicate by port (keep first occurrence)
                var seenPorts = Set<Int>()
                let unique = rawEntries.filter { seenPorts.insert($0.port).inserted }

                guard !unique.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }

                // Step 2: Batch CWD lookup for all PIDs at once
                let allPids = Array(Set(unique.map { $0.pid }))
                let pidArgs = allPids.map(String.init).joined(separator: ",")
                let (cwdOutput, _) = runProcess(
                    "/usr/sbin/lsof",
                    arguments: ["-d", "cwd", "-F", "pn", "-p", pidArgs]
                )

                // Parse CWD output
                var cwdMap: [Int: String] = [:]
                var cwdPid = 0
                for line in cwdOutput.components(separatedBy: "\n") {
                    if line.hasPrefix("p") {
                        cwdPid = Int(String(line.dropFirst())) ?? 0
                    } else if line.hasPrefix("n") {
                        let path = String(line.dropFirst())
                        if !path.isEmpty, path != "/" {
                            cwdMap[cwdPid] = path
                        }
                    }
                }

                // Build results
                let results = unique.map { entry in
                    ScannedPort(
                        port: entry.port,
                        pid: entry.pid,
                        processName: entry.name,
                        workingDirectory: cwdMap[entry.pid],
                        framework: PortFramework.detect(from: entry.name)
                    )
                }

                continuation.resume(returning: results.sorted { $0.port < $1.port })
            }
        }
    }

    /// Filter scanned ports to those matching a workspace path
    static func portsForWorkspace(_ workspacePath: String, from ports: [ScannedPort]) -> [ScannedPort] {
        let wsMatch = ports.filter { port in
            guard let cwd = port.workingDirectory else { return false }
            return cwd.hasPrefix(workspacePath) || workspacePath.hasPrefix(cwd)
        }.filter { isDevServerProcess($0.processName) }

        if !wsMatch.isEmpty { return wsMatch }

        // Fallback: dev servers on common ports
        return ports.filter { commonDevPorts.contains($0.port) && isDevServerProcess($0.processName) }
    }

    /// Check if a process name looks like a dev server
    static func isDevServerProcess(_ name: String) -> Bool {
        let lower = name.lowercased()
        return devServerProcessNames.contains(where: { lower.contains($0) })
    }

    // MARK: - Process Helper

    private static func runProcess(_ executablePath: String, arguments: [String]) -> (output: String, exitCode: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (output, proc.terminationStatus)
        } catch {
            return ("", -1)
        }
    }
}
