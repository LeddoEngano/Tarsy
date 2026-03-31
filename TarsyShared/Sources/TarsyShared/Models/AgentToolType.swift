import Foundation

public enum AgentToolType: String, Codable, Sendable {
    case read = "Read"
    case edit = "Edit"
    case write = "Write"
    case bash = "Bash"
    case grep = "Grep"
    case glob = "Glob"
    case thinking = "Thinking"
    case todoWrite = "TodoWrite"
    case agent = "Agent"
    case webSearch = "WebSearch"
    case webFetch = "WebFetch"
    case idle = "Idle"
    case unknown = "Unknown"

    public var displayName: String {
        switch self {
        case .read: return "Reading"
        case .edit: return "Editing"
        case .write: return "Writing"
        case .bash: return "Running"
        case .grep: return "Searching"
        case .glob: return "Finding"
        case .thinking: return "Thinking"
        case .todoWrite: return "Planning"
        case .agent: return "Sub-agent"
        case .webSearch: return "Searching web"
        case .webFetch: return "Fetching"
        case .idle: return "Idle"
        case .unknown: return "Working"
        }
    }

    public var iconName: String {
        switch self {
        case .read: return "doc.text.magnifyingglass"
        case .edit: return "pencil.line"
        case .write: return "doc.badge.plus"
        case .bash: return "terminal"
        case .grep: return "magnifyingglass"
        case .glob: return "folder.fill"
        case .thinking: return "brain"
        case .todoWrite: return "checklist"
        case .agent: return "person.2"
        case .webSearch: return "globe"
        case .webFetch: return "globe"
        case .idle: return "pause.circle"
        case .unknown: return "wrench"
        }
    }

    /// Parse tool type from engine output text
    public static func parse(from output: String) -> AgentToolType? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Match patterns like "⏺ Read(file.swift)" or "Read file.swift"
        if trimmed.contains("Read(") || trimmed.hasPrefix("Read ") { return .read }
        if trimmed.contains("Edit(") || trimmed.hasPrefix("Edit ") { return .edit }
        if trimmed.contains("Write(") || trimmed.hasPrefix("Write ") { return .write }
        if trimmed.contains("Bash(") || trimmed.hasPrefix("Bash ") { return .bash }
        if trimmed.contains("Grep(") || trimmed.hasPrefix("Grep ") { return .grep }
        if trimmed.contains("Glob(") || trimmed.hasPrefix("Glob ") { return .glob }
        if trimmed.contains("TodoWrite(") || trimmed.hasPrefix("TodoWrite ") { return .todoWrite }
        if trimmed.contains("Agent(") || trimmed.hasPrefix("Agent ") { return .agent }
        if trimmed.contains("WebSearch(") || trimmed.hasPrefix("WebSearch ") { return .webSearch }
        if trimmed.contains("WebFetch(") || trimmed.hasPrefix("WebFetch ") { return .webFetch }

        // Thinking indicator
        if trimmed.contains("⏺ Thinking") || trimmed.hasPrefix("Thinking") { return .thinking }

        return nil
    }
}
