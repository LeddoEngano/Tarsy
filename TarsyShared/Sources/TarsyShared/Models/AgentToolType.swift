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

    /// Parse tool type from engine output text.
    /// Matches formats: "🔧 Read: path", "⏺ Read(path)", "Read path", "Read(path)"
    public static func parse(from output: String) -> AgentToolType? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract the tool name from common formats:
        //   "🔧 Read: /path/to/file"  →  "Read"
        //   "⏺ Read(file.swift)"      →  "Read"
        //   "Read file.swift"          →  "Read"
        for tool in allToolNames {
            if trimmed.contains("\(tool)(") || trimmed.contains("\(tool):") ||
               trimmed.hasPrefix("\(tool) ") || trimmed.hasPrefix("\(tool)\t") {
                return fromName(tool)
            }
        }

        // Thinking indicator
        if trimmed.contains("Thinking") { return .thinking }

        return nil
    }

    private static let allToolNames = [
        "Read", "Edit", "Write", "Bash", "Grep", "Glob",
        "TodoWrite", "Agent", "WebSearch", "WebFetch"
    ]

    private static func fromName(_ name: String) -> AgentToolType? {
        switch name {
        case "Read": return .read
        case "Edit": return .edit
        case "Write": return .write
        case "Bash": return .bash
        case "Grep": return .grep
        case "Glob": return .glob
        case "TodoWrite": return .todoWrite
        case "Agent": return .agent
        case "WebSearch": return .webSearch
        case "WebFetch": return .webFetch
        default: return nil
        }
    }
}
