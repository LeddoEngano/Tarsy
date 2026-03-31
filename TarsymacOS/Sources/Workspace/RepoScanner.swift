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

    func scan() async -> [ScannedRepo] {
        var repos: [ScannedRepo] = []
        let fm = FileManager.default

        for dir in scanDirs {
            let expandedDir = (dir as NSString).expandingTildeInPath

            guard fm.fileExists(atPath: expandedDir) else { continue }

            guard let contents = try? fm.contentsOfDirectory(atPath: expandedDir) else { continue }

            for item in contents {
                let itemPath = "\(expandedDir)/\(item)"
                let gitPath = "\(itemPath)/.git"

                guard fm.fileExists(atPath: gitPath) else { continue }

                // Skip hidden dirs and common non-project dirs
                if item.hasPrefix(".") || ["node_modules", "Library", ".Trash", "Applications", "Movies", "Music", "Pictures", "Public"].contains(item) {
                    continue
                }

                let remoteUrl = getRemoteUrl(at: itemPath)
                let branch = getCurrentBranch(at: itemPath)
                let stack = detectStack(at: itemPath)

                repos.append(ScannedRepo(
                    name: item,
                    path: itemPath,
                    remoteUrl: remoteUrl,
                    currentBranch: branch,
                    stack: stack
                ))
            }
        }

        // Deduplicate by path
        var seen = Set<String>()
        repos = repos.filter { seen.insert($0.path).inserted }

        // Sort by name
        repos.sort { $0.name.lowercased() < $1.name.lowercased() }

        return repos
    }

    private func getRemoteUrl(at path: String) -> String? {
        runGit(["config", "--get", "remote.origin.url"], at: path)
    }

    private func getCurrentBranch(at path: String) -> String? {
        runGit(["rev-parse", "--abbrev-ref", "HEAD"], at: path)
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
        process.environment = ["GIT_TERMINAL_PROMPT": "0"] // Prevent git from hanging on credential prompts

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()

            // Timeout: kill git if it takes more than 5 seconds
            let deadline = DispatchTime.now() + .seconds(5)
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
