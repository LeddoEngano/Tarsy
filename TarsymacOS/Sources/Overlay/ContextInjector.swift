import AppKit
import Foundation
import TarsyShared

/// Injects UltraContext session content into the active terminal.
/// Approach: copies formatted context to clipboard and simulates Cmd+V paste.
@MainActor
final class ContextInjector {

    /// Format a session's messages into a context block and paste into the frontmost terminal.
    func inject(session: UltraContextSession, client: UltraContextClient) async {
        // Fetch full session with messages if needed
        let fullSession: UltraContextSession
        if session.messages.isEmpty {
            do {
                fullSession = try await client.getContext(id: session.id, limit: 50)
            } catch {
                #if DEBUG
                print("[ContextInjector] Failed to fetch session: \(error)")
                #endif
                return
            }
        } else {
            fullSession = session
        }

        let formatted = formatContext(session: fullSession)
        guard !formatted.isEmpty else { return }

        pasteIntoTerminal(formatted)
    }

    // MARK: - Formatting

    private func formatContext(session: UltraContextSession) -> String {
        // Build a concise context block from the session's messages (assistant only for context injection)
        let relevantMessages = session.messages.filter { $0.role == "assistant" }
        guard !relevantMessages.isEmpty else {
            // Fallback: use all messages
            return formatAllMessages(session)
        }

        var parts: [String] = []
        parts.append("--- UltraContext: \(session.displayTitle) ---")

        for msg in relevantMessages.suffix(10) { // Last 10 assistant messages
            let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                parts.append(content)
            }
        }

        parts.append("--- end context ---")
        return parts.joined(separator: "\n\n")
    }

    private func formatAllMessages(_ session: UltraContextSession) -> String {
        var parts: [String] = []
        parts.append("--- UltraContext: \(session.displayTitle) ---")

        for msg in session.messages.suffix(10) {
            let role = msg.role.uppercased()
            let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                parts.append("[\(role)] \(content)")
            }
        }

        parts.append("--- end context ---")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Paste

    private func pasteIntoTerminal(_ text: String) {
        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // Set context to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .hidSystemState)

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cghidEventTap)

            // Restore clipboard after a short delay
            if let prev = previousContents {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    pasteboard.clearContents()
                    pasteboard.setString(prev, forType: .string)
                }
            }
        }
    }
}

// MARK: - Private extension on UltraContextClient to fetch full context

private extension UltraContextClient {
    func getFullSession(id: String) async throws -> UltraContextSession {
        try await getContext(id: id, limit: 50)
    }
}
