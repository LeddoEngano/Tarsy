import Foundation

public struct Workspace: Codable, Identifiable, Sendable {
    public let id: UUID
    public let userId: UUID
    public let machineId: UUID
    public let name: String
    public let repoUrl: String?
    public let localPath: String
    public let stack: WorkspaceStack
    public let status: WorkspaceStatus
    public let workspaceType: WorkspaceType
    public let currentBranch: String?
    public let devServerCommand: String?
    public let streamUrl: String?
    public let aiContext: String?
    public let config: [String: String]?
    public let createdAt: Date
    public let updatedAt: Date

    public enum WorkspaceStack: String, Codable, Sendable {
        case web
        case mobile
        case backend
        case fullstack
    }

    public enum WorkspaceStatus: String, Codable, Sendable {
        case idle
        case starting
        case running
        case error
    }

    public enum WorkspaceType: String, Codable, Sendable {
        case standard
        case openClaw = "openclaw"
    }

    /// Whether this workspace captures the full screen instead of a window
    public var isFullScreen: Bool {
        workspaceType == .openClaw
    }

    /// Repo-relative sub-path for monorepo workspaces (e.g. "apps/web"). Nil when the workspace points at the repo root.
    public var subPath: String? {
        guard let raw = config?["subPath"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// True when the user has been through the monorepo sub-project picker
    /// (either by choosing a project or explicitly opting to use the repo
    /// root). Used by `WorkspaceView` to avoid re-prompting on every open
    /// for legacy workspaces created before sub-path persistence shipped.
    public var subPathConfigured: Bool {
        // A non-empty subPath implies the picker ran during creation.
        if subPath != nil { return true }
        return config?["subPathConfigured"] == "true"
    }

    /// Working directory commands and agents should run from. Joins `localPath` with `subPath` when present.
    public var effectivePath: String {
        guard let sub = subPath, !sub.isEmpty else { return localPath }
        let trimmedRoot = localPath.hasSuffix("/") ? String(localPath.dropLast()) : localPath
        return "\(trimmedRoot)/\(sub)"
    }

    /// Detected primary language (e.g. "Swift", "TypeScript"), captured at workspace creation.
    public var language: String? {
        config?["language"]
    }

    /// Detected framework (e.g. "SwiftUI/UIKit", "Expo", "Next.js"), captured at workspace creation.
    public var framework: String? {
        config?["framework"]
    }

    /// Which Build & Run runner the macOS daemon should dispatch to. Nil
    /// when the stack has no supported runner — used by `WorkspaceView` to
    /// hide the Build & Run controls.
    ///
    /// Each runner has different mechanics (xcodebuild + dylib injection
    /// for Swift; long-running Metro process for Expo; Dart VM daemon for
    /// Flutter), so the iOS side announces which one applies and the macOS
    /// daemon picks the implementation.
    public enum BuildRunner: String, Sendable {
        case xcode    // Native Apple: xcodebuild + simulator install + Tarsy hot reload
        case expo     // Expo / React Native: `npx expo run:ios` + Metro Fast Refresh
        case flutter  // Flutter: `flutter run` + Dart VM hot reload
    }

    /// Resolves the `BuildRunner` for this workspace based on `language` /
    /// `framework` saved in `config`, with a legacy fallback for pre-config
    /// workspaces tagged `stack=mobile`.
    public var buildRunner: BuildRunner? {
        if let fw = framework?.lowercased() {
            if fw.contains("expo") || fw.contains("react native") {
                return .expo
            }
            if fw.contains("flutter") {
                return .flutter
            }
            if fw.contains("swiftui") || fw.contains("uikit") {
                return .xcode
            }
        }
        if language?.caseInsensitiveCompare("Swift") == .orderedSame {
            // Exclude server-side Swift (Vapor) — Build & Run only makes
            // sense for Apple-platform builds.
            if framework?.caseInsensitiveCompare("Vapor") == .orderedSame { return nil }
            return .xcode
        }
        if let lang = language?.lowercased() {
            if lang == "dart" { return .flutter }
            // Known non-supported mobile languages.
            if lang == "kotlin" || lang == "java" { return nil }
        }
        // Legacy fallback: pre-config workspace tagged as mobile. Default
        // to .xcode since that's what RepoAnalyzer tagged as mobile most
        // of the time before framework persistence shipped.
        if stack == .mobile { return .xcode }
        return nil
    }

    /// True when the workspace has a runner the macOS daemon knows how to
    /// drive. Convenience over `buildRunner != nil` — read sites are about
    /// UI gating, not which runner.
    public var supportsBuildAndRun: Bool {
        buildRunner != nil
    }

    /// Backwards-compat shim. Older call sites referenced `isSwiftMobile`
    /// before the runner abstraction; keep them working until they're
    /// migrated to `supportsBuildAndRun` / `buildRunner`.
    public var isSwiftMobile: Bool {
        buildRunner == .xcode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userId = try container.decode(UUID.self, forKey: .userId)
        machineId = try container.decode(UUID.self, forKey: .machineId)
        name = try container.decode(String.self, forKey: .name)
        repoUrl = try container.decodeIfPresent(String.self, forKey: .repoUrl)
        localPath = try container.decode(String.self, forKey: .localPath)
        stack = try container.decode(WorkspaceStack.self, forKey: .stack)
        status = try container.decode(WorkspaceStatus.self, forKey: .status)
        workspaceType = (try? container.decode(WorkspaceType.self, forKey: .workspaceType)) ?? .standard
        currentBranch = try container.decodeIfPresent(String.self, forKey: .currentBranch)
        devServerCommand = try container.decodeIfPresent(String.self, forKey: .devServerCommand)
        streamUrl = try container.decodeIfPresent(String.self, forKey: .streamUrl)
        aiContext = try container.decodeIfPresent(String.self, forKey: .aiContext)
        config = try container.decodeIfPresent([String: String].self, forKey: .config)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case machineId = "machine_id"
        case name
        case repoUrl = "repo_url"
        case localPath = "local_path"
        case stack
        case status
        case workspaceType = "workspace_type"
        case currentBranch = "current_branch"
        case devServerCommand = "dev_server_command"
        case streamUrl = "stream_url"
        case aiContext = "ai_context"
        case config
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
