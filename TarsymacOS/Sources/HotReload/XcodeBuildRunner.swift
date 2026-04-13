import Foundation

struct BuildResult: Sendable {
    let appBundlePath: String
    let appBundleId: String
    let derivedDataPath: String
    let success: Bool
}

actor XcodeBuildRunner {

    // MARK: - Build

    /// Runs xcodebuild and streams progress. Returns build result.
    func build(
        projectPath: String,
        scheme: String,
        configuration: String,
        simulatorUDID: String,
        onProgress: @escaping @Sendable (String, String, Int) async -> Void  // (output, phase, percent)
    ) async throws -> BuildResult {
        let derivedDataPath = NSTemporaryDirectory() + "TarsyHotReload-DerivedData"

        // Detect project file
        let projectFile = findProjectFile(in: projectPath)
        guard let projectFile else {
            throw BuildError.noProjectFound(projectPath)
        }

        let isWorkspace = projectFile.hasSuffix(".xcworkspace")

        let args: [String] = [
            "xcodebuild", "build",
            isWorkspace ? "-workspace" : "-project", projectFile,
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", "platform=iOS Simulator,id=\(simulatorUDID)",
            "-derivedDataPath", derivedDataPath,
            "EMIT_FRONTEND_COMMAND_LINES=YES"
        ]

        // Add -quiet for less noise but keep enough for parsing
        // Don't use -quiet because we need frontend command lines

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Count files for progress estimation
        var totalFiles = 0
        var compiledFiles = 0
        var currentPhase = "preparing"

        try process.run()

        // Read output line-by-line in background
        let outputTask = Task.detached { () -> String in
            var fullOutput = ""
            let handle = outPipe.fileHandleForReading

            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                guard let text = String(data: data, encoding: .utf8) else { continue }
                fullOutput += text

                // Parse each line
                for line in text.components(separatedBy: "\n") where !line.isEmpty {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)

                    // Detect phases and filter — only forward meaningful lines
                    var phase = currentPhase
                    var shouldForward = false

                    if trimmed.hasPrefix("CompileSwift") || trimmed.hasPrefix("SwiftCompile") {
                        phase = "compiling"
                        compiledFiles += 1
                        // Extract just the filename for display
                        let parts = trimmed.components(separatedBy: " ")
                        let filename = parts.last.map { ($0 as NSString).lastPathComponent } ?? trimmed
                        shouldForward = true
                        await onProgress("Compiling \(filename)", phase, 0)
                    } else if trimmed.hasPrefix("Ld ") || trimmed.hasPrefix("Link") {
                        phase = "linking"
                        shouldForward = true
                    } else if trimmed.hasPrefix("CodeSign") || trimmed.hasPrefix("SignBinary") {
                        phase = "signing"
                        shouldForward = true
                    } else if trimmed.contains("BUILD SUCCEEDED") {
                        phase = "complete"
                        shouldForward = true
                    } else if trimmed.contains("BUILD FAILED") {
                        phase = "error"
                        shouldForward = true
                    } else if trimmed.contains("error:") || trimmed.contains("warning:") {
                        shouldForward = true
                    } else if trimmed.contains("swift-frontend") {
                        // Count but don't forward verbose compiler invocations
                        phase = "compiling"
                        compiledFiles += 1
                    }
                    currentPhase = phase

                    let percent: Int
                    switch phase {
                    case "compiling":
                        if totalFiles == 0 { totalFiles = max(compiledFiles * 2, 20) }
                        percent = min(80, compiledFiles * 80 / max(totalFiles, 1))
                    case "linking": percent = 85
                    case "signing": percent = 95
                    case "complete": percent = 100
                    default: percent = 5
                    }

                    if shouldForward {
                        await onProgress(trimmed, phase, percent)
                    }
                }
            }
            return fullOutput
        }

        _ = await outputTask.value
        process.waitUntilExit()

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errOutput = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            // Extract meaningful error from stderr
            let errorLines = errOutput.components(separatedBy: "\n")
                .filter { $0.contains("error:") }
                .prefix(5)
                .joined(separator: "\n")
            throw BuildError.buildFailed(errorLines.isEmpty ? "Build failed with exit code \(process.terminationStatus)" : errorLines)
        }

        // Find the built .app
        let appPath = findBuiltApp(derivedDataPath: derivedDataPath, configuration: configuration)
        let bundleId = extractBundleId(appPath: appPath ?? "")

        return BuildResult(
            appBundlePath: appPath ?? "",
            appBundleId: bundleId ?? "",
            derivedDataPath: derivedDataPath,
            success: true
        )
    }

    // MARK: - Discover Schemes

    static func listSchemes(projectPath: String) async -> [String] {
        let projectFile = XcodeBuildRunner.findProjectFileStatic(in: projectPath)
        guard let projectFile else { return [] }

        let isWorkspace = projectFile.hasSuffix(".xcworkspace")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcodebuild", "-list",
            isWorkspace ? "-workspace" : "-project", projectFile,
            "-json"
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        // Structure: { "project": { "schemes": [...] } } or { "workspace": { "schemes": [...] } }
        if let project = json["project"] as? [String: Any],
           let schemes = project["schemes"] as? [String] {
            return schemes
        }
        if let workspace = json["workspace"] as? [String: Any],
           let schemes = workspace["schemes"] as? [String] {
            return schemes
        }
        return []
    }

    // MARK: - Helpers

    private func findProjectFile(in path: String) -> String? {
        Self.findProjectFileStatic(in: path)
    }

    private static func findProjectFileStatic(in path: String) -> String? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return nil }

        // Prefer .xcworkspace over .xcodeproj
        if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") && !$0.contains("project.xcworkspace") }) {
            return path + "/" + workspace
        }
        if let project = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return path + "/" + project
        }
        return nil
    }

    private func findBuiltApp(derivedDataPath: String, configuration: String) -> String? {
        let buildDir = derivedDataPath + "/Build/Products/\(configuration)-iphonesimulator"
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: buildDir) else { return nil }
        if let app = contents.first(where: { $0.hasSuffix(".app") }) {
            return buildDir + "/" + app
        }
        return nil
    }

    private func extractBundleId(appPath: String) -> String? {
        let plistPath = appPath + "/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleId = plist["CFBundleIdentifier"] as? String else { return nil }
        return bundleId
    }

    enum BuildError: LocalizedError {
        case noProjectFound(String)
        case buildFailed(String)

        var errorDescription: String? {
            switch self {
            case .noProjectFound(let path): return "No .xcodeproj or .xcworkspace found in \(path)"
            case .buildFailed(let msg): return msg
            }
        }
    }
}
