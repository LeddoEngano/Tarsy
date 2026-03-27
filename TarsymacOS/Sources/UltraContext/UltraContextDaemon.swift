import Foundation

class UltraContextDaemon {
    static let shared = UltraContextDaemon()

    private var process: Process?
    private(set) var isRunning = false

    /// Check if ultracontext CLI is installed
    func isInstalled() -> Bool {
        let paths = [
            "/opt/homebrew/bin/ultracontext",
            "/usr/local/bin/ultracontext",
            "\(realHome())/.local/bin/ultracontext",
            "\(realHome())/.npm-global/bin/ultracontext"
        ]
        return paths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Find the ultracontext CLI path
    func findCLI() -> String? {
        let paths = [
            "/opt/homebrew/bin/ultracontext",
            "/usr/local/bin/ultracontext",
            "\(realHome())/.local/bin/ultracontext",
            "\(realHome())/.npm-global/bin/ultracontext"
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Start the daemon
    func start() {
        guard !isRunning, let cliPath = findCLI() else {
            print("[UltraContext] CLI not found or already running")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = ["start"]

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = realHome()
        proc.environment = env

        proc.terminationHandler = { [weak self] _ in
            self?.isRunning = false
            print("[UltraContext] Daemon stopped")
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            print("[UltraContext] Daemon started with PID \(proc.processIdentifier)")
        } catch {
            print("[UltraContext] Failed to start daemon: \(error)")
        }
    }

    /// Stop the daemon
    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    /// Get daemon status
    func status() -> String {
        guard let cliPath = findCLI() else { return "not installed" }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = ["status"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = realHome()
        proc.environment = env

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    private func realHome() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
    }
}
