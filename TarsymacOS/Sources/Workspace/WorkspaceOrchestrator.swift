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
                try await runShell("git clone \(url) \(expandedPath)")
            }
        }

        // Detect stack and install deps
        let stack = detectStack(at: expandedPath)
        let devCommand = detectDevCommand(at: expandedPath, stack: stack)

        if let installCmd = detectInstallCommand(at: expandedPath, stack: stack) {
            try await runShell("cd \(expandedPath) && \(installCmd)")
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

    private func detectStack(at path: String) -> String? {
        let fm = FileManager.default

        if fm.fileExists(atPath: "\(path)/package.json") {
            // Check for mobile frameworks
            if fm.fileExists(atPath: "\(path)/ios") || fm.fileExists(atPath: "\(path)/app.json") {
                return "mobile"
            }
            // Check for Next.js, Vite, etc.
            if fm.fileExists(atPath: "\(path)/next.config.js") ||
               fm.fileExists(atPath: "\(path)/next.config.mjs") ||
               fm.fileExists(atPath: "\(path)/next.config.ts") ||
               fm.fileExists(atPath: "\(path)/vite.config.ts") ||
               fm.fileExists(atPath: "\(path)/vite.config.js") {
                return "web"
            }
            return "web"
        }

        if fm.fileExists(atPath: "\(path)/Package.swift") {
            return fm.fileExists(atPath: "\(path)/Sources") ? "backend" : "mobile"
        }

        if fm.fileExists(atPath: "\(path)/requirements.txt") || fm.fileExists(atPath: "\(path)/pyproject.toml") {
            return "backend"
        }

        if fm.fileExists(atPath: "\(path)/go.mod") {
            return "backend"
        }

        if fm.fileExists(atPath: "\(path)/Cargo.toml") {
            return "backend"
        }

        return nil
    }

    private func detectDevCommand(at path: String, stack: String?) -> String? {
        let fm = FileManager.default

        if fm.fileExists(atPath: "\(path)/package.json") {
            if let data = fm.contents(atPath: "\(path)/package.json"),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let scripts = json["scripts"] as? [String: String] {
                if scripts["dev"] != nil { return detectPackageRunner(at: path) + " run dev" }
                if scripts["start"] != nil { return detectPackageRunner(at: path) + " run start" }
            }
        }

        if fm.fileExists(atPath: "\(path)/manage.py") {
            return "python manage.py runserver"
        }

        return nil
    }

    private func detectInstallCommand(at path: String, stack: String?) -> String? {
        let fm = FileManager.default

        if fm.fileExists(atPath: "\(path)/package-lock.json") { return "npm install" }
        if fm.fileExists(atPath: "\(path)/yarn.lock") { return "yarn install" }
        if fm.fileExists(atPath: "\(path)/pnpm-lock.yaml") { return "pnpm install" }
        if fm.fileExists(atPath: "\(path)/bun.lockb") { return "bun install" }
        if fm.fileExists(atPath: "\(path)/requirements.txt") { return "pip install -r requirements.txt" }
        if fm.fileExists(atPath: "\(path)/Gemfile") { return "bundle install" }

        return nil
    }

    private func detectPackageRunner(at path: String) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(path)/bun.lockb") { return "bun" }
        if fm.fileExists(atPath: "\(path)/pnpm-lock.yaml") { return "pnpm" }
        if fm.fileExists(atPath: "\(path)/yarn.lock") { return "yarn" }
        return "npm"
    }

    // MARK: - Shell

    private func runShell(_ command: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw WorkspaceError.commandFailed(command, output)
        }
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
