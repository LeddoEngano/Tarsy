import Foundation
import Supabase
import UserNotifications

private struct UnreadCountRow: Decodable {
    let workspaceId: UUID
    let unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case unreadCount = "unread_count"
    }
}

@MainActor
public class NotificationBadgeService: ObservableObject {
    @Published public var unreadCounts: [UUID: Int] = [:]

    public init() {}

    /// Fetch unread notification counts per workspace from the database
    public func refreshCounts() async {
        do {
            let rows: [UnreadCountRow] = try await supabase
                .rpc("get_unread_counts")
                .execute()
                .value

            var counts: [UUID: Int] = [:]
            for row in rows {
                counts[row.workspaceId] = row.unreadCount
            }
            unreadCounts = counts
        } catch {
            #if DEBUG
            print("[NotificationBadgeService] Failed to fetch unread counts: \(error)")
            #endif
        }
    }

    /// Mark all notifications for a workspace as read and update badge counts
    public func clearBadge(for workspaceId: UUID) async {
        // Remove from local state immediately (if present)
        unreadCounts.removeValue(forKey: workspaceId)

        // Update app icon badge to remaining total
        let remaining = unreadCounts.values.reduce(0, +)
        updateAppIconBadge(remaining)

        // Mark as read in the database regardless of local state
        do {
            try await supabase
                .from("push_notifications")
                .update(["read_at": Date()])
                .eq("workspace_id", value: workspaceId.uuidString)
                .is("read_at", value: nil)
                .execute()
        } catch {
            #if DEBUG
            print("[NotificationBadgeService] Failed to clear badge: \(error)")
            #endif
            await refreshCounts()
        }
    }

    /// Clear the app icon badge without affecting per-workspace counts
    public func clearAppIconBadge() {
        updateAppIconBadge(0)
    }

    private func updateAppIconBadge(_ count: Int) {
        #if os(iOS)
        UNUserNotificationCenter.current().setBadgeCount(count)
        #endif
    }
}
