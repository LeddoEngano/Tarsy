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

        let brewPath = findBrew()
        guard let brew = brewPath else {
            throw TailscaleError.installFailed("Homebrew not found. Install it from https://brew.sh")
        }

        // Step 1: Download the cask (no sudo needed)
        appendLog("→ Downloading tailscale-app...\n")
        onOutput("→ Downloading tailscale-app...\n")
        installProgress = 0.1

        let downloadResult = try await runProcess(
            executable: brew,
            arguments: ["fetch", "--cask", "tailscale-app"],
            env: ["HOMEBREW_NO_AUTO_UPDATE": "1"],
            onOutput: { [weak self] text in
                Task { @MainActor in
                    self?.appendLog(text)
                    self?.updateProgress(from: text)
                    onOutput(text)
                }
            }
        )

        installProgress = 0.5
        appendLog("→ Download complete. Installing...\n")
        onOutput("→ Installing...\n")

        // Step 2: Find the downloaded .pkg in the Caskroom and install it directly
        // Using osascript "do shell script ... with administrator privileges" runs
        // only the installer as admin (not brew itself, which refuses to run as root)
        let pkgPath = try await findDownloadedPkg()

        appendLog("→ Found package: \(pkgPath)\n")
        appendLog("→ macOS will ask for your password...\n")
        onOutput("→ macOS will ask for your password...\n")

        installProgress = 0.6

        let installScript = """
        do shell script "/usr/sbin/installer -pkg \\\"\(pkgPath)\\\" -target / 2>&1" with administrator privileges
        """

        let installResult = try await runProcess(
            executable: "/usr/bin/osascript",
            arguments: ["-e", installScript],
            onOutput: { [weak self] text in
                Task { @MainActor in
                    self?.appendLog(text)
                    self?.updateProgress(from: text)
                    onOutput(text)
                }
            }
        )

        installProgress = 0.9

        // Check if installed
        let appInstalled = FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")
        let caskInstalled = FileManager.default.fileExists(atPath: "/opt/homebrew/Caskroom/tailscale-app")

        if appInstalled || caskInstalled {
            installProgress = 1.0
            appendLog("\n✓ Tailscale installed successfully!\n")
            appendLog("→ Opening Tailscale — please sign in.\n")
            onOutput("\n✓ Installed! Opening Tailscale...\n")

            if appInstalled {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app"))
            }
        } else {
            throw TailscaleError.installFailed(installResult)
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

    private func findDownloadedPkg() async throws -> String {
        // brew fetch downloads to the cache, then stages in Caskroom
        let caskroomPath = "/opt/homebrew/Caskroom/tailscale-app"
        let cachePath = NSHomeDirectory() + "/Library/Caches/Homebrew/downloads"

        // Check Caskroom first
        if FileManager.default.fileExists(atPath: caskroomPath) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: caskroomPath)
            for version in contents {
                let versionDir = "\(caskroomPath)/\(version)"
                let pkgs = try? FileManager.default.contentsOfDirectory(atPath: versionDir)
                if let pkg = pkgs?.first(where: { $0.hasSuffix(".pkg") }) {
                    return "\(versionDir)/\(pkg)"
                }
            }
        }

        // Check brew cache
        if FileManager.default.fileExists(atPath: cachePath) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: cachePath)
            if let pkg = contents.first(where: { $0.lowercased().contains("tailscale") && $0.hasSuffix(".pkg") }) {
                return "\(cachePath)/\(pkg)"
            }
        }

        throw TailscaleError.installFailed("Could not find downloaded Tailscale package. Try running: brew install --cask tailscale-app in Terminal.")
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

    @discardableResult
    private func runProcess(
        executable: String,
        arguments: [String],
        env: [String: String]? = nil,
        onOutput: @escaping (String) -> Void
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var processEnv = ProcessInfo.processInfo.environment
        if let env {
            for (k, v) in env { processEnv[k] = v }
        }
        process.environment = processEnv

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let accumulator = OutputAccumulator()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            accumulator.append(text)
            onOutput(text)
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            accumulator.append(text)
            onOutput(text)
        }

        try process.run()

        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }

        try? await Task.sleep(nanoseconds: 300_000_000)

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        return accumulator.value
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
