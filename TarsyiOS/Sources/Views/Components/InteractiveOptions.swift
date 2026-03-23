import SwiftUI

struct InteractiveOption: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let style: OptionStyle

    enum OptionStyle {
        case primary    // Yes, Allow, Accept
        case secondary  // No, Deny, Skip
        case numbered   // 1, 2, 3...
    }
}

struct InteractiveOptionsView: View {
    let options: [InteractiveOption]
    let onSelect: (InteractiveOption) -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Yes/No style (horizontal)
            if options.count <= 3 && options.contains(where: { $0.style != .numbered }) {
                HStack(spacing: 8) {
                    ForEach(options) { option in
                        Button(action: { onSelect(option) }) {
                            Text(option.label)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(option.style == .primary ? TarsyTheme.backgroundPrimary : TarsyTheme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(option.style == .primary ? TarsyTheme.accentAmber : TarsyTheme.backgroundTertiary)
                                .cornerRadius(8)
                        }
                    }
                }
            } else {
                // Numbered/multiple options (vertical)
                ForEach(options) { option in
                    Button(action: { onSelect(option) }) {
                        HStack(spacing: 8) {
                            if option.style == .numbered {
                                Text(option.value)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(TarsyTheme.accentAmber)
                                    .frame(width: 20)
                            }
                            Text(option.label)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(TarsyTheme.textPrimary)
                            Spacer()
                        }
                        .padding(10)
                        .background(TarsyTheme.backgroundTertiary)
                        .cornerRadius(6)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// Parse Claude Code interactive prompts from terminal output
struct InteractiveParser {
    static func parse(_ text: String) -> [InteractiveOption]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Yes/No prompts: [Y/n], [y/N], (y/n)
        if trimmed.contains("[Y/n]") || trimmed.contains("[y/n]") || trimmed.contains("(y/n)") {
            return [
                InteractiveOption(label: "Yes", value: "y", style: .primary),
                InteractiveOption(label: "No", value: "n", style: .secondary)
            ]
        }
        if trimmed.contains("[y/N]") {
            return [
                InteractiveOption(label: "Yes", value: "y", style: .secondary),
                InteractiveOption(label: "No", value: "N", style: .primary)
            ]
        }

        // Allow/Deny tool use
        if trimmed.lowercased().contains("allow") && trimmed.lowercased().contains("deny") {
            var options = [
                InteractiveOption(label: "Allow", value: "y", style: .primary),
                InteractiveOption(label: "Deny", value: "n", style: .secondary)
            ]
            if trimmed.lowercased().contains("always") {
                options.insert(InteractiveOption(label: "Always allow", value: "a", style: .primary), at: 1)
            }
            return options
        }

        // "Do you want to proceed?" style
        if trimmed.contains("proceed?") || trimmed.contains("continue?") || trimmed.contains("confirm?") {
            return [
                InteractiveOption(label: "Yes", value: "y", style: .primary),
                InteractiveOption(label: "No", value: "n", style: .secondary)
            ]
        }

        // Numbered options: (1) Something (2) Something
        let numberedPattern = #"\((\d+)\)\s+(.+?)(?=\(\d+\)|$)"#
        if let regex = try? NSRegularExpression(pattern: numberedPattern, options: .dotMatchesLineSeparators) {
            let matches = regex.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
            if matches.count >= 2 {
                return matches.compactMap { match -> InteractiveOption? in
                    guard let numRange = Range(match.range(at: 1), in: trimmed),
                          let labelRange = Range(match.range(at: 2), in: trimmed) else { return nil }
                    let num = String(trimmed[numRange])
                    let label = String(trimmed[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return InteractiveOption(label: label, value: num, style: .numbered)
                }
            }
        }

        return nil
    }
}
