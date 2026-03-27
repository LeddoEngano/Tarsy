import Foundation
import Supabase

@MainActor
public class AgentTaskService: ObservableObject {
    @Published public var activeTasks: [AgentTask] = []
    @Published public var isLoading = false

    public init() {}

    // MARK: - Load

    public func loadActiveTasks() async {
        isLoading = true
        do {
            activeTasks = try await supabase
                .from("agent_tasks")
                .select()
                .in("status", values: ["running", "waiting"])
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            print("[AgentTaskService] Load error: \(error)")
        }
        isLoading = false
    }

    public func loadTasks(for workspaceId: UUID) async -> [AgentTask] {
        do {
            return try await supabase
                .from("agent_tasks")
                .select()
                .eq("workspace_id", value: workspaceId.uuidString)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
        } catch {
            print("[AgentTaskService] Load workspace tasks error: \(error)")
            return []
        }
    }

    // MARK: - Create

    public func createTask(
        workspaceId: UUID,
        tabId: String,
        description: String,
        sessionId: String? = nil,
        engineType: String? = nil
    ) async -> AgentTask? {
        let task = AgentTask(
            userId: UUID(), // Will be overridden by default auth.uid()
            workspaceId: workspaceId,
            tabId: tabId,
            description: description,
            sessionId: sessionId,
            engineType: engineType
        )
        do {
            let created: AgentTask = try await supabase
                .from("agent_tasks")
                .insert(task)
                .select()
                .single()
                .execute()
                .value
            await MainActor.run {
                activeTasks.insert(created, at: 0)
            }
            return created
        } catch {
            print("[AgentTaskService] Create error: \(error)")
            return nil
        }
    }

    // MARK: - Update Status

    public func updateStatus(_ taskId: UUID, status: AgentTask.TaskStatus, errorMessage: String? = nil) async {
        do {
            var update: [String: String] = ["status": status.rawValue]
            if let err = errorMessage {
                update["error_message"] = err
            }
            try await supabase
                .from("agent_tasks")
                .update(update)
                .eq("id", value: taskId.uuidString)
                .execute()

            if let idx = activeTasks.firstIndex(where: { $0.id == taskId }) {
                activeTasks[idx].status = status
                if status == .completed || status == .error {
                    // Remove from active after a delay
                    let id = taskId
                    Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        await MainActor.run {
                            activeTasks.removeAll { $0.id == id }
                        }
                    }
                }
            }
        } catch {
            print("[AgentTaskService] Update error: \(error)")
        }
    }

    public func updateStatusBySession(_ sessionId: String, status: AgentTask.TaskStatus, errorMessage: String? = nil) async {
        if let task = activeTasks.first(where: { $0.sessionId == sessionId }) {
            await updateStatus(task.id, status: status, errorMessage: errorMessage)
        }
    }

    // MARK: - Cleanup

    public func cleanupOldTasks(olderThanDays: Int = 7) async {
        let cutoff = Calendar.current.date(byAdding: .day, value: -olderThanDays, to: Date()) ?? Date()
        let formatter = ISO8601DateFormatter()
        do {
            try await supabase
                .from("agent_tasks")
                .delete()
                .in("status", values: ["completed", "error"])
                .lt("updated_at", value: formatter.string(from: cutoff))
                .execute()
        } catch {
            print("[AgentTaskService] Cleanup error: \(error)")
        }
    }
}
