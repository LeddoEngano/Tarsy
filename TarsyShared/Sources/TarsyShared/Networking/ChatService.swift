import Foundation
import Supabase

@MainActor
public class ChatService: ObservableObject {
    @Published public var messages: [ChatMessage] = []
    @Published public var isLoading = false
    @Published public var hasMoreMessages = false
    @Published public var updateCounter: Int = 0

    private static let pageSize = 50
    private var currentWorkspaceId: UUID?
    private var currentTabId: String?

    public init() {}

    // MARK: - Load (paginated)

    public func loadMessages(workspaceId: UUID, tabId: String) async {
        isLoading = true
        currentWorkspaceId = workspaceId
        currentTabId = tabId
        do {
            // Fetch most recent N messages (descending), then reverse for chronological display
            let fetched: [ChatMessage] = try await supabase
                .from("chat_messages")
                .select()
                .eq("workspace_id", value: workspaceId.uuidString)
                .eq("tab_id", value: tabId)
                .order("created_at", ascending: false)
                .limit(Self.pageSize)
                .execute()
                .value
            messages = fetched.reversed()
            hasMoreMessages = fetched.count >= Self.pageSize
        } catch {
            print("[ChatService] Load error: \(error)")
        }
        isLoading = false
    }

    public func loadOlderMessages() async {
        guard let workspaceId = currentWorkspaceId,
              let tabId = currentTabId,
              let oldest = messages.first,
              hasMoreMessages else { return }

        do {
            let formatter = ISO8601DateFormatter()
            let cutoff = formatter.string(from: oldest.createdAt)
            let older: [ChatMessage] = try await supabase
                .from("chat_messages")
                .select()
                .eq("workspace_id", value: workspaceId.uuidString)
                .eq("tab_id", value: tabId)
                .lt("created_at", value: cutoff)
                .order("created_at", ascending: false)
                .limit(Self.pageSize)
                .execute()
                .value
            let sorted = older.reversed()
            messages.insert(contentsOf: sorted, at: 0)
            hasMoreMessages = older.count >= Self.pageSize
        } catch {
            print("[ChatService] Load older error: \(error)")
        }
    }

    // MARK: - Add

    public func addMessage(_ message: ChatMessage) async {
        messages.append(message)
        do {
            try await supabase
                .from("chat_messages")
                .insert(message)
                .execute()
        } catch {
            print("[ChatService] Save error: \(error)")
        }
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
                content: content
            )
            messages.append(msg)
        }
    }

    public func saveLastAssistantMessage() async {
        guard let last = messages.last, last.role == .assistant else { return }
        do {
            try await supabase
                .from("chat_messages")
                .upsert(last)
                .execute()
        } catch {
            print("[ChatService] Save assistant error: \(error)")
        }
    }
}
