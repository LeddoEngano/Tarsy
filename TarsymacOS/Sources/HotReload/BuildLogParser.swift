import Foundation

struct CompileCommand: Sendable {
    let swiftcPath: String
    let arguments: [String]
    let workingDirectory: String
    let sourceFile: String
}

actor BuildLogParser {

    /// Cached compile commands keyed by source file path
    private var cache: [String: CompileCommand] = [:]

    // MARK: - Parse from xcodebuild output (preferred)

    /// Parse compile commands from live xcodebuild output.
    /// Called line-by-line during the initial build when EMIT_FRONTEND_COMMAND_LINES=YES.
    func parseBuildOutputLine(_ line: String) {
        // Look for swift-frontend invocations with -primary-file
        // Format: <path>/swift-frontend -frontend -c -primary-file <source> ...
        guard line.contains("swift-frontend") || line.contains("swiftc") else { return }
        guard line.contains("-primary-file") || line.contains("-c") else { return }

        let tokens = tokenize(line)
        guard tokens.count > 3 else { return }

        // Find -primary-file argument
        var primaryFile: String?
        var swiftcPath: String?
        var args: [String] = []

        for i in 0..<tokens.count {
            let token = tokens[i]

            // First token that ends with swift-frontend or swiftc is the compiler
            if swiftcPath == nil && (token.hasSuffix("swift-frontend") || token.hasSuffix("swiftc")) {
                swiftcPath = token
                continue
            }

            if token == "-primary-file" && i + 1 < tokens.count {
                primaryFile = tokens[i + 1]
                // Don't add -primary-file to args, we'll add it back during recompile
                continue
            }

            // Skip -o and its argument (we'll provide our own)
            if token == "-o" && i + 1 < tokens.count {
                continue
            }
            // Skip the output path (follows -o)
            if i > 0 && tokens[i - 1] == "-o" {
                continue
            }

            args.append(token)
        }

        guard let file = primaryFile, let compiler = swiftcPath else { return }

        // Resolve to absolute path
        let resolvedFile = (file as NSString).expandingTildeInPath
        let absoluteFile: String
        if resolvedFile.hasPrefix("/") {
            absoluteFile = resolvedFile
        } else {
            absoluteFile = resolvedFile
        }

        let cmd = CompileCommand(
            swiftcPath: compiler,
            arguments: args,
            workingDirectory: "",
            sourceFile: absoluteFile
        )
        cache[absoluteFile] = cmd
    }

    // MARK: - Parse from xcactivitylog (fallback)

    /// Parse compile commands from DerivedData build logs.
    /// Falls back to this when EMIT_FRONTEND_COMMAND_LINES output isn't available.
    func parseFromDerivedData(derivedDataPath: String, forFile sourceFile: String) async -> CompileCommand? {
        // Check cache first
        if let cached = cache[sourceFile] { return cached }

        let logsDir = derivedDataPath + "/Logs/Build"
        let fm = FileManager.default

        guard let logFiles = try? fm.contentsOfDirectory(atPath: logsDir) else { return nil }

        // Sort by modification date (most recent first)
        let sortedLogs = logFiles
            .filter { $0.hasSuffix(".xcactivitylog") }
            .compactMap { file -> (String, Date)? in
                let path = logsDir + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let date = attrs[.modificationDate] as? Date else { return nil }
                return (path, date)
            }
            .sorted { $0.1 > $1.1 }

        let sourceFileName = (sourceFile as NSString).lastPathComponent

        for (logPath, _) in sortedLogs.prefix(3) {
            if let cmd = await parseActivityLog(logPath, sourceFileName: sourceFileName, fullPath: sourceFile) {
                cache[sourceFile] = cmd
                return cmd
            }
        }

        return nil
    }

    // MARK: - Lookup

    func commandForFile(_ file: String) -> CompileCommand? {
        return cache[file]
    }

    func clearCache() {
        cache.removeAll()
    }

    var cachedFileCount: Int { cache.count }

    // MARK: - Private

    private func parseActivityLog(_ logPath: String, sourceFileName: String, fullPath: String) async -> CompileCommand? {
        // xcactivitylog files are gzip-compressed
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", logPath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let content = String(data: data, encoding: .utf8) else { return nil }

        // Search for compile command containing our source file
        // Build logs use \r as record separator
        let records = content.components(separatedBy: "\r")

        for record in records {
            guard record.contains("swift-frontend") || record.contains("swiftc"),
                  record.contains(sourceFileName),
                  record.contains("-primary-file") || record.contains("-c") else { continue }

            // Found a matching compile command
            let tokens = tokenize(record)
            var swiftcPath: String?
            var args: [String] = []
            var primaryFile: String?

            for i in 0..<tokens.count {
                let token = tokens[i]

                if swiftcPath == nil && (token.hasSuffix("swift-frontend") || token.hasSuffix("swiftc")) {
                    swiftcPath = token
                    continue
                }

                if token == "-primary-file" && i + 1 < tokens.count {
                    primaryFile = tokens[i + 1]
                    continue
                }

                if token == "-o" && i + 1 < tokens.count { continue }
                if i > 0 && tokens[i - 1] == "-o" { continue }

                args.append(token)
            }

            guard let compiler = swiftcPath, primaryFile != nil else { continue }

            return CompileCommand(
                swiftcPath: compiler,
                arguments: args,
                workingDirectory: "",
                sourceFile: fullPath
            )
        }

        return nil
    }

    /// Tokenize a command line, respecting quoted strings
    private func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false

        for char in line {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }

            if char == "\\" && !inSingleQuote {
                escaped = true
                continue
            }

            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }

            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }

            if char == " " && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(char)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}
