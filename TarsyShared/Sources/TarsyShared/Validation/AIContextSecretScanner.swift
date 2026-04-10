import Foundation

/// Detects known API key / token patterns in free-text input before it is
/// written to Supabase.
///
/// This is the client-side counterpart to the CHECK constraint in
/// `supabase/migrations/032_ai_context_secret_guard.sql`. Keep the two in sync
/// — any pattern added here should also be added to the SQL constraint, and
/// vice versa.
///
/// Patterns are deliberately tuned to avoid false positives on ordinary code
/// snippets (minimum 30–40 continuous token chars, no whitespace breaks).
public enum AIContextSecretScanner {
    /// A detected provider whose credential pattern matched.
    public struct Pattern {
        public let provider: String
        public let regex: NSRegularExpression

        init(_ provider: String, _ pattern: String) {
            self.provider = provider
            // Force-try: these are compile-time constants; a failure would
            // indicate a bug in the literal, which we want to crash on in debug.
            self.regex = try! NSRegularExpression(pattern: pattern, options: [])
        }
    }

    /// Ordered list of patterns. The first match wins when reporting back to
    /// the user so the message stays concise.
    public static let patterns: [Pattern] = [
        Pattern("anthropic",   #"sk-ant-[a-zA-Z0-9_-]{20,}"#),
        Pattern("openai",      #"sk-[a-zA-Z0-9_-]{40,}"#),
        Pattern("github",      #"gh[oprsu]_[a-zA-Z0-9]{30,}"#),
        Pattern("slack",       #"xox[a-z]-[0-9a-zA-Z-]{20,}"#),
        Pattern("aws",         #"AKIA[0-9A-Z]{16}"#),
        Pattern("google",      #"AIza[a-zA-Z0-9_-]{35}"#),
        Pattern("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
    ]

    /// Returns the provider name of the first matching pattern, or nil if the
    /// input contains no recognised credential.
    public static func firstMatch(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            if pattern.regex.firstMatch(in: text, options: [], range: range) != nil {
                return pattern.provider
            }
        }
        return nil
    }
}
