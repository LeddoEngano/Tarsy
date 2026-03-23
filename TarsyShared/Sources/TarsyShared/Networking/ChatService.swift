import Foundation
import Supabase

@MainActor
public class ChatService: ObservableObject {
    @Published public var messages: [ChatMessage] = []
    @Published public var isLoading = false

    public init() {}

    public func loadMessages(workspaceId: UUID, tabId: String) async {
        isLoading = true
        do {
            messages = try await supabase
                .from("chat_messages")
                .select()
                .eq("workspace_id", value: workspaceId.uuidString)
                .eq("tab_id", value: tabId)
                .order("created_at", ascending: true)
                .execute()
                .value
        } catch {
            print("[ChatService] Load error: \(error)")
        }
        isLoading = false
    }

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
