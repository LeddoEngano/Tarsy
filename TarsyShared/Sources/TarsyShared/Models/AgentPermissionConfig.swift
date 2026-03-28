import Foundation

public struct AgentPermissionConfig: Codable, Sendable {
    public var claude: PermissionMode = .dangerous
    public var codex: PermissionMode = .dangerous
    public var gemini: PermissionMode = .dangerous
    public var aider: PermissionMode = .dangerous
    public var cursor: PermissionMode = .dangerous
    public var windsurf: PermissionMode = .dangerous
    public var amp: PermissionMode = .dangerous
    public var cline: PermissionMode = .dangerous
    public var copilot: PermissionMode = .dangerous

    public init() {}

    public enum PermissionMode: String, Codable, Sendable {
        case safe
        case dangerous
    }

    public func mode(for engineType: AIEngineType) -> PermissionMode {
        switch engineType {
        case .claude: return claude
        case .codex: return codex
        case .gemini: return gemini
        case .aider: return aider
        case .cursor: return cursor
        case .windsurf: return windsurf
        case .amp: return amp
        case .cline: return cline
        case .copilot: return copilot
        case .custom: return .dangerous
        }
    }

    public mutating func setMode(_ mode: PermissionMode, for engineType: AIEngineType) {
        switch engineType {
        case .claude: claude = mode
        case .codex: codex = mode
        case .gemini: gemini = mode
        case .aider: aider = mode
        case .cursor: cursor = mode
        case .windsurf: windsurf = mode
        case .amp: amp = mode
        case .cline: cline = mode
        case .copilot: copilot = mode
        case .custom: break
        }
    }

    // MARK: - Persistence

    private static let storageKey = "agent_permission_config"

    public static func load() -> AgentPermissionConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(AgentPermissionConfig.self, from: data) else {
            return AgentPermissionConfig()
        }
        return config
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AgentPermissionConfig.storageKey)
        }
    }

    public static var hasBeenConfigured: Bool {
        UserDefaults.standard.data(forKey: storageKey) != nil
    }
}
