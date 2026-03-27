import Foundation
import TarsyShared

struct AgentDetector {

    /// Returns the real home directory, stripping the sandbox container path if present.
    private static var realHome: String {
        FileManager.default.homeDirectoryForCurrentUser.path
            .replacingOccurrences(of: "/Library/Containers/com.tarsy.macos/Data", with: "")
    }

    // MARK: - Detection

    /// Detects which AI coding agents are installed on this Mac.
    static func detectInstalledAgents() -> [AIEngineType] {
        var installed: [AIEngineType] = []
        for engineType in AIEngineType.allCases {
            if agentPath(for: engineType) != nil {
                installed.append(engineType)
            }
        }
        return installed
    }

    /// Returns the first valid path for the given engine type, or nil if not installed.
    static func agentPath(for engineType: AIEngineType) -> String? {
        let candidates = candidatePaths(for: engineType)
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Version

    /// Runs `<agent> --version` and returns the trimmed output, or nil on failure.
    static func agentVersion(for engineType: AIEngineType) -> String? {
        guard let path = agentPath(for: engineType) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == true ? nil : output
        } catch {
            return nil
        }
    }

    // MARK: - Candidate Paths

    private static func candidatePaths(for engineType: AIEngineType) -> [String] {
        let home = realHome
        switch engineType {
        case .claude:
            return [
                "/opt/homebrew/bin/claude",
                "\(home)/.local/bin/claude",
                "/usr/local/bin/claude",
                "\(home)/.claude/bin/claude",
                "\(home)/.npm-global/bin/claude",
            ]
        case .gemini:
            return [
                "/opt/homebrew/bin/gemini",
                "\(home)/.local/bin/gemini",
                "/usr/local/bin/gemini",
                "\(home)/.npm-global/bin/gemini",
            ]
        case .codex:
            return [
                "/opt/homebrew/bin/codex",
                "\(home)/.local/bin/codex",
                "/usr/local/bin/codex",
                "\(home)/.npm-global/bin/codex",
            ]
        case .aider:
            return [
                "/opt/homebrew/bin/aider",
                "\(home)/.local/bin/aider",
                "/usr/local/bin/aider",
                "\(home)/.pyenv/shims/aider",
                "\(home)/.cargo/bin/aider",
            ]
        case .custom:
            return []
        }
    }
}
