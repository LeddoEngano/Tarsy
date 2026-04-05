import Foundation
import os
import TarsyShared

struct AgentDetector {

    private static let log = Logger(subsystem: "com.tarsy.macos", category: "AgentDetector")

    /// Timeout for subprocess calls (seconds).
    private static let processTimeout: TimeInterval = 5

    /// Returns the real home directory, stripping the sandbox container path if present.
    private static func computeRealHome() -> String {
        let raw = FileManager.default.homeDirectoryForCurrentUser.path
        if let range = raw.range(of: "/Library/Containers/com.tarsy.macos/Data") {
            return String(raw[raw.startIndex..<range.lowerBound])
        }
        return raw
    }

    static var realHome: String { computeRealHome() }

    /// Enriched PATH for subprocess execution, computed once.
    /// Menu bar apps launched at login inherit a minimal launchd PATH,
    /// so we prepend common tool locations to ensure `which` can find binaries.
    private static let enrichedPATH: String = {
        let home = computeRealHome()

        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.claude/bin",
            "\(home)/.amp/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.volta/bin",
            "\(home)/.npm-global/bin",
            "\(home)/go/bin",
            "\(home)/.local/share/pnpm",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/.pyenv/shims",
        ]

        // Add nvm/fnm version manager bins
        var vmPaths: [String] = []
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                vmPaths.append("\(nvmDir)/\(v)/bin")
            }
        }
        let fnmDir = "\(home)/.local/share/fnm/node-versions"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: fnmDir) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                vmPaths.append("\(fnmDir)/\(v)/installation/bin")
            }
        }

        let existing = (extraPaths + vmPaths).filter { FileManager.default.fileExists(atPath: $0) }
        let systemPATH = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return (existing + [systemPATH]).joined(separator: ":")
    }()

    /// Cached version manager bin paths, computed once at first access.
    private static let cachedVersionManagerBinPaths: [String] = {
        let home = computeRealHome()

        var paths: [String] = []

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

        // pyenv: ~/.pyenv/shims
        let pyenvShims = "\(home)/.pyenv/shims"
        if FileManager.default.fileExists(atPath: pyenvShims) {
            paths.append(pyenvShims)
        }

        // conda: ~/miniconda3/bin and ~/anaconda3/bin
        for condaDir in ["miniconda3", "anaconda3", "miniforge3"] {
            let condaBin = "\(home)/\(condaDir)/bin"
            if FileManager.default.fileExists(atPath: condaBin) {
                paths.append(condaBin)
            }
        }

        return paths
    }()

    // MARK: - Detection

    /// Detects which AI coding agents are installed on this Mac.
    static func detectInstalledAgents() -> [AIEngineType] {
        log.info("Starting agent detection...")
        var installed: [AIEngineType] = []
        for engineType in AIEngineType.allCases {
            if let path = agentPath(for: engineType) {
                installed.append(engineType)
                log.info("[ok] \(engineType.rawValue) found at \(path)")
            } else if engineType != .custom {
                log.info("[--] \(engineType.rawValue) not found")
            }
        }
        log.info("Detection complete: \(installed.map(\.rawValue))")
        return installed
    }

    /// Returns the first valid path for the given engine type, or nil if not installed.
    static func agentPath(for engineType: AIEngineType) -> String? {
        // 1. Check known candidate paths first (fast, no subprocess)
        let candidates = candidatePaths(for: engineType)
        for path in candidates {
            if isValidExecutable(atPath: path) {
                // For copilot, we found `gh` — but must verify the copilot extension is installed
                if engineType == .copilot && !isCopilotExtensionInstalled(ghPath: path) {
                    continue
                }
                return path
            }
        }
        // 2. Fallback: ask the user's login shell to resolve the binary via PATH
        if let binaryName = engineType.defaultCommand ?? engineType.primaryBinaryName {
            if let resolved = resolveViaShell(binaryName), isValidExecutable(atPath: resolved) {
                if engineType == .copilot && !isCopilotExtensionInstalled(ghPath: resolved) {
                    return nil
                }
                return resolved
            }
        }
        return nil
    }

    /// Validates that a path is a real, executable file (resolving symlinks).
    private static func isValidExecutable(atPath path: String) -> Bool {
        let fm = FileManager.default
        // Resolve symlinks to detect broken ones
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard fm.fileExists(atPath: resolved) else {
            return false
        }
        return fm.isExecutableFile(atPath: resolved)
    }

    /// Checks if the `gh copilot` extension is installed by running `gh extension list`.
    private static func isCopilotExtensionInstalled(ghPath: String) -> Bool {
        guard let (output, status) = runProcess(
            executablePath: ghPath,
            arguments: ["extension", "list"]
        ) else {
            log.warning("gh extension list timed out or failed to launch")
            return false
        }
        guard status == 0 else { return false }
        return output.contains("copilot")
    }

    // MARK: - Version

    /// Runs `<agent> --version` and returns the trimmed output, or nil on failure.
    static func agentVersion(for engineType: AIEngineType) -> String? {
        guard let path = agentPath(for: engineType) else { return nil }
        guard let (output, status) = runProcess(
            executablePath: path,
            arguments: ["--version"]
        ) else {
            log.warning("\(engineType.rawValue) --version timed out")
            return nil
        }
        guard status == 0, !output.isEmpty else { return nil }
        return output
    }

    // MARK: - Subprocess Execution

    /// Runs a process with a timeout. Returns (trimmed stdout, exit status) or nil on timeout/launch failure.
    private static func runProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval = processTimeout
    ) -> (String, Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        // Fix HOME and PATH for hardened runtime / login item environment
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = realHome
        env["PATH"] = enrichedPATH
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.error("Failed to launch \(executablePath): \(error.localizedDescription)")
            return nil
        }

        // Read stdout and wait for exit concurrently to avoid pipe buffer deadlocks.
        // If the pipe buffer fills (64KB), the process blocks on write and waitUntilExit
        // never returns. Reading concurrently drains the buffer so the process can finish.
        let completed = DispatchSemaphore(value: 0)
        var timedOut = false
        var outputData = Data()

        DispatchQueue.global().async {
            outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            completed.signal()
        }

        if completed.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            log.warning("Process \(executablePath) timed out after \(timeout)s")
            process.terminate()
            // Give it a moment to clean up, then force kill
            if completed.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        if timedOut { return nil }

        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (output, process.terminationStatus)
    }

    // MARK: - Shell Fallback

    /// Uses the user's login shell to resolve a binary name via `which`.
    /// This catches any custom PATH setup (version managers, custom dirs, etc.)
    private static func resolveViaShell(_ binaryName: String) -> String? {
        // Validate binary name to prevent shell injection (only alphanumeric, dash, underscore)
        guard binaryName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.fileExists(atPath: shell) else {
            log.warning("Login shell not found at \(shell), falling back to /bin/zsh")
            return resolveViaShellWith(shellPath: "/bin/zsh", binaryName: binaryName)
        }
        return resolveViaShellWith(shellPath: shell, binaryName: binaryName)
    }

    private static func resolveViaShellWith(shellPath: String, binaryName: String) -> String? {
        // Use login shell (-l) to source .zprofile. The enriched PATH already covers
        // nvm/fnm/pyenv/etc., so we don't need to source .zshrc (which can print to
        // stdout via motd/fortune/neofetch and contaminate the `which` output, or check
        // for interactive mode and bail early).
        guard let (output, status) = runProcess(
            executablePath: shellPath,
            arguments: ["-l", "-c", "which \(binaryName)"]
        ) else { return nil }

        guard status == 0, !output.isEmpty else { return nil }
        return output
    }

    // MARK: - Candidate Paths

    private static func candidatePaths(for engineType: AIEngineType) -> [String] {
        let home = realHome
        let vmBins = cachedVersionManagerBinPaths

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
                "/Applications/Codex.app/Contents/Resources/codex",
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
