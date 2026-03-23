import Foundation
import AppKit

@MainActor
class TailscaleManager: ObservableObject {
    @Published var installProgress: Double = 0
    @Published var installLog: String = ""
    @Published var isInstalling = false

    enum TailscaleStatus {
        case notInstalled
        case installed
        case running(ip: String)
        case error(String)
    }

    func checkStatus() async -> TailscaleStatus {
        let cliPath = findTailscaleCLI()
        let appExists = FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")

        if cliPath == nil && !appExists {
            return .notInstalled
        }

        // App installed but CLI might not be in PATH
        if let cli = cliPath {
            do {
                let ip = try await getTailscaleIP(cli: cli)
                return .running(ip: ip)
            } catch {
                return .installed
            }
        }

        return .installed
    }

    func install(onOutput: @escaping (String) -> Void) async throws {
        isInstalling = true
        installProgress = 0
        installLog = ""

        defer { isInstalling = false }

        // Find brew
        let brewPath = findBrew()
        guard let brew = brewPath else {
            throw TailscaleError.installFailed("Homebrew not found. Install it from https://brew.sh")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "--cask", "tailscale-app"]

        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        process.environment = env

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputAccumulator = OutputAccumulator()

        // Read stdout in real-time
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            outputAccumulator.append(text)
            Task { @MainActor in
                self?.appendLog(text)
                self?.updateProgress(from: text)
                onOutput(text)
            }
        }

        // Read stderr in real-time (brew writes progress here)
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            outputAccumulator.append(text)
            Task { @MainActor in
                self?.appendLog(text)
                self?.updateProgress(from: text)
                onOutput(text)
            }
        }

        try process.run()

        // Wait on background thread
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }

        // Give pipes a moment to flush remaining data
        try? await Task.sleep(nanoseconds: 500_000_000)

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        // Check if Tailscale.app exists regardless of exit code
        // (brew returns non-zero for caveats like kernel extension warnings)
        let appInstalled = FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")
        let caskInstalled = FileManager.default.fileExists(atPath: "/opt/homebrew/Caskroom/tailscale-app")

        if appInstalled || caskInstalled {
            installProgress = 1.0
            appendLog("\n✓ Tailscale installed successfully!\n")
            appendLog("→ Opening Tailscale — please sign in.\n")

            // Open Tailscale app
            if appInstalled {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app"))
            }
        } else {
            let output = outputAccumulator.value
            throw TailscaleError.installFailed(output.isEmpty ? "Installation failed with exit code \(process.terminationStatus)" : output)
        }
    }

    func getTailscaleIP(cli: String? = nil) async throws -> String {
        let cliPath = cli ?? findTailscaleCLI()
        guard let path = cliPath else {
            throw TailscaleError.notInstalled
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["ip", "-4"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()

        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty else {
            throw TailscaleError.noIP
        }

        return ip
    }

    // MARK: - Private

    private func appendLog(_ text: String) {
        installLog += text
    }

    private func updateProgress(from text: String) {
        let lower = text.lowercased()
        if lower.contains("downloading") || lower.contains("fetching") {
            installProgress = max(installProgress, 0.2)
        }
        if lower.contains("downloaded") {
            installProgress = max(installProgress, 0.5)
        }
        if lower.contains("installing") || lower.contains("cask") {
            installProgress = max(installProgress, 0.6)
        }
        if lower.contains("linking") || lower.contains("moving") {
            installProgress = max(installProgress, 0.8)
        }
        if lower.contains("caveats") || lower.contains("installed") {
            installProgress = max(installProgress, 0.9)
        }
    }

    private func findBrew() -> String? {
        let paths = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func findTailscaleCLI() -> String? {
        let paths = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    enum TailscaleError: LocalizedError {
        case notInstalled
        case installFailed(String)
        case noIP

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Tailscale is not installed"
            case .installFailed(let msg): return "Install failed: \(msg)"
            case .noIP: return "Could not get Tailscale IP. Open Tailscale app and sign in first."
            }
        }
    }
}

// Thread-safe string accumulator for pipe output
private class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func append(_ text: String) {
        lock.lock()
        _value += text
        lock.unlock()
    }
}
