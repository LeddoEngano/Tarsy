import Foundation

public struct Profile: Codable, Identifiable, Sendable {
    public let id: UUID
    public let email: String
    public var displayName: String?
    public var avatarUrl: String?
    public var voiceLanguage: String
    public var agentPermissions: [String: String]  // engineType.rawValue -> "safe"/"dangerous"
    public var isPro: Bool
    public var subscriptionStatus: String
    public var subscriptionEndDate: Date?
    public var onboarded: Bool
    public let createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case voiceLanguage = "voice_language"
        case agentPermissions = "agent_permissions"
        case isPro = "is_pro"
        case subscriptionStatus = "subscription_status"
        case subscriptionEndDate = "subscription_end_date"
        case onboarded
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID,
        email: String,
        displayName: String? = nil,
        avatarUrl: String? = nil,
        voiceLanguage: String = "en",
        agentPermissions: [String: String] = [:],
        isPro: Bool = false,
        subscriptionStatus: String = "inactive",
        subscriptionEndDate: Date? = nil,
        onboarded: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.voiceLanguage = voiceLanguage
        self.agentPermissions = agentPermissions
        self.isPro = isPro
        self.subscriptionStatus = subscriptionStatus
        self.subscriptionEndDate = subscriptionEndDate
        self.onboarded = onboarded
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Helpers

    public func permissionMode(for engineType: AIEngineType) -> AgentPermissionConfig.PermissionMode {
        guard let raw = agentPermissions[engineType.rawValue],
              let mode = AgentPermissionConfig.PermissionMode(rawValue: raw) else {
            return .dangerous
        }
        return mode
    }

    public var nameOrEmail: String {
        if let name = displayName, !name.isEmpty { return name }
        return email
    }
}
