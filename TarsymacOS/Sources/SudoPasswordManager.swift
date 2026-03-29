import Foundation
import TarsyShared

/// Manages sudo password requests by sending them to the iOS client and waiting for the response.
/// The password dialog is shown on the iPhone, not on the Mac.
/// Actor ensures thread-safe access to mutable state (password cache, pending requests).
actor SudoPasswordManager {
    static let shared = SudoPasswordManager()

    private var cachedPassword: [UInt8]?
    private var cacheExpiry: Date?
    private let cacheDuration: TimeInterval = 60 // 60 seconds

    private var pendingRequests: [String: CheckedContinuation<String?, Never>] = [:]

    /// Set by DaemonManager to send packets to the iOS client
    private var sendPacket: ((WSPacket) async -> Void)?

    func setSendPacket(_ handler: @escaping (WSPacket) async -> Void) {
        sendPacket = handler
    }

    private var handlingSudoForSession: Set<String> = []

    // MARK: - Sudo Command Whitelist

    enum SudoCategory: String, Codable, CaseIterable {
        case packageManagers
        case filePermissions
        case processControl
        case devTools
    }

    private static let categoryPatterns: [SudoCategory: [String]] = [
        .packageManagers: [
            "npm install", "npm ci", "npm rebuild", "npm cache clean",
            "yarn install", "yarn add",
            "pnpm install", "pnpm add",
            "bun install", "bun add",
            "gem install", "bundle install",
            "pip install", "pip3 install",
            "brew install", "brew upgrade", "brew update",
            "apt-get install", "apt-get update",
            "cargo install",
        ],
        .filePermissions: ["chmod", "chown", "mkdir"],
        .processControl: ["kill", "killall", "launchctl", "pkill"],
        .devTools: ["xcode-select", "xcodebuild", "softwareupdate"],
    ]

    /// Shell metacharacters that indicate command chaining (potential injection)
    private static let dangerousPatterns = ["; ", " && ", " || ", " | ", "$(", "`", " > ", " >> ", " < "]

    /// Known sudo flags to strip when parsing commands
    private static let sudoFlags: Set<String> = ["-S", "-E", "-v", "-k", "-K", "-n", "-H", "-P", "-b"]

    /// Active categories — loaded from Supabase profile, configurable from iPhone
    private(set) var enabledCategories: Set<SudoCategory> = Set(SudoCategory.allCases)

    func setEnabledCategories(_ categories: Set<SudoCategory>) {
        enabledCategories = categories
    }

    /// Validates that a command matches the whitelist.
    /// Uses exact word-boundary matching to prevent prefix bypass attacks.
    func isCommandAllowed(_ command: String) -> Bool {
        let parts = parseCommandParts(command)
        let baseCommand = parts.joined(separator: " ")
        guard !baseCommand.isEmpty else { return false }

        // Check against allowed patterns in enabled categories
        for category in enabledCategories {
            guard let patterns = Self.categoryPatterns[category] else { continue }
            for pattern in patterns {
                // Exact match or pattern followed by a space + arguments (word boundary)
                if baseCommand == pattern || baseCommand.hasPrefix(pattern + " ") {
                    let rest = String(baseCommand.dropFirst(pattern.count))
                    let hasDangerousChars = Self.dangerousPatterns.contains { rest.contains($0) }
                    if !hasDangerousChars {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Parses a command string into executable and arguments, stripping "sudo" prefix and its flags.
    /// Does NOT use shell interpretation — splits on whitespace only.
    private func parseCommandParts(_ command: String) -> [String] {
        var parts = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        // Strip "sudo" and known sudo flags
        if parts.first == "sudo" {
            parts.removeFirst()
            while let first = parts.first, Self.sudoFlags.contains(first) {
                parts.removeFirst()
            }
        }

        return parts
    }

    /// Resolves a command name to its full path by checking common locations.
    private func resolveExecutablePath(_ name: String) -> String {
        if name.hasPrefix("/") { return name }

        let searchPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
            "/usr/sbin/\(name)",
            "/sbin/\(name)",
        ]

        return searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? name
    }

    // MARK: - Secure password memory

    /// Store password as zeroed-on-clear byte array instead of immutable String
    private func cachePassword(_ password: String) {
        clearPasswordBytes()
        cachedPassword = Array(password.utf8)
        cacheExpiry = Date().addingTimeInterval(cacheDuration)
    }

    private func getCachedPasswordString() -> String? {
        guard let bytes = cachedPassword, let expiry = cacheExpiry, Date() < expiry else {
            clearPasswordBytes()
            return nil
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private func clearPasswordBytes() {
        if var bytes = cachedPassword {
            for i in bytes.indices { bytes[i] = 0 }
        }
        cachedPassword = nil
        cacheExpiry = nil
    }

    // MARK: - Password request (asks iOS client)

    func requestPassword(reason: String? = nil) async -> String? {
        if let cached = getCachedPasswordString() {
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

        cachePassword(password)
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
        clearPasswordBytes()
    }

    // MARK: - Command rewriting (uses stdin pipe instead of temp files)

    /// Rewrites a command that needs sudo to pipe password via stdin.
    /// Uses `sudo -S` which reads from stdin — no temp files, no env vars.
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
                return sudoStdinWrapper(password: password, command: trimmed)
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
        return sudoStdinWrapper(password: password, command: command)
    }

    /// Wraps a command so sudo reads the password via stdin pipe.
    /// Uses printf (not echo) to avoid escape sequence interpretation.
    /// Password is single-quote escaped to prevent shell injection.
    private func sudoStdinWrapper(password: String, command: String) -> String {
        // Escape single quotes for safe embedding in shell single-quoted string
        let escaped = password.replacingOccurrences(of: "'", with: "'\\''")
        // Replace bare "sudo " with "sudo -S " so it reads from stdin
        var cmd = command
        cmd = cmd.replacingOccurrences(of: "sudo ", with: "sudo -S ")
        // Pipe password via printf (safer than echo — no escape sequence interpretation)
        return "printf '%s\\n' '\(escaped)' | \(cmd)"
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
    /// The command must match the whitelist of allowed sudo commands.
    func runWithSudo(_ command: String, reason: String? = nil) async throws -> (output: String, exitCode: Int32) {
        guard isCommandAllowed(command) else {
            throw SudoError.commandNotAllowed
        }

        guard let password = await requestPassword(reason: reason) else {
            throw SudoError.cancelled
        }

        // Authenticate sudo via stdin pipe (safe — no shell interpolation, no temp files)
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

        // Parse command into executable + arguments (no shell interpretation)
        let commandParts = parseCommandParts(command)
        guard let executable = commandParts.first else {
            throw SudoError.commandNotAllowed
        }

        // Resolve executable to full path so sudo can find it without a shell
        let resolvedExecutable = resolveExecutablePath(executable)

        // Run with sudo using array arguments — no shell, no injection possible
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [resolvedExecutable] + Array(commandParts.dropFirst())
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
        case commandNotAllowed

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Password entry was cancelled"
            case .authenticationFailed: return "Authentication failed — wrong password"
            case .commandNotAllowed: return "Command not allowed for remote sudo execution"
            }
        }
    }
}
