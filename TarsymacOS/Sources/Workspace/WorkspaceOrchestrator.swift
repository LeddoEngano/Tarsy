import Foundation
import TarsyShared

actor WorkspaceOrchestrator {
    private let terminalManager: TerminalSessionManager

    init(terminalManager: TerminalSessionManager) {
        self.terminalManager = terminalManager
    }

    struct SetupResult: Sendable {
        let sessionId: String
        let detectedStack: String?
        let detectedDevCommand: String?
    }

    // MARK: - Clone & Setup

    func setupWorkspace(repoUrl: String?, localPath: String, name: String) async throws -> SetupResult {
        let expandedPath = (localPath as NSString).expandingTildeInPath
        let fm = FileManager.default

        // Create directory if needed
        if !fm.fileExists(atPath: expandedPath) {
            try fm.createDirectory(atPath: expandedPath, withIntermediateDirectories: true)
        }

        // Clone if repo URL provided and directory is empty
        if let url = repoUrl, !url.isEmpty {
            let contents = (try? fm.contentsOfDirectory(atPath: expandedPath)) ?? []
            if contents.isEmpty || contents == [".DS_Store"] {
                try await runProcess("/usr/bin/git", arguments: ["clone", url, expandedPath])
            }
        }

        // Detect stack and install deps
        let stack = detectStack(at: expandedPath)
        let devCommand = detectDevCommand(at: expandedPath, stack: stack)

        if let installCmd = detectInstallCommand(at: expandedPath, stack: stack) {
            let parts = installCmd.components(separatedBy: " ").filter { !$0.isEmpty }
            guard let executable = parts.first else { return SetupResult(sessionId: "", detectedStack: stack, detectedDevCommand: devCommand) }
            let execPath = resolveExecutable(executable)
            let args = Array(parts.dropFirst())
            try await runProcess(execPath, arguments: args, workingDirectory: expandedPath)
        }

        // Create terminal session
        let sessionId = try await terminalManager.createSession(workingDirectory: expandedPath)

        return SetupResult(
            sessionId: sessionId,
            detectedStack: stack,
            detectedDevCommand: devCommand
        )
    }

    // MARK: - Cold Start

    func coldStart(localPath: String, devServerCommand: String?) async throws -> String {
        let expandedPath = (localPath as NSString).expandingTildeInPath
        let sessionId = try await terminalManager.createSession(workingDirectory: expandedPath)

        if let cmd = devServerCommand ?? detectDevCommand(at: expandedPath, stack: detectStack(at: expandedPath)) {
            await terminalManager.sendInput(cmd, to: sessionId)
        }

        return sessionId
    }

    // MARK: - Detection
    //
    // Stack and dev-command detection is delegated to `RepoAnalyzer` so that
    // cold-start, workspace setup, and the iOS repo-analyze flow all return
    // the exact same answer. When adding a new framework/stack, update
    // RepoAnalyzer — NOT this file.

    private func detectStack(at path: String) -> String? {
        return RepoAnalyzer().analyze(at: path).stack
    }

    private func detectDevCommand(at path: String, stack: String?) -> String? {
        return RepoAnalyzer().analyze(at: path).suggestedCommand
    }

    private func detectInstallCommand(at path: String, stack: String?) -> String? {
        let fm = FileManager.default

        if fm.fileExists(atPath: "\(path)/package-lock.json") { return "npm install" }
        if fm.fileExists(atPath: "\(path)/yarn.lock") { return "yarn install" }
        if fm.fileExists(atPath: "\(path)/pnpm-lock.yaml") { return "pnpm install" }
        if fm.fileExists(atPath: "\(path)/bun.lockb") || fm.fileExists(atPath: "\(path)/bun.lock") { return "bun install" }
        if fm.fileExists(atPath: "\(path)/requirements.txt") { return "pip install -r requirements.txt" }
        if fm.fileExists(atPath: "\(path)/Gemfile") { return "bundle install" }
        if fm.fileExists(atPath: "\(path)/pubspec.yaml") { return "flutter pub get" }
        if fm.fileExists(atPath: "\(path)/Cargo.toml") { return "cargo fetch" }
        if fm.fileExists(atPath: "\(path)/go.mod") { return "go mod download" }

        return nil
    }

    // MARK: - Process Execution (safe — no shell interpolation)

    private func runProcess(_ executablePath: String, arguments: [String], workingDirectory: String? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "Unknown error"
            let description = ([executablePath] + arguments).joined(separator: " ")
            throw WorkspaceError.commandFailed(description, output)
        }
    }

    private func resolveExecutable(_ name: String) -> String {
        let searchPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/opt/homebrew/bin/\(name)"
    }

    enum WorkspaceError: LocalizedError {
        case commandFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let cmd, let output):
                return "Command '\(cmd)' failed: \(output)"
            }
        }
    }
}
