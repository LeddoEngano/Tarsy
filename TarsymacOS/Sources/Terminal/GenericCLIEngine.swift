import Foundation
import TarsyShared

/// Runs CLI coding agents. Uses headless mode (-p/--prompt) for TUI-based CLIs (Gemini, etc.)
/// and PTY interactive mode for line-based CLIs (Aider, etc.).
actor GenericCLIEngine: AIEngine {
    let id: String
    let engineType: AIEngineType
    let workspacePath: String
    let command: String
    let apiKey: String?
    let permissionMode: AgentPermissionConfig.PermissionMode
    private var isRunning = false

    // Headless mode state
    private var currentProcess: Process?

    private var onOutput: (@Sendable (String) -> Void)?
    private var onComplete: (@Sendable (String) -> Void)?
    private var onAskUser: (@Sendable (String, [String]) -> Void)?

    init(id: String, engineType: AIEngineType, workspacePath: String, command: String? = nil, apiKey: String? = nil, permissionMode: AgentPermissionConfig.PermissionMode = .dangerous) {
        self.id = id
        self.engineType = engineType
        self.workspacePath = workspacePath
        self.command = command ?? engineType.defaultCommand ?? "echo"
        self.apiKey = apiKey
        self.permissionMode = permissionMode
    }

    func setHandlers(
        onOutput: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String) -> Void
    ) {
        self.onOutput = onOutput
        self.onComplete = onComplete
    }

    func setAskUserHandler(_ handler: @escaping @Sendable (String, [String]) -> Void) {
        self.onAskUser = handler
    }

    func start() throws {
        isRunning = true
    }

    func sendMessage(_ message: String) {
        guard isRunning else { return }

        // Kill any previous in-flight request
        currentProcess?.terminate()
        currentProcess = nil

        let cliPath = findCLI()
        let expandedPath = (workspacePath as NSString).expandingTildeInPath
        let args = argsForEngine(message: message)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: expandedPath)
        proc.environment = buildEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        let onOutput = self.onOutput

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let cleaned = GenericCLIEngine.stripAnsi(text)
            if !cleaned.isEmpty {
                onOutput?(cleaned)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let cleaned = GenericCLIEngine.stripAnsi(text)
            let lower = cleaned.lowercased()
            let isNoise = lower.contains("cached credentials") ||
                          lower.contains("loaded cached") ||
                          lower.contains("warning:") ||
                          lower.contains("256-color") ||
                          cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !isNoise {
                onOutput?(cleaned)
            }
        }

        let onComplete = self.onComplete
        proc.terminationHandler = { _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            onComplete?("")
        }

        do {
            try proc.run()
            currentProcess = proc
        } catch {
            onOutput?("Error: \(error.localizedDescription)\n")
        }
    }

    func respondToQuestion(_ answer: String) {
        // In headless mode, questions are handled by sending a new message
        sendMessage(answer)
    }

    func terminate() {
        isRunning = false
        currentProcess?.terminate()
        currentProcess = nil
        onComplete?("Session ended")
    }

    // MARK: - Private

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
        let home = realHome.isEmpty ? (env["HOME"] ?? NSHomeDirectory()) : realHome
        env["HOME"] = home

        var extraPaths: [String] = []
        let candidates = [
            "/opt/homebrew/bin",
            "\(home)/.local/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims",
        ]
        for p in candidates where FileManager.default.fileExists(atPath: p) {
            extraPaths.append(p)
        }
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                let binPath = "\(nvmDir)/\(v)/bin"
                if FileManager.default.fileExists(atPath: binPath) {
                    extraPaths.append(binPath)
                }
            }
        }
        let fnmDir = "\(home)/.local/share/fnm/node-versions"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: fnmDir) {
            for v in versions {
                let binPath = "\(fnmDir)/\(v)/installation/bin"
                if FileManager.default.fileExists(atPath: binPath) {
                    extraPaths.append(binPath)
                }
            }
        }
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")

        if let key = apiKey, let envVar = engineType.envKeyName {
            env[envVar] = key
        }
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"

        return env
    }

    /// Build CLI arguments. For TUI-based CLIs, uses headless/prompt flags.
    private func argsForEngine(message: String) -> [String] {
        switch engineType {
        case .gemini:
            var args = ["-p", message]
            if permissionMode == .dangerous {
                args.append("--yolo")
            }
            return args
        case .codex:
            var args = ["-p", message]
            if permissionMode == .dangerous {
                args.append(contentsOf: ["--approval-mode", "full-auto"])
            } else {
                args.append(contentsOf: ["--approval-mode", "suggest"])
            }
            return args
        case .aider:
            var args = ["--message", message]
            if permissionMode != .dangerous {
                args.append(contentsOf: ["--no-auto-commits", "--no-git"])
            }
            return args
        case .cursor:
            return [message]
        case .windsurf:
            return [message]
        case .amp:
            return ["--prompt", message]
        case .cline:
            return ["--prompt", message]
        case .copilot:
            return ["copilot", message]
        case .custom, .claude:
            return [message]
        }
    }

    /// Strips ANSI escape sequences from output.
    nonisolated static func stripAnsi(_ input: String) -> String {
        var result = input
        let esc = "\u{1b}"

        // Strip CSI sequences
        result = result.replacingOccurrences(
            of: "\(esc)\\[[0-9;?]*[A-Za-z@-~]",
            with: "",
            options: .regularExpression
        )
        // Strip OSC sequences
        result = result.replacingOccurrences(
            of: "\(esc)\\][^\u{07}\(esc)]*(?:\u{07}|\(esc)\\\\)",
            with: "",
            options: .regularExpression
        )
        // Strip remaining ESC
        result = result.replacingOccurrences(of: esc, with: "")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findCLI() -> String {
        if let path = AgentDetector.agentPath(for: engineType) {
            return path
        }
        return "/usr/bin/env"
    }
}
