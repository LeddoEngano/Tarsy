import Foundation

struct ScannedRepo: Codable, Sendable {
    let name: String
    let path: String
    let remoteUrl: String?
    let currentBranch: String?
    let stack: String?
}

class RepoScanner {
    // Directories to scan for git repos (1 level deep)
    private let scanDirs: [String] = [
        "~/Desktop",
        "~/Documents",
        "~/Projects",
        "~/Developer",
        "~/Code",
        "~/repos",
        "~/dev",
        "~/work",
        "~/src",
        "~"
    ]

    /// Max time for the entire scan operation
    private let globalTimeoutSeconds: UInt64 = 20

    /// Max time per individual git command
    private let gitTimeoutSeconds: Int = 2

    /// Whether git is installed and usable on this machine
    private(set) lazy var gitAvailable: Bool = {
        // On macOS, /usr/bin/git exists as a stub even without CLT installed.
        // Running it would trigger a GUI prompt — check for real git first.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--version"]
        process.environment = ["GIT_TERMINAL_PROMPT": "0"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        // Prevent the CLT install dialog
        process.environment?["DEVELOPER_DIR"] = "/nonexistent"

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }()

    func scan() async -> [ScannedRepo] {
        // Use a global timeout to guarantee we always return
        let result = await withTaskGroup(of: [ScannedRepo].self) { group in
            group.addTask {
                await self.performScan()
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: self.globalTimeoutSeconds * 1_000_000_000)
                return [] // sentinel for timeout
            }

            // Return whichever finishes first
            if let first = await group.next() {
                group.cancelAll()
                return first
            }
            return []
        }

        return result
    }

    private func performScan() async -> [ScannedRepo] {
        let fm = FileManager.default

        // Phase 1: Discover all git repo paths (fast, no git commands)
        var repoPaths: [(name: String, path: String)] = []

        for dir in scanDirs {
            let expandedDir = (dir as NSString).expandingTildeInPath

            guard fm.fileExists(atPath: expandedDir) else { continue }
            guard let contents = try? fm.contentsOfDirectory(atPath: expandedDir) else { continue }

            for item in contents {
                // Skip hidden dirs and common non-project dirs
                if item.hasPrefix(".") { continue }
                let skipList: Set<String> = ["node_modules", "Library", ".Trash", "Applications",
                                              "Movies", "Music", "Pictures", "Public",
                                              "Downloads", "Caches"]
                if skipList.contains(item) { continue }

                let itemPath = "\(expandedDir)/\(item)"
                let gitPath = "\(itemPath)/.git"

                guard fm.fileExists(atPath: gitPath) else { continue }

                repoPaths.append((name: item, path: itemPath))
            }
        }

        // Deduplicate by path
        var seen = Set<String>()
        repoPaths = repoPaths.filter { seen.insert($0.path).inserted }

        // Phase 2: Enrich repos concurrently with git metadata
        let repos = await withTaskGroup(of: ScannedRepo?.self, returning: [ScannedRepo].self) { group in
            for repo in repoPaths {
                group.addTask {
                    // Check cancellation (from global timeout)
                    guard !Task.isCancelled else { return nil }

                    let remoteUrl = self.gitAvailable ? self.runGit(["config", "--get", "remote.origin.url"], at: repo.path) : nil
                    let branch = self.gitAvailable ? self.runGit(["rev-parse", "--abbrev-ref", "HEAD"], at: repo.path) : nil
                    let stack = self.detectStack(at: repo.path)

                    return ScannedRepo(
                        name: repo.name,
                        path: repo.path,
                        remoteUrl: remoteUrl,
                        currentBranch: branch,
                        stack: stack
                    )
                }
            }

            var results: [ScannedRepo] = []
            for await repo in group {
                if let repo = repo {
                    results.append(repo)
                }
            }
            return results
        }

        return repos.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func detectStack(at path: String) -> String? {
        let fm = FileManager.default

        if fm.fileExists(atPath: "\(path)/app.json") || fm.fileExists(atPath: "\(path)/ios") {
            return "mobile"
        }
        if fm.fileExists(atPath: "\(path)/next.config.js") ||
           fm.fileExists(atPath: "\(path)/next.config.mjs") ||
           fm.fileExists(atPath: "\(path)/next.config.ts") ||
           fm.fileExists(atPath: "\(path)/vite.config.ts") ||
           fm.fileExists(atPath: "\(path)/vite.config.js") {
            return "web"
        }
        if fm.fileExists(atPath: "\(path)/package.json") {
            return "web"
        }
        if fm.fileExists(atPath: "\(path)/Package.swift") {
            return fm.fileExists(atPath: "\(path)/Sources") ? "backend" : "mobile"
        }
        if fm.fileExists(atPath: "\(path)/requirements.txt") ||
           fm.fileExists(atPath: "\(path)/go.mod") ||
           fm.fileExists(atPath: "\(path)/Cargo.toml") {
            return "backend"
        }
        return nil
    }

    private func runGit(_ args: [String], at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.environment = ["GIT_TERMINAL_PROMPT": "0"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()

            // Timeout: kill git if it takes too long
            let deadline = DispatchTime.now() + .seconds(gitTimeoutSeconds)
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning {
                    process.terminate()
                }
            }

            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == true ? nil : output
        } catch {
            return nil
        }
    }
}
