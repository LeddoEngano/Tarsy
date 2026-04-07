import Foundation

// MARK: - Port Extraction from Output

enum PortExtractor {

    /// Extract port from dev server output.
    /// Uses LAST match to handle "port 3000 in use, trying 3001" patterns (fixes Bug #11).
    static func extractPort(from output: String) -> Int? {
        // Ordered from most specific to least specific
        let patterns = [
            "localhost:(\\d{4,5})",
            "127\\.0\\.0\\.1:(\\d{4,5})",
            "0\\.0\\.0\\.0:(\\d{4,5})",
            "\\[::\\]:(\\d{4,5})",
            "port\\s+(\\d{4,5})",
        ]

        // Try specific patterns first (these are reliable)
        for pattern in patterns {
            if let port = lastMatch(pattern: pattern, in: output) {
                return port
            }
        }

        // Generic fallback: any :NNNN (less reliable, only if nothing else matched)
        return lastMatch(pattern: ":(\\d{4,5})", in: output)
    }

    /// Extract port from a URL string
    static func portFromUrl(_ urlString: String?) -> UInt16? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        if let port = url.port { return UInt16(port) }
        if url.scheme == "https" { return 443 }
        return 80
    }

    // MARK: - Private

    private static func lastMatch(pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // Take the LAST match — handles "port X in use, trying Y" correctly
        guard let match = matches.last,
              let range = Range(match.range(at: 1), in: text),
              let port = Int(text[range]),
              port >= 1024, port < 65535 else {
            return nil
        }
        return port
    }
}

// MARK: - Ready Signal Detector

/// Detects when a dev server has finished starting up by matching output patterns.
/// Plain struct (not actor) — mutated only within PortMonitorService actor context.
struct ReadySignalDetector: Sendable {
    private(set) var isReady = false
    private(set) var accumulatedOutput = ""

    private static let readyPatterns: [String] = [
        "ready on",
        "ready in",
        "started server on",
        "listening on",
        "localhost:",
        "127.0.0.1:",
        "compiled successfully",
        "compiled client and server",
        "webpack compiled",
        "vite",
        "Local:",
        "Network:",
        "➜",
        "started at",
        "running at",
    ]

    mutating func check(_ output: String) {
        accumulatedOutput += output
        guard !isReady else { return }
        let lower = output.lowercased()
        for pattern in Self.readyPatterns {
            if lower.contains(pattern.lowercased()) {
                isReady = true
                return
            }
        }
    }

    mutating func reset() {
        isReady = false
        accumulatedOutput = ""
    }
}

// MARK: - Conflict Detector

/// Detects port conflict messages ("address already in use") and extracts the conflicting PID.
struct ConflictDetector: Sendable {
    private(set) var conflictPID: pid_t?

    private static let pidPatterns = [
        "PID:\\s*(\\d+)",
        "pid\\s+(\\d+)",
        "kill\\s+(\\d+)",
    ]

    mutating func check(_ output: String) {
        guard conflictPID == nil else { return }
        guard output.contains("already running") || output.contains("already in use") || output.contains("EADDRINUSE") || output.contains("PID") else {
            return
        }
        for pattern in Self.pidPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let range = Range(match.range(at: 1), in: output),
               let pid = pid_t(output[range]) {
                conflictPID = pid
                return
            }
        }
    }

    mutating func reset() {
        conflictPID = nil
    }
}
