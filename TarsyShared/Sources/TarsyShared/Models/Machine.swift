import Foundation

public struct Machine: Codable, Identifiable, Sendable {
    public let id: UUID
    public let userId: UUID
    public let hostname: String
    public let hardwareUuid: String?
    public let displayName: String?
    public let tailscaleIp: String?
    public let localIp: String?
    public let modelIdentifier: String?
    public let status: MachineStatus
    public let lastSeenAt: Date?
    public let createdAt: Date

    public enum MachineStatus: String, Codable, Sendable {
        case online
        case offline
    }

    /// Display name with fallback to hostname
    public var name: String {
        displayName ?? hostname
    }

    /// Whether this machine was seen recently (within last 2 minutes)
    public var isRecentlyOnline: Bool {
        guard status == .online, let lastSeen = lastSeenAt else { return false }
        return Date().timeIntervalSince(lastSeen) < 120
    }

    /// SF Symbol name for this Mac model.
    /// `modelIdentifier` format: "MacBook Air (Mac15,12)" or just "Mac15,12"
    public var deviceIcon: String {
        guard let model = modelIdentifier?.lowercased() else { return "desktopcomputer" }

        // Match human-readable name first (e.g. "MacBook Air (Mac15,12)")
        if model.contains("macbook") { return "laptopcomputer" }
        if model.contains("mac mini") { return "macmini" }
        if model.contains("mac studio") { return "macstudio" }
        if model.contains("mac pro") { return "macpro.gen3" }
        if model.contains("imac") { return "desktopcomputer" }

        return "desktopcomputer"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case hostname
        case hardwareUuid = "hardware_uuid"
        case displayName = "display_name"
        case tailscaleIp = "tailscale_ip"
        case localIp = "local_ip"
        case modelIdentifier = "model_identifier"
        case status
        case lastSeenAt = "last_seen_at"
        case createdAt = "created_at"
    }
}
