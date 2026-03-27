import Foundation
import SwiftUI

@MainActor
class VoiceTodoManager: ObservableObject {
    @Published var items: [VoiceTodoItem] = []
    @Published var isMinimized: Bool = true

    private var nextId = 1
    private var minimizeTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var deferredCompletionTasks: [String: Task<Void, Never>] = [:]

    struct VoiceTodoItem: Identifiable {
        let id: Int
        let text: String
        var sessionId: String
        var status: Status = .working
        var currentTool: String? = nil
        var resumedAt: Date? = nil
        let createdAt: Date = Date()

        enum Status {
            case working
            case question
            case completed
        }
    }

    @discardableResult
    func addItem(text: String, sessionId: String) -> Int {
        let item = VoiceTodoItem(id: nextId, text: text, sessionId: sessionId)
        let itemId = nextId
        nextId += 1
        // Set expanded before appending so the overlay renders expanded on first item
        isMinimized = false
        withAnimation(.easeInOut(duration: 0.25)) {
            items.append(item)
        }
        scheduleMinimize()

        // Safety timeout: auto-complete after 5 minutes if still active
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if let idx = items.firstIndex(where: { $0.id == itemId && $0.status != .completed }) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    items[idx].status = .completed
                }
                scheduleCleanup()
            }
        }

        return itemId
    }

    @discardableResult
    func markCompleted(sessionId: String) -> Bool {
        // Primary: exact sessionId match
        if let idx = items.lastIndex(where: { $0.sessionId == sessionId && ($0.status == .working || $0.status == .question) }) {
            if let resumedAt = items[idx].resumedAt, Date().timeIntervalSince(resumedAt) < 5 {
                scheduleDeferredCompletion(sessionId: sessionId, itemId: items[idx].id, resumedAt: resumedAt)
                return true
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                items[idx].status = .completed
            }
            scheduleCleanup()
            return true
        }
        // Fallback: oldest active item (catches "pending" mismatch, empty string, etc.)
        // Skip items that were just resumed from a question (avoid premature completion)
        if let idx = items.firstIndex(where: {
            ($0.status == .working || $0.status == .question)
        }) {
            if let resumedAt = items[idx].resumedAt, Date().timeIntervalSince(resumedAt) < 5 {
                scheduleDeferredCompletion(sessionId: items[idx].sessionId, itemId: items[idx].id, resumedAt: resumedAt)
                return true
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                items[idx].status = .completed
            }
            scheduleCleanup()
            return true
        }
        return false
    }

    func markOldestWorking() {
        if let idx = items.firstIndex(where: { $0.status == .working || $0.status == .question }) {
            withAnimation(.easeInOut(duration: 0.25)) {
                items[idx].status = .completed
            }
            scheduleCleanup()
        }
    }

    func markQuestion(sessionId: String) {
        if let idx = items.lastIndex(where: { $0.sessionId == sessionId && $0.status == .working }) {
            withAnimation(.easeInOut(duration: 0.25)) {
                items[idx].status = .question
            }
        } else if let idx = items.lastIndex(where: { $0.status == .working }) {
            withAnimation(.easeInOut(duration: 0.25)) {
                items[idx].status = .question
            }
        }
    }

    func updateTool(sessionId: String, tool: String) {
        if let idx = items.lastIndex(where: { $0.sessionId == sessionId && $0.status == .working }) {
            items[idx].currentTool = tool
        } else if let idx = items.lastIndex(where: { $0.status == .working }) {
            items[idx].currentTool = tool
        }
    }

    static func iconForTool(_ tool: String) -> String {
        let name = tool.lowercased()
        if name.contains("read") { return "doc.text.magnifyingglass" }
        if name.contains("edit") { return "pencil.line" }
        if name.contains("write") { return "doc.badge.plus" }
        if name.contains("grep") || name.contains("search") { return "magnifyingglass" }
        if name.contains("glob") { return "folder.fill" }
        if name.contains("bash") || name.contains("terminal") { return "terminal" }
        if name.contains("mcp") { return "puzzlepiece.extension" }
        if name.contains("list") && name.contains("file") { return "folder" }
        if name.contains("web") || name.contains("fetch") { return "globe" }
        return "wrench"
    }

    func markResumed(sessionId: String) {
        if let idx = items.lastIndex(where: { $0.sessionId == sessionId && $0.status == .question }) {
            withAnimation(.easeInOut(duration: 0.25)) {
                items[idx].status = .working
                items[idx].resumedAt = Date()
            }
        }
    }

    func confirmWorking(sessionId: String) {
        deferredCompletionTasks[sessionId]?.cancel()
        deferredCompletionTasks.removeValue(forKey: sessionId)
        if let idx = items.lastIndex(where: { $0.sessionId == sessionId && $0.status == .working }) {
            items[idx].resumedAt = nil
        }
    }

    private func scheduleDeferredCompletion(sessionId: String, itemId: Int, resumedAt: Date) {
        deferredCompletionTasks[sessionId]?.cancel()
        deferredCompletionTasks[sessionId] = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            if let idx = items.firstIndex(where: { $0.id == itemId && $0.status == .working && $0.resumedAt == resumedAt }) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    items[idx].status = .completed
                }
                scheduleCleanup()
            }
            deferredCompletionTasks.removeValue(forKey: sessionId)
        }
    }

    var hasActiveItems: Bool {
        items.contains { $0.status == .working || $0.status == .question }
    }

    var hasWorkingItems: Bool {
        items.contains { $0.status == .working }
    }

    var hasQuestionItems: Bool {
        items.contains { $0.status == .question }
    }

    var workingCount: Int {
        items.filter { $0.status == .working }.count
    }

    var activeCount: Int {
        items.filter { $0.status == .working || $0.status == .question }.count
    }

    func minimize() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isMinimized = true
        }
    }

    func expand() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isMinimized = false
        }
        minimizeTask?.cancel()
    }

    private func scheduleMinimize() {
        minimizeTask?.cancel()
        minimizeTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                isMinimized = true
            }
        }
    }

    private func scheduleCleanup() {
        cleanupTask?.cancel()
        cleanupTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                items.removeAll { $0.status == .completed }
            }
        }
    }
}
