import Foundation
import TarsyShared

struct RepoAnalysis: Codable, Sendable {
    let language: String?
    let framework: String?
    let stack: String?
    let projectName: String?
    let suggestedCommand: String?
    let scripts: [String: String]?
    let hasClaudeMd: Bool
    let hasCursorRules: Bool

    func encode() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

class RepoAnalyzer {

    func analyze(at path: String) -> RepoAnalysis {
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

            if let deps = packageJson["dependencies"] as? [String: Any] {
                if deps["next"] != nil {
                    framework = "Next.js"
                    stack = "web"
                } else if deps["nuxt"] != nil {
                    framework = "Nuxt"
                    stack = "web"
                } else if deps["react"] != nil {
                    framework = deps["vite"] != nil ? "React + Vite" : "React"
                    stack = "web"
                } else if deps["vue"] != nil {
                    framework = "Vue"
                    stack = "web"
                } else if deps["express"] != nil || deps["fastify"] != nil || deps["koa"] != nil {
                    framework = deps["express"] != nil ? "Express" : (deps["fastify"] != nil ? "Fastify" : "Koa")
                    stack = "backend"
                } else if deps["react-native"] != nil || deps["expo"] != nil {
                    framework = deps["expo"] != nil ? "Expo" : "React Native"
                    stack = "mobile"
                }
            }

            // Extract scripts for suggested command
            if let scriptMap = packageJson["scripts"] as? [String: String] {
                scripts = scriptMap
                // Suggest dev command
                if scriptMap["dev"] != nil {
                    suggestedCommand = "npm run dev"
                } else if scriptMap["start"] != nil {
                    suggestedCommand = "npm start"
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

        // Xcode project
        if language == nil {
            let contents = (try? fm.contentsOfDirectory(atPath: expandedPath)) ?? []
            if contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                language = "Swift"
                stack = "mobile"
                framework = "SwiftUI/UIKit"
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

        return RepoAnalysis(
            language: language,
            framework: framework,
            stack: stack,
            projectName: projectName,
            suggestedCommand: suggestedCommand,
            scripts: scripts,
            hasClaudeMd: hasClaudeMd,
            hasCursorRules: hasCursorRules
        )
    }

    private func readJSON(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func readFileString(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
