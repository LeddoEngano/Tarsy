import Foundation
import TarsyShared

struct RepoSubProject: Codable, Sendable {
    let name: String          // directory basename, e.g. "web"
    let path: String          // repo-relative path, e.g. "apps/web"
    let stack: String?        // web / mobile / backend / fullstack
    let framework: String?    // Next.js / Expo / Flutter / ...
    let language: String?
    let suggestedCommand: String?  // already scoped, e.g. "cd apps/web && npm run dev"
}

struct RepoAnalysis: Codable, Sendable {
    let language: String?
    let framework: String?
    let stack: String?
    let projectName: String?
    let suggestedCommand: String?
    let scripts: [String: String]?
    let hasClaudeMd: Bool
    let hasCursorRules: Bool
    let isMonorepo: Bool
    let projects: [RepoSubProject]?  // populated only for monorepos

    func encode() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

class RepoAnalyzer {

    func analyze(at path: String) -> RepoAnalysis {
        return analyze(at: path, scanSubProjects: true)
    }

    private func analyze(at path: String, scanSubProjects: Bool) -> RepoAnalysis {
        let expandedPath = (path as NSString).expandingTildeInPath
        let fm = FileManager.default

        let projectName = (expandedPath as NSString).lastPathComponent
        let hasClaudeMd = fm.fileExists(atPath: "\(expandedPath)/CLAUDE.md")
        let hasCursorRules = fm.fileExists(atPath: "\(expandedPath)/.cursorrules")

        var language: String?
        var framework: String?
        var stack: String?
        var suggestedCommand: String?
        var scripts: [String: String]?

        // Package.json (Node.js / JS / TS)
        if let packageJson = readJSON(at: "\(expandedPath)/package.json") {
            language = fm.fileExists(atPath: "\(expandedPath)/tsconfig.json") ? "TypeScript" : "JavaScript"

            // Merge dependencies + devDependencies for framework detection
            var allDeps: [String: Any] = [:]
            if let deps = packageJson["dependencies"] as? [String: Any] {
                allDeps.merge(deps) { current, _ in current }
            }
            if let devDeps = packageJson["devDependencies"] as? [String: Any] {
                allDeps.merge(devDeps) { current, _ in current }
            }

            // Mobile frameworks take priority over web — a React Native project
            // has react in its deps but is NOT a web workspace.
            if !allDeps.isEmpty {
                if allDeps["expo"] != nil {
                    framework = "Expo"
                    stack = "mobile"
                } else if allDeps["react-native"] != nil {
                    framework = "React Native"
                    stack = "mobile"
                } else if allDeps["next"] != nil {
                    framework = "Next.js"
                    stack = "web"
                } else if allDeps["nuxt"] != nil {
                    framework = "Nuxt"
                    stack = "web"
                } else if allDeps["@remix-run/react"] != nil || allDeps["@remix-run/node"] != nil {
                    framework = "Remix"
                    stack = "web"
                } else if allDeps["@sveltejs/kit"] != nil {
                    framework = "SvelteKit"
                    stack = "web"
                } else if allDeps["astro"] != nil {
                    framework = "Astro"
                    stack = "web"
                } else if allDeps["react"] != nil {
                    framework = allDeps["vite"] != nil ? "React + Vite" : "React"
                    stack = "web"
                } else if allDeps["vue"] != nil {
                    framework = "Vue"
                    stack = "web"
                } else if allDeps["svelte"] != nil {
                    framework = "Svelte"
                    stack = "web"
                } else if allDeps["express"] != nil || allDeps["fastify"] != nil || allDeps["koa"] != nil || allDeps["hono"] != nil {
                    if allDeps["express"] != nil { framework = "Express" }
                    else if allDeps["fastify"] != nil { framework = "Fastify" }
                    else if allDeps["koa"] != nil { framework = "Koa" }
                    else { framework = "Hono" }
                    stack = "backend"
                }
            }

            // Default any un-matched package.json project to web so downstream
            // code (orchestrator, stream start) always has a sensible stack.
            if stack == nil { stack = "web" }

            // Detect package manager from lock files
            let runner = detectPackageRunner(at: expandedPath)

            // Extract scripts for suggested command
            if let scriptMap = packageJson["scripts"] as? [String: String] {
                scripts = scriptMap
                if scriptMap["dev"] != nil {
                    suggestedCommand = "\(runner) run dev"
                } else if scriptMap["start"] != nil {
                    suggestedCommand = runner == "npm" ? "npm start" : "\(runner) run start"
                }
            }

            // Mobile command fallbacks — if no scripts matched, use the
            // canonical invocation for each framework.
            if suggestedCommand == nil {
                if framework == "Expo" {
                    suggestedCommand = runner == "npm" ? "npx expo start" : "\(runner) expo start"
                } else if framework == "React Native" {
                    suggestedCommand = runner == "npm" ? "npx react-native start" : "\(runner) react-native start"
                }
            }
        }

        // Python
        if language == nil && (fm.fileExists(atPath: "\(expandedPath)/pyproject.toml") ||
                              fm.fileExists(atPath: "\(expandedPath)/requirements.txt")) {
            language = "Python"
            stack = "backend"

            if let pyproject = readFileString(at: "\(expandedPath)/pyproject.toml") {
                if pyproject.contains("fastapi") {
                    framework = "FastAPI"
                    suggestedCommand = "uvicorn main:app --reload"
                } else if pyproject.contains("django") {
                    framework = "Django"
                    suggestedCommand = "python manage.py runserver"
                } else if pyproject.contains("flask") {
                    framework = "Flask"
                    suggestedCommand = "flask run"
                }
            }
        }

        // Rust
        if language == nil && fm.fileExists(atPath: "\(expandedPath)/Cargo.toml") {
            language = "Rust"
            stack = "backend"
            suggestedCommand = "cargo run"

            if let cargo = readFileString(at: "\(expandedPath)/Cargo.toml") {
                if cargo.contains("actix") {
                    framework = "Actix"
                } else if cargo.contains("axum") {
                    framework = "Axum"
                } else if cargo.contains("rocket") {
                    framework = "Rocket"
                }
            }
        }

        // Go
        if language == nil && fm.fileExists(atPath: "\(expandedPath)/go.mod") {
            language = "Go"
            stack = "backend"
            suggestedCommand = "go run ."

            if let gomod = readFileString(at: "\(expandedPath)/go.mod") {
                if gomod.contains("gin-gonic") {
                    framework = "Gin"
                } else if gomod.contains("gofiber") {
                    framework = "Fiber"
                } else if gomod.contains("echo") {
                    framework = "Echo"
                }
            }
        }

        // Swift Package
        if language == nil && fm.fileExists(atPath: "\(expandedPath)/Package.swift") {
            language = "Swift"
            if fm.fileExists(atPath: "\(expandedPath)/Sources") {
                stack = fm.fileExists(atPath: "\(expandedPath)/ios") ? "mobile" : "backend"
                if let pkg = readFileString(at: "\(expandedPath)/Package.swift") {
                    if pkg.contains("Vapor") {
                        framework = "Vapor"
                        suggestedCommand = "swift run"
                    }
                }
            } else {
                stack = "mobile"
            }
        }

        // Xcode project (native iOS / macOS)
        if language == nil {
            let contents = (try? fm.contentsOfDirectory(atPath: expandedPath)) ?? []
            if let xcworkspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
                language = "Swift"
                stack = "mobile"
                framework = "SwiftUI/UIKit"
                let scheme = (xcworkspace as NSString).deletingPathExtension
                suggestedCommand = "xcodebuild -workspace \"\(xcworkspace)\" -scheme \"\(scheme)\" -destination 'platform=iOS Simulator,name=iPhone 15' build"
            } else if let xcodeproj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
                language = "Swift"
                stack = "mobile"
                framework = "SwiftUI/UIKit"
                let scheme = (xcodeproj as NSString).deletingPathExtension
                suggestedCommand = "xcodebuild -scheme \"\(scheme)\" -destination 'platform=iOS Simulator,name=iPhone 15' build"
            }
        }

        // Flutter (pubspec.yaml)
        if language == nil && fm.fileExists(atPath: "\(expandedPath)/pubspec.yaml") {
            language = "Dart"
            framework = "Flutter"
            stack = "mobile"
            suggestedCommand = "flutter run"
        }

        // Gradle (Android, Kotlin, Java)
        if language == nil {
            let hasGradleKts = fm.fileExists(atPath: "\(expandedPath)/build.gradle.kts") ||
                               fm.fileExists(atPath: "\(expandedPath)/settings.gradle.kts")
            let hasGradleGroovy = fm.fileExists(atPath: "\(expandedPath)/build.gradle") ||
                                  fm.fileExists(atPath: "\(expandedPath)/settings.gradle")
            if hasGradleKts || hasGradleGroovy {
                let rootGradle = readFileString(at: "\(expandedPath)/build.gradle") ??
                                 readFileString(at: "\(expandedPath)/build.gradle.kts") ?? ""
                let appGradle = readFileString(at: "\(expandedPath)/app/build.gradle") ??
                                readFileString(at: "\(expandedPath)/app/build.gradle.kts") ?? ""
                let gradleContent = rootGradle + "\n" + appGradle

                let isAndroid = gradleContent.contains("com.android.application") ||
                                gradleContent.contains("com.android.library") ||
                                fm.fileExists(atPath: "\(expandedPath)/app/src/main/AndroidManifest.xml")
                let isKotlin = hasGradleKts || gradleContent.contains("kotlin")

                language = isKotlin ? "Kotlin" : "Java"
                let wrapper = fm.fileExists(atPath: "\(expandedPath)/gradlew") ? "./gradlew" : "gradle"

                if isAndroid {
                    framework = "Android"
                    stack = "mobile"
                    suggestedCommand = "\(wrapper) installDebug"
                } else {
                    framework = "Gradle"
                    stack = "backend"
                    suggestedCommand = "\(wrapper) run"
                }
            }
        }

        // .NET / C# / F# (csproj / sln / fsproj)
        if language == nil {
            let contents = (try? fm.contentsOfDirectory(atPath: expandedPath)) ?? []
            let hasSln = contents.contains(where: { $0.hasSuffix(".sln") })
            let hasCsproj = contents.contains(where: { $0.hasSuffix(".csproj") })
            let hasFsproj = contents.contains(where: { $0.hasSuffix(".fsproj") })
            if hasSln || hasCsproj || hasFsproj {
                language = hasFsproj ? "F#" : "C#"
                framework = ".NET"
                // .NET covers desktop (WPF/WinUI), web (ASP.NET/Blazor), CLI,
                // and services. Without parsing the csproj we can't tell which
                // — surface it as fullstack so the UI shows a chip and let the
                // user override if needed.
                stack = "fullstack"
                suggestedCommand = "dotnet run"
            }
        }

        // Makefile / Justfile
        if suggestedCommand == nil {
            if fm.fileExists(atPath: "\(expandedPath)/Makefile") {
                suggestedCommand = "make"
            } else if fm.fileExists(atPath: "\(expandedPath)/Justfile") || fm.fileExists(atPath: "\(expandedPath)/justfile") {
                suggestedCommand = "just"
            }
        }

        // Monorepo detection + recursive sub-project analysis. We only scan
        // one level deep (scanSubProjects=false on the recursive call) so a
        // sub-project that is itself a monorepo doesn't explode.
        var isMonorepo = false
        var subProjects: [RepoSubProject]? = nil
        if scanSubProjects {
            if let patterns = detectMonorepoPatterns(at: expandedPath) {
                let relPaths = expandWorkspacePatterns(patterns, at: expandedPath)
                var found: [RepoSubProject] = []
                for relPath in relPaths {
                    let subFullPath = "\(expandedPath)/\(relPath)"
                    let sub = analyze(at: subFullPath, scanSubProjects: false)
                    // Skip dirs we couldn't classify — they add noise to the picker.
                    guard sub.stack != nil || sub.framework != nil || sub.language != nil else { continue }
                    let scopedCmd: String? = sub.suggestedCommand.map { "cd \(relPath) && \($0)" }
                    found.append(RepoSubProject(
                        name: (relPath as NSString).lastPathComponent,
                        path: relPath,
                        stack: sub.stack,
                        framework: sub.framework,
                        language: sub.language,
                        suggestedCommand: scopedCmd
                    ))
                }
                if !found.isEmpty {
                    isMonorepo = true
                    subProjects = found.sorted { $0.path < $1.path }

                    // A monorepo rarely has a single coherent "stack" — surface
                    // it as fullstack so the iOS UI knows to show the picker,
                    // and clear the top-level command (it would be wrong anyway).
                    if found.count > 1 {
                        stack = "fullstack"
                        suggestedCommand = nil
                    }
                }
            }
        }

        return RepoAnalysis(
            language: language,
            framework: framework,
            stack: stack,
            projectName: projectName,
            suggestedCommand: suggestedCommand,
            scripts: scripts,
            hasClaudeMd: hasClaudeMd,
            hasCursorRules: hasCursorRules,
            isMonorepo: isMonorepo,
            projects: subProjects
        )
    }

    // MARK: - Monorepo detection

    /// Returns the list of workspace glob patterns if this path is a monorepo,
    /// or nil if it isn't. Patterns are the raw strings from the config
    /// (e.g. "apps/*", "packages/*") — they still need to be expanded to
    /// actual directories via `expandWorkspacePatterns`.
    private func detectMonorepoPatterns(at path: String) -> [String]? {
        let fm = FileManager.default
        var patterns: [String] = []

        // npm / yarn / bun workspaces declared in package.json
        if let pkg = readJSON(at: "\(path)/package.json") {
            if let ws = pkg["workspaces"] as? [String] {
                patterns.append(contentsOf: ws)
            } else if let wsObj = pkg["workspaces"] as? [String: Any],
                      let pkgs = wsObj["packages"] as? [String] {
                patterns.append(contentsOf: pkgs)
            }
        }

        // pnpm-workspace.yaml — minimal line parser (no real YAML lib needed
        // since the file is always a simple `packages:` list).
        if let yaml = readFileString(at: "\(path)/pnpm-workspace.yaml") {
            for rawLine in yaml.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("-") else { continue }
                var value = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if (value.hasPrefix("'") && value.hasSuffix("'")) ||
                   (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                    value = String(value.dropFirst().dropLast())
                }
                if !value.isEmpty { patterns.append(value) }
            }
        }

        // Turborepo / Nx / Lerna don't define workspace layouts themselves —
        // they rely on package.json workspaces or pnpm. But if one of these
        // tools is present and no patterns were found, fall back to the
        // conventional layout.
        let hasMonorepoTool = fm.fileExists(atPath: "\(path)/turbo.json") ||
                              fm.fileExists(atPath: "\(path)/nx.json") ||
                              fm.fileExists(atPath: "\(path)/lerna.json")

        if patterns.isEmpty && hasMonorepoTool {
            patterns = ["apps/*", "packages/*"]
        }

        // Final fallback: if there's an `apps/` directory with multiple
        // sub-folders AND a root package.json or pubspec.yaml, treat it as
        // an implicit monorepo. This catches repos that ship sub-apps under
        // `apps/` without declaring workspaces.
        if patterns.isEmpty {
            let hasAppsDir = fm.fileExists(atPath: "\(path)/apps")
            let hasRootProject = fm.fileExists(atPath: "\(path)/package.json") ||
                                 fm.fileExists(atPath: "\(path)/pubspec.yaml") ||
                                 fm.fileExists(atPath: "\(path)/Cargo.toml")
            if hasAppsDir && hasRootProject {
                patterns = ["apps/*"]
            }
        }

        return patterns.isEmpty ? nil : patterns
    }

    /// Expands glob patterns like "apps/*" into actual repo-relative paths
    /// that contain a recognizable project (package.json, Cargo.toml, etc.).
    /// Only the trailing "/*" glob is supported — that's what workspace
    /// config files use in practice.
    ///
    /// Also does a one-level scan of the repo root to catch projects that
    /// live alongside declared workspaces but aren't part of them (e.g. a
    /// repo with `relay/` + `website/` as npm workspaces plus native
    /// `TarsyiOS/` + `TarsymacOS/` Xcode projects at the root).
    private func expandWorkspacePatterns(_ patterns: [String], at root: String) -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        var seen = Set<String>()

        for pattern in patterns {
            // Ignore negation patterns (e.g. "!apps/legacy") for now.
            if pattern.hasPrefix("!") { continue }

            if pattern.hasSuffix("/*") {
                let dir = String(pattern.dropLast(2))
                let fullDir = "\(root)/\(dir)"
                guard let contents = try? fm.contentsOfDirectory(atPath: fullDir) else { continue }
                for item in contents.sorted() {
                    if item.hasPrefix(".") { continue }
                    let subPath = "\(fullDir)/\(item)"
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
                    if hasProjectMarker(at: subPath) {
                        let rel = "\(dir)/\(item)"
                        if seen.insert(rel).inserted { results.append(rel) }
                    }
                }
            } else if pattern.hasSuffix("/**") {
                // Not supported — conservatively skip to avoid deep scans.
                continue
            } else {
                // Exact path.
                let fullDir = "\(root)/\(pattern)"
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullDir, isDirectory: &isDir), isDir.boolValue,
                   hasProjectMarker(at: fullDir),
                   seen.insert(pattern).inserted {
                    results.append(pattern)
                }
            }
        }

        // Supplementary root scan: catch top-level projects that aren't
        // declared as workspaces. Only runs for confirmed monorepos, so
        // this can't cause false positives on plain single-project repos.
        var rootSkip: Set<String> = [
            "node_modules", "build", "dist", "target", "out",
            ".git", ".github", ".gitlab", ".vscode", ".idea",
            ".next", ".nuxt", ".turbo", ".cache", ".parcel-cache",
            "coverage", "logs", "tmp", "temp",
            "DerivedData", "Pods", ".build",
            "scripts", "docs", "assets", "images", "logos",
            "supabase", "migrations"
        ]

        // When the root is clearly a React Native / Expo / Flutter project,
        // the conventional native-shell subdirectories (`ios`, `android`,
        // `macos`, `windows`, `linux`, `web`) are NOT standalone sub-projects
        // — they're built by the JS toolchain as part of the main app.
        // Surfacing `ios/` as its own sub-project led users to pick it in
        // the monorepo migration picker, which then pointed the workspace
        // at the native Xcode shell. Build & Run would run xcodebuild
        // directly instead of `expo run:ios`, producing an installed app
        // with no Metro handshake and the infamous
        // `unsanitizedScriptURLString = (null)` error.
        if isJSMobileRoot(at: root) {
            rootSkip.formUnion(["ios", "android", "macos", "windows", "linux", "web"])
        }
        if let rootContents = try? fm.contentsOfDirectory(atPath: root) {
            for item in rootContents.sorted() {
                if item.hasPrefix(".") || rootSkip.contains(item) { continue }
                let subPath = "\(root)/\(item)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
                if hasProjectMarker(at: subPath), seen.insert(item).inserted {
                    results.append(item)
                }
            }
        }

        return results
    }

    /// True when the directory's root manifest marks it as a JS-based
    /// mobile project (React Native, Expo) or Flutter — in which case the
    /// conventional `ios/`, `android/`, `macos/`, `windows/`, `linux/`,
    /// `web/` subdirectories are native shells owned by the JS/Dart
    /// toolchain, not standalone sub-projects to surface in the picker.
    private func isJSMobileRoot(at path: String) -> Bool {
        let fm = FileManager.default
        // Flutter — pubspec.yaml at root means ios/android are Flutter shells.
        if fm.fileExists(atPath: "\(path)/pubspec.yaml") { return true }
        // RN / Expo — package.json with react-native or expo in any dep section.
        guard let pkg = readJSON(at: "\(path)/package.json") else { return false }
        for section in ["dependencies", "devDependencies", "peerDependencies"] {
            guard let deps = pkg[section] as? [String: Any] else { continue }
            if deps["react-native"] != nil || deps["expo"] != nil { return true }
        }
        return false
    }

    private func hasProjectMarker(at path: String) -> Bool {
        let fm = FileManager.default
        let markers = [
            "package.json",
            "pubspec.yaml",
            "Cargo.toml",
            "go.mod",
            "Package.swift",
            "pyproject.toml",
            "requirements.txt",
            "build.gradle",
            "build.gradle.kts"
        ]
        for marker in markers {
            if fm.fileExists(atPath: "\(path)/\(marker)") { return true }
        }
        // Extension-based markers: Xcode projects and .NET solutions/projects.
        if let contents = try? fm.contentsOfDirectory(atPath: path) {
            if contents.contains(where: {
                $0.hasSuffix(".xcodeproj") ||
                $0.hasSuffix(".xcworkspace") ||
                $0.hasSuffix(".csproj") ||
                $0.hasSuffix(".sln") ||
                $0.hasSuffix(".fsproj")
            }) {
                return true
            }
        }
        return false
    }

    private func readJSON(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func detectPackageRunner(at path: String) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(path)/bun.lockb") || fm.fileExists(atPath: "\(path)/bun.lock") { return "bun" }
        if fm.fileExists(atPath: "\(path)/pnpm-lock.yaml") { return "pnpm" }
        if fm.fileExists(atPath: "\(path)/yarn.lock") { return "yarn" }
        return "npm"
    }

    private func readFileString(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
