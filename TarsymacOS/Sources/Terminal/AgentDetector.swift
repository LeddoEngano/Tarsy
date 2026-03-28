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
        // 1. Check known candidate paths first (fast, no subprocess)
        let candidates = candidatePaths(for: engineType)
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                // For copilot, we found `gh` — but must verify the copilot extension is installed
                if engineType == .copilot && !isCopilotExtensionInstalled(ghPath: path) {
                    continue
                }
                return path
            }
        }
        // 2. Fallback: ask the user's login shell to resolve the binary via PATH
        if let binaryName = engineType.defaultCommand ?? engineType.primaryBinaryName {
            if let resolved = resolveViaShell(binaryName), FileManager.default.isExecutableFile(atPath: resolved) {
                if engineType == .copilot && !isCopilotExtensionInstalled(ghPath: resolved) {
                    return nil
                }
                return resolved
            }
        }
        return nil
    }

    /// Checks if the `gh copilot` extension is installed by running `gh extension list`.
    private static func isCopilotExtensionInstalled(ghPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = ["extension", "list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains("copilot")
        } catch {
            return false
        }
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

    // MARK: - Shell Fallback

    /// Uses the user's login shell to resolve a binary name via `which`.
    /// This catches any custom PATH setup (version managers, custom dirs, etc.)
    private static func resolveViaShell(_ binaryName: String) -> String? {
        let process = Process()
        // Use the user's default shell for full PATH resolution
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        // -l for login (loads .zprofile/.bash_profile), -c to run command
        process.arguments = ["-l", "-c", "which \(binaryName)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (output?.isEmpty == true) ? nil : output
        } catch {
            return nil
        }
    }

    // MARK: - Version Manager Bin Paths

    /// Discovers bin directories from Node version managers, Python version managers, and other tool managers.
    private static var versionManagerBinPaths: [String] {
        let home = realHome
        var paths: [String] = []

        // --- Node version managers ---

        // nvm: ~/.nvm/versions/node/*/bin
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                paths.append("\(nvmDir)/\(v)/bin")
            }
        }

        // fnm: ~/.local/share/fnm/node-versions/*/installation/bin
        let fnmDir = "\(home)/.local/share/fnm/node-versions"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: fnmDir) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                paths.append("\(fnmDir)/\(v)/installation/bin")
            }
        }

        // Volta: ~/.volta/bin
        let voltaBin = "\(home)/.volta/bin"
        if FileManager.default.fileExists(atPath: voltaBin) {
            paths.append(voltaBin)
        }

        // asdf: ~/.asdf/shims
        let asdfShims = "\(home)/.asdf/shims"
        if FileManager.default.fileExists(atPath: asdfShims) {
            paths.append(asdfShims)
        }

        // mise (formerly rtx): ~/.local/share/mise/shims
        let miseShims = "\(home)/.local/share/mise/shims"
        if FileManager.default.fileExists(atPath: miseShims) {
            paths.append(miseShims)
        }

        // Bun: ~/.bun/bin
        let bunBin = "\(home)/.bun/bin"
        if FileManager.default.fileExists(atPath: bunBin) {
            paths.append(bunBin)
        }

        // pnpm global: ~/Library/pnpm
        let pnpmBin = "\(home)/Library/pnpm"
        if FileManager.default.fileExists(atPath: pnpmBin) {
            paths.append(pnpmBin)
        }

        // --- Python version managers (for aider) ---

        // pyenv: ~/.pyenv/shims
        let pyenvShims = "\(home)/.pyenv/shims"
        if FileManager.default.fileExists(atPath: pyenvShims) {
            paths.append(pyenvShims)
        }

        // pipx: ~/.local/bin (already a static candidate, but included for completeness)

        // uv: ~/.local/bin (same)

        // conda: ~/miniconda3/bin and ~/anaconda3/bin
        for condaDir in ["miniconda3", "anaconda3", "miniforge3"] {
            let condaBin = "\(home)/\(condaDir)/bin"
            if FileManager.default.fileExists(atPath: condaBin) {
                paths.append(condaBin)
            }
        }

        return paths
    }

    // MARK: - Candidate Paths

    private static func candidatePaths(for engineType: AIEngineType) -> [String] {
        let home = realHome
        let vmBins = versionManagerBinPaths

        switch engineType {
        case .claude:
            var paths = [
                "\(home)/.claude/bin/claude",
                "/opt/homebrew/bin/claude",
                "\(home)/.local/bin/claude",
                "/usr/local/bin/claude",
                "\(home)/.npm-global/bin/claude",
            ]
            paths.append(contentsOf: vmBins.map { "\($0)/claude" })
            return paths

        case .gemini:
            var paths = [
                "/opt/homebrew/bin/gemini",
                "\(home)/.local/bin/gemini",
                "/usr/local/bin/gemini",
                "\(home)/.npm-global/bin/gemini",
            ]
            paths.append(contentsOf: vmBins.map { "\($0)/gemini" })
            return paths

        case .codex:
            var paths = [
                "/opt/homebrew/bin/codex",
                "\(home)/.local/bin/codex",
                "/usr/local/bin/codex",
                "\(home)/.npm-global/bin/codex",
            ]
            paths.append(contentsOf: vmBins.map { "\($0)/codex" })
            return paths

        case .aider:
            var paths = [
                "/opt/homebrew/bin/aider",
                "\(home)/.local/bin/aider",
                "/usr/local/bin/aider",
                "\(home)/.cargo/bin/aider",
            ]
            paths.append(contentsOf: vmBins.map { "\($0)/aider" })
            return paths

        case .cursor:
            return [
                "/usr/local/bin/cursor",
                "/opt/homebrew/bin/cursor",
                "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
                "\(home)/.local/bin/cursor",
            ]

        case .windsurf:
            return [
                "/usr/local/bin/windsurf",
                "/opt/homebrew/bin/windsurf",
                "/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf",
                "\(home)/.local/bin/windsurf",
            ]

        case .amp:
            var paths = [
                "\(home)/.amp/bin/amp",
                "/opt/homebrew/bin/amp",
                "\(home)/.local/bin/amp",
                "/usr/local/bin/amp",
                "\(home)/.npm-global/bin/amp",
            ]
            paths.append(contentsOf: vmBins.map { "\($0)/amp" })
            return paths

        case .cline:
            var paths = [
                "/opt/homebrew/bin/cline",
                "\(home)/.local/bin/cline",
                "/usr/local/bin/cline",
                "\(home)/.npm-global/bin/cline",
            ]
            paths.append(contentsOf: vmBins.map { "\($0)/cline" })
            return paths

        case .copilot:
            var paths = [
                "/opt/homebrew/bin/gh",
                "/usr/local/bin/gh",
                "\(home)/.local/bin/gh",
            ]
            paths.append(contentsOf: vmBins.map { "\($0)/gh" })
            return paths

        case .custom:
            return []
        }
    }
}
