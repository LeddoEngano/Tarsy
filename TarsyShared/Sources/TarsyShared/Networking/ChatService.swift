import Foundation

@MainActor
public class ChatService: ObservableObject {
    @Published public var messages: [ChatMessage] = []
    @Published public var isLoading = false
    @Published public var isLoadingOlder = false
    @Published public var hasOlderMessages = false
    @Published public var updateCounter: Int = 0

    private var currentTabId: String?
    private var tabMessages: [String: [ChatMessage]] = [:]

    /// Tracks the current UltraContext session for pagination
    private var currentSessionId: String?
    private var currentSessionTotal: Int = 0
    private var loadedOffset: Int = 0

    /// Number of messages to load per page
    private let pageSize = 50

    public init() {}

    // MARK: - Load from UltraContext

    /// Loads the most recent UltraContext session for this workspace path into the chat.
    /// Loads only the last `pageSize` messages. Use `loadOlderMessages` to fetch earlier history.
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

            // Fetch last page of messages
            let full = try await client.getContext(id: session.id, limit: pageSize)
            let total = full.total ?? full.messages.count

            currentSessionId = session.id
            currentSessionTotal = total
            // The server returns the last `pageSize` messages by default when no offset is given
            loadedOffset = max(0, total - full.messages.count)
            hasOlderMessages = loadedOffset > 0

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
            #if DEBUG
            print("[ChatService] UltraContext load error: \(error)")
            #endif
            return nil
        }
    }

    /// Loads an older page of messages from the current UltraContext session.
    /// Prepends them to the existing messages array.
    public func loadOlderMessages(client: UltraContextClient) async {
        guard let sessionId = currentSessionId,
              loadedOffset > 0,
              !isLoadingOlder else { return }

        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let fetchCount = min(pageSize, loadedOffset)
        let fetchOffset = loadedOffset - fetchCount

        do {
            let older = try await client.getContext(id: sessionId, limit: fetchCount, offset: fetchOffset)
            let olderMessages = older.messages.map { msg in
                ChatMessage(
                    workspaceId: UUID(),
                    tabId: currentTabId ?? "default",
                    role: msg.role == "user" ? .user : .assistant,
                    content: msg.content
                )
            }

            loadedOffset = fetchOffset
            hasOlderMessages = loadedOffset > 0
            messages.insert(contentsOf: olderMessages, at: 0)
        } catch {
            #if DEBUG
            print("[ChatService] Load older messages error: \(error)")
            #endif
        }
    }

    // MARK: - Tab management

    public func switchTab(tabId: String) {
        // Save current tab's messages
        if let currentId = currentTabId {
            tabMessages[currentId] = messages
        }
        currentTabId = tabId
        // Restore target tab's messages
        messages = tabMessages[tabId] ?? []
        // Reset pagination state (each tab has its own session context)
        currentSessionId = nil
        currentSessionTotal = 0
        loadedOffset = 0
        hasOlderMessages = false
    }

    // MARK: - Add

    public func addMessage(_ message: ChatMessage) async {
        if message.tabId == currentTabId {
            messages.append(message)
        } else {
            tabMessages[message.tabId, default: []].append(message)
        }
    }

    public func addAssistantChunk(workspaceId: UUID, tabId: String, content: String) {
        if tabId == currentTabId {
            appendChunk(to: &messages, workspaceId: workspaceId, tabId: tabId, content: content)
            updateCounter += 1
        } else {
            var cached = tabMessages[tabId] ?? []
            appendChunk(to: &cached, workspaceId: workspaceId, tabId: tabId, content: content)
            tabMessages[tabId] = cached
        }
    }

    private func appendChunk(to msgs: inout [ChatMessage], workspaceId: UUID, tabId: String, content: String) {
        if let last = msgs.last, last.role == .assistant, last.tabId == tabId {
            let updated = ChatMessage(
                id: last.id,
                workspaceId: last.workspaceId,
                tabId: last.tabId,
                role: .assistant,
                content: last.content + content,
                createdAt: last.createdAt
            )
            msgs[msgs.count - 1] = updated
        } else {
            let msg = ChatMessage(
                workspaceId: workspaceId,
                tabId: tabId,
                role: .assistant,
                content: content.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
            )
            msgs.append(msg)
        }
    }

    /// Remove cached messages for a closed tab.
    public func removeTab(_ tabId: String) {
        tabMessages.removeValue(forKey: tabId)
    }
}
