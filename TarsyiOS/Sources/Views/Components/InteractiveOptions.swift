import SwiftUI

struct InteractiveOption: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let style: OptionStyle

    enum OptionStyle {
        case primary
        case secondary
        case numbered
    }
}

struct InteractiveOptionsView: View {
    let options: [InteractiveOption]
    let onSelect: (InteractiveOption) -> Void

    var body: some View {
        VStack(spacing: 6) {
            if options.count <= 3 && options.contains(where: { $0.style != .numbered }) {
                // Yes/No style — compact horizontal
                HStack(spacing: 6) {
                    ForEach(options) { option in
                        Button(action: { onSelect(option) }) {
                            Text(option.label)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(option.style == .primary ? TarsyTheme.backgroundPrimary : TarsyTheme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(option.style == .primary ? TarsyTheme.accentAmber : TarsyTheme.backgroundTertiary)
                                .cornerRadius(6)
                        }
                    }
                }
            } else {
                // Multiple options — vertical list
                ForEach(options) { option in
                    Button(action: { onSelect(option) }) {
                        Text(option.label)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(TarsyTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(TarsyTheme.backgroundTertiary)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(TarsyTheme.accentAmber.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InteractiveParser {
    static func parse(_ text: String) -> [InteractiveOption]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

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

        if trimmed.contains("proceed?") || trimmed.contains("continue?") || trimmed.contains("confirm?") {
            return [
                InteractiveOption(label: "Yes", value: "y", style: .primary),
                InteractiveOption(label: "No", value: "n", style: .secondary)
            ]
        }

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
