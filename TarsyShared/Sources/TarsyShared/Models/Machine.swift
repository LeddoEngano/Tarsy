import Foundation

public struct Machine: Codable, Identifiable, Sendable {
    public let id: UUID
    public let userId: UUID
    public let hostname: String
    public let tailscaleIp: String
    public let status: MachineStatus
    public let lastSeenAt: Date?
    public let createdAt: Date

    public enum MachineStatus: String, Codable, Sendable {
        case online
        case offline
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case hostname
        case tailscaleIp = "tailscale_ip"
        case status
        case lastSeenAt = "last_seen_at"
        case createdAt = "created_at"
    }
}
