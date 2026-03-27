import Foundation

public struct Machine: Codable, Identifiable, Sendable {
    public let id: UUID
    public let userId: UUID
    public let hostname: String
    public let hardwareUuid: String?
    public let displayName: String?
    public let tailscaleIp: String?
    public let localIp: String?
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

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case hostname
        case hardwareUuid = "hardware_uuid"
        case displayName = "display_name"
        case tailscaleIp = "tailscale_ip"
        case localIp = "local_ip"
        case status
        case lastSeenAt = "last_seen_at"
        case createdAt = "created_at"
    }
}
