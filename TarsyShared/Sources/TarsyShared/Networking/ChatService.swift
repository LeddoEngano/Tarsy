import Foundation

@MainActor
public class ChatService: ObservableObject {
    @Published public var messages: [ChatMessage] = []
    @Published public var isLoading = false
    @Published public var updateCounter: Int = 0

    private var currentTabId: String?

    public init() {}

    // MARK: - Load from UltraContext

    /// Loads the most recent UltraContext session for this workspace path into the chat.
    /// Returns the session if found, nil otherwise.
    @discardableResult
    public func loadFromUltraContext(workspacePath: String, client: UltraContextClient) async -> UltraContextSession? {
        isLoading = true
        defer { isLoading = false }

        do {
            let sessions = try await client.listContexts()
            // Find the most recent session matching this workspace
            guard let session = sessions
                .filter({ $0.projectPath == workspacePath })
                .sorted(by: { ($0.updatedAt ?? $0.createdAt ?? "") > ($1.updatedAt ?? $1.createdAt ?? "") })
                .first else {
                return nil
            }

            // Fetch full session with messages
            let full = try await client.getContext(id: session.id)
            messages = full.messages.map { msg in
                ChatMessage(
                    workspaceId: UUID(),
                    tabId: currentTabId ?? "default",
                    role: msg.role == "user" ? .user : .assistant,
                    content: msg.content
                )
            }
            return full
        } catch {
            print("[ChatService] UltraContext load error: \(error)")
            return nil
        }
    }

    // MARK: - Tab management

    public func switchTab(tabId: String) {
        currentTabId = tabId
        messages = []
    }

    // MARK: - Add

    public func addMessage(_ message: ChatMessage) async {
        messages.append(message)
    }

    public func addAssistantChunk(workspaceId: UUID, tabId: String, content: String) {
        // If last message is from assistant in same tab, append to it
        if let last = messages.last, last.role == .assistant, last.tabId == tabId {
            let updated = ChatMessage(
                id: last.id,
                workspaceId: last.workspaceId,
                tabId: last.tabId,
                role: .assistant,
                content: last.content + content,
                createdAt: last.createdAt
            )
            messages[messages.count - 1] = updated
            updateCounter += 1
        } else {
            let msg = ChatMessage(
                workspaceId: workspaceId,
                tabId: tabId,
                role: .assistant,
                content: content.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
            )
            messages.append(msg)
        }
    }
}
