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
        // Per-workspace DerivedData. Sharing one directory across all
        // workspaces caused .app bundles from previous builds (e.g. Tarsy
        // itself) to collide with the current build's output, so
        // `findBuiltApp` could return the wrong .app and we'd install/launch
        // the wrong bundleId on the simulator. A stable hash of the
        // projectPath isolates each workspace.
        let workspaceHash = String(abs(projectPath.hashValue), radix: 16)
        let derivedDataPath = NSTemporaryDirectory() + "TarsyHotReload-DerivedData-\(workspaceHash)"

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

        // Find the built .app — prefer the one matching the scheme name to
        // protect against directories that legitimately contain multiple
        // .app bundles (multi-target workspaces, prior partial builds).
        guard let appPath = findBuiltApp(derivedDataPath: derivedDataPath, configuration: configuration, scheme: scheme) else {
            // Surface the actual buildDir contents so the user can see what
            // was produced (or whether the dir is empty / missing entirely).
            let buildDir = derivedDataPath + "/Build/Products/\(configuration)-iphonesimulator"
            let fm = FileManager.default
            let contents = (try? fm.contentsOfDirectory(atPath: buildDir)) ?? []
            let listing = contents.isEmpty ? "<empty>" : contents.joined(separator: ", ")
            throw BuildError.buildFailed("Build succeeded but no .app was produced.\n  Looked in: \(buildDir)\n  Found: \(listing)\n  Scheme '\(scheme)' may not produce an app target — try a different scheme.")
        }

        guard let bundleId = extractBundleId(appPath: appPath) else {
            throw BuildError.buildFailed("Found app at \(appPath) but could not read CFBundleIdentifier from its Info.plist")
        }

        return BuildResult(
            appBundlePath: appPath,
            appBundleId: bundleId,
            derivedDataPath: derivedDataPath,
            success: true
        )
    }

    // MARK: - Discover Schemes

    static func listSchemes(projectPath: String) async -> [String] {
        // Prefer listing from a .xcodeproj when both .xcodeproj and
        // .xcworkspace exist. CocoaPods workspaces include every Pod's
        // scheme in `xcodebuild -list -workspace` output (often hundreds —
        // EXConstants, React-cxxreact, RCT*, etc.) and the first scheme
        // alphabetically is almost never the user's app. Listing from the
        // .xcodeproj directly returns only the user's targets and skips
        // the Pod noise entirely.
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: projectPath)) ?? []
        let xcodeproj = contents.first(where: { $0.hasSuffix(".xcodeproj") }).map { projectPath + "/" + $0 }
        let xcworkspace = contents.first(where: { $0.hasSuffix(".xcworkspace") && !$0.contains("project.xcworkspace") }).map { projectPath + "/" + $0 }

        if let xcodeproj {
            let schemes = await rawSchemes(target: xcodeproj, isWorkspace: false, cwd: projectPath)
            let filtered = filterAppSchemes(schemes)
            if !filtered.isEmpty { return filtered }
        }
        if let xcworkspace {
            let schemes = await rawSchemes(target: xcworkspace, isWorkspace: true, cwd: projectPath)
            let filtered = filterAppSchemes(schemes)
            if !filtered.isEmpty { return filtered }
            // If filtering wiped everything, return the raw list — better
            // to give the user something than nothing.
            return schemes
        }
        return []
    }

    /// Drop schemes that obviously don't produce an app: test bundles and
    /// CocoaPods/SwiftPM dependency schemes that leak through when a
    /// .xcodeproj couldn't be used to scope the listing.
    private static func filterAppSchemes(_ schemes: [String]) -> [String] {
        // Common CocoaPods / React Native dependency scheme prefixes. Not
        // exhaustive — additions are cheap and the list is consulted only
        // as a last-resort filter when the user's project isn't available
        // to query directly.
        let depPrefixes = [
            "Pods-", "EX", "RCT", "React-", "React_", "RN", "FB", "FBLazyVector",
            "RealmSwift", "Boost", "boost", "Folly", "Yoga", "glog",
            "DoubleConversion", "RCTRequired", "RCTTypeSafety",
            "Hermes", "hermes", "Flipper", "flipper",
        ]
        return schemes.filter { name in
            // Test bundles never produce an app.
            if name.hasSuffix("Tests") || name.hasSuffix("UITests") { return false }
            // CocoaPods / RN dependency schemes.
            for p in depPrefixes where name.hasPrefix(p) { return false }
            return true
        }
    }

    private static func rawSchemes(target: String, isWorkspace: Bool, cwd: String) async -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcodebuild", "-list",
            isWorkspace ? "-workspace" : "-project", target,
            "-json"
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

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

    private func findBuiltApp(derivedDataPath: String, configuration: String, scheme: String) -> String? {
        let buildDir = derivedDataPath + "/Build/Products/\(configuration)-iphonesimulator"
        let fm = FileManager.default

        // First-level lookup at the standard location.
        if let contents = try? fm.contentsOfDirectory(atPath: buildDir) {
            // Prefer `<scheme>.app` if present — Xcode names the product after
            // the scheme's target by default, so this lands on the right bundle
            // even when the directory contains leftovers from a prior build.
            let schemeAppName = "\(scheme).app"
            if contents.contains(schemeAppName) {
                return buildDir + "/" + schemeAppName
            }
            // Fall back to the first .app — better than nothing if the scheme
            // produces a product whose name diverges from the scheme name
            // (Filter out .app subfolders that are clearly extensions, watch
            // apps, or test bundles bundled inside the main app's Plugins/).
            if let app = contents.first(where: { $0.hasSuffix(".app") }) {
                return buildDir + "/" + app
            }
        }

        // Recursive fallback: some workspace setups (CocoaPods, custom
        // BUILT_PRODUCTS_DIR, multi-platform projects) produce the .app at
        // a nested path. Walk the entire DerivedData/Build tree as a last
        // resort. Restricted to `Build/` so we don't pick up Index/Indexed*
        // shadow builds Apple stores at the same level.
        let buildRoot = derivedDataPath + "/Build"
        guard let enumerator = fm.enumerator(atPath: buildRoot) else { return nil }
        var schemeMatch: String? = nil
        var firstMatch: String? = nil
        let schemeAppSuffix = "/\(scheme).app"
        while let rel = enumerator.nextObject() as? String {
            // Only top-level .app bundles — not nested ones inside Plugins/,
            // Frameworks/, etc.
            guard rel.hasSuffix(".app"),
                  !rel.contains(".app/") else { continue }
            let abs = buildRoot + "/" + rel
            if rel.hasSuffix(schemeAppSuffix) || rel == "\(scheme).app" {
                schemeMatch = abs
                break
            }
            if firstMatch == nil { firstMatch = abs }
        }
        return schemeMatch ?? firstMatch
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
