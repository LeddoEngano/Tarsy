import Foundation

class TailscaleManager {
    enum TailscaleStatus {
        case notInstalled
        case installed
        case running(ip: String)
        case error(String)
    }

    func checkStatus() async -> TailscaleStatus {
        // Check if tailscale CLI exists
        let cliPath = findTailscaleCLI()
        guard let cli = cliPath else {
            return .notInstalled
        }

        // Check if running and get IP
        do {
            let ip = try await getTailscaleIP(cli: cli)
            return .running(ip: ip)
        } catch {
            return .installed
        }
    }

    func install() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        process.arguments = ["install", "--cask", "tailscale"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TailscaleError.installFailed(output)
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
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty else {
            throw TailscaleError.noIP
        }

        return ip
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
            case .installFailed(let msg): return "Failed to install Tailscale: \(msg)"
            case .noIP: return "Could not get Tailscale IP. Is Tailscale running?"
            }
        }
    }
}
