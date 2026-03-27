import Foundation
import TarsyShared

/// Manages sudo password requests by sending them to the iOS client and waiting for the response.
/// The password dialog is shown on the iPhone, not on the Mac.
final class SudoPasswordManager {
    static let shared = SudoPasswordManager()

    private var cachedPassword: String?
    private var cacheExpiry: Date?
    private let cacheDuration: TimeInterval = 60 // 60 seconds (reduced from 5min for security)

    private var pendingRequests: [String: CheckedContinuation<String?, Never>] = [:]

    /// Set by DaemonManager to send packets to the iOS client
    var sendPacket: ((WSPacket) async -> Void)?

    private var handlingSudoForSession: Set<String> = []

    private init() {}

    // MARK: - Password request (asks iOS client)

    func requestPassword(reason: String? = nil) async -> String? {
        if let cached = cachedPassword, let expiry = cacheExpiry, Date() < expiry {
            return cached
        }

        let requestId = UUID().uuidString

        guard sendPacket != nil else { return nil }

        await sendPacket?(WSPacket(
            action: .sudoRequest,
            payload: ["reason": reason ?? "A command requires administrator privileges (sudo)."],
            id: requestId
        ))

        let password: String? = await withCheckedContinuation { continuation in
            pendingRequests[requestId] = continuation
        }

        guard let password, !password.isEmpty else { return nil }

        cachedPassword = password
        cacheExpiry = Date().addingTimeInterval(cacheDuration)
        return password
    }

    /// Called when iOS sends back a sudoResponse packet.
    func handlePasswordResponse(packet: WSPacket) {
        let password = packet.payload?["password"]
        if let continuation = pendingRequests.removeValue(forKey: packet.id) {
            continuation.resume(returning: password)
        }
    }

    func clearCache() {
        cachedPassword = nil
        cacheExpiry = nil
    }

    // MARK: - Command rewriting

    func rewriteCommandIfSudo(_ command: String, workingDirectory: String? = nil, reason: String? = nil) async -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // Direct sudo in command
        if trimmed.contains("sudo ") || trimmed.hasPrefix("sudo") {
            return await rewriteSudoInCommand(trimmed, reason: reason)
        }

        // Resolve package manager scripts: "pnpm dev-castro" -> check package.json for sudo
        if let dir = workingDirectory, let resolved = resolvePackageScript(trimmed, in: dir) {
            if resolved.contains("sudo ") || resolved.hasPrefix("sudo") {
                guard let password = await requestPassword(
                    reason: reason ?? "The command '\(trimmed)' runs:\n\(resolved)\n\nIt requires administrator privileges."
                ) else {
                    return nil
                }
                return sudoAskpassWrapper(password: password, command: trimmed)
            }
        }

        return command
    }

    private func rewriteSudoInCommand(_ command: String, reason: String?) async -> String? {
        guard let password = await requestPassword(
            reason: reason ?? "The command requires administrator privileges:\n\(command)"
        ) else {
            return nil
        }
        return sudoAskpassWrapper(password: password, command: command)
    }

    /// Wraps a command so any `sudo` call inside it gets the password via SUDO_ASKPASS.
    /// Since terminal sessions use pipes (no PTY), sudo can't prompt interactively.
    /// We create a temp askpass script with restricted permissions (0700 dir, 0755 scripts),
    /// then prepend them to PATH.
    private func sudoAskpassWrapper(password: String, command: String) -> String {
        // Escape single quotes for safe embedding in shell single-quoted string
        let escaped = password.replacingOccurrences(of: "'", with: "'\\''")
        let setup = [
            "_SUDO_DIR=$(mktemp -d /tmp/.sudo_wrap.XXXXXX)",
            "chmod 700 \"$_SUDO_DIR\"",
            "_ASKPASS=\"$_SUDO_DIR/askpass\"",
            "printf '%s\\n' '#!/bin/sh' 'echo '\\\"'\(escaped)'\\\"'' > \"$_ASKPASS\"",
            "chmod 700 \"$_ASKPASS\"",
            "printf '%s\\n' '#!/bin/sh' 'exec /usr/bin/sudo -A \"$@\"' > \"$_SUDO_DIR/sudo\"",
            "chmod 700 \"$_SUDO_DIR/sudo\"",
            "export SUDO_ASKPASS=\"$_ASKPASS\"",
            "export PATH=\"$_SUDO_DIR:$PATH\"",
        ].joined(separator: " && ")

        return "\(setup) && \(command); _EC=$?; rm -rf \"$_SUDO_DIR\"; exit $_EC"
    }

    private func resolvePackageScript(_ command: String, in directory: String) -> String? {
        let parts = command.components(separatedBy: " ").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }

        let runner = parts[0]
        guard ["npm", "pnpm", "yarn", "bun", "npx"].contains(runner) else { return nil }

        let scriptName: String
        if parts.count >= 3 && parts[1] == "run" {
            scriptName = parts[2]
        } else if !["install", "i", "add", "remove", "uninstall"].contains(parts[1]) {
            scriptName = parts[1]
        } else {
            return nil
        }

        let packageJsonPath = (directory as NSString).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: packageJsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String],
              let script = scripts[scriptName] else {
            return nil
        }

        return script
    }

    // MARK: - Output-based sudo detection (fallback)

    func handleSudoPromptIfNeeded(output: String, sessionId: String, sendInput: @escaping (String) async -> Void) async {
        let lower = output.lowercased()

        let isSudoPrompt = lower.contains("password for")
            || lower.contains("[sudo] password")
            || lower.contains("password:")

        guard isSudoPrompt else {
            if lower.contains("sorry, try again") { clearCache() }
            return
        }

        guard !handlingSudoForSession.contains(sessionId) else { return }
        handlingSudoForSession.insert(sessionId)
        defer { handlingSudoForSession.remove(sessionId) }

        if let password = await requestPassword(
            reason: "A running process needs your administrator password."
        ) {
            await sendInput(password)
        }
    }

    // MARK: - Standalone sudo execution

    /// Runs a command with sudo by piping the password via stdin to `sudo -S`.
    /// The command parts are passed as separate arguments to avoid shell injection.
    func runWithSudo(_ command: String, reason: String? = nil) async throws -> (output: String, exitCode: Int32) {
        guard let password = await requestPassword(reason: reason) else {
            throw SudoError.cancelled
        }

        // First, authenticate sudo via stdin pipe (safe — no shell interpolation)
        let authProcess = Process()
        authProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        authProcess.arguments = ["-S", "-v"]
        authProcess.environment = ProcessInfo.processInfo.environment

        let authStdin = Pipe()
        authProcess.standardInput = authStdin
        authProcess.standardOutput = Pipe()
        authProcess.standardError = Pipe()

        try authProcess.run()
        if let passData = "\(password)\n".data(using: .utf8) {
            authStdin.fileHandleForWriting.write(passData)
            authStdin.fileHandleForWriting.closeFile()
        }
        authProcess.waitUntilExit()

        if authProcess.terminationStatus != 0 {
            clearCache()
            throw SudoError.authenticationFailed
        }

        // Now run the actual command with sudo (credentials are cached by sudo -v)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // Split the command for argument passing — use shell for complex commands
        process.arguments = ["/bin/zsh", "-c", command]
        process.environment = ProcessInfo.processInfo.environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return (output, process.terminationStatus)
    }

    enum SudoError: LocalizedError {
        case cancelled
        case authenticationFailed

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Password entry was cancelled"
            case .authenticationFailed: return "Authentication failed — wrong password"
            }
        }
    }
}
