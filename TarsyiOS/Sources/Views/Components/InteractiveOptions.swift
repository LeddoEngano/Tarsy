import SwiftUI

// MARK: - Data Models

struct InteractiveQuestion: Identifiable, Codable {
    let id = UUID()
    let question: String
    let header: String
    let options: [String]
    let multiSelect: Bool

    enum CodingKeys: String, CodingKey {
        case question, header, options, multiSelect
    }
}

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

// MARK: - Multi-Question Form

struct MultiQuestionFormView: View {
    let questions: [InteractiveQuestion]
    let onSubmit: ([String: String]) -> Void

    @State private var answers: [Int: String] = [:] // questionIndex -> selected option

    private var allAnswered: Bool {
        questions.indices.allSatisfy { answers[$0] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                questionCard(index: index, question: question)
            }

            // Submit button
            Button(action: { submit() }) {
                Text(allAnswered ? "submit" : "answer all questions")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(allAnswered ? TarsyTheme.backgroundPrimary : TarsyTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(allAnswered ? TarsyTheme.accentAmber : TarsyTheme.backgroundTertiary)
                    .cornerRadius(8)
            }
            .disabled(!allAnswered)
        }
    }

    @ViewBuilder
    private func questionCard(index: Int, question: InteractiveQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Question header
            if !question.header.isEmpty {
                Text(question.header.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(TarsyTheme.accentAmber)
                    .tracking(1)
            }

            Text(question.question)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(TarsyTheme.textPrimary)

            // Options
            VStack(spacing: 4) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { optIndex, option in
                    let isSelected = answers[index] == option
                    Button(action: { answers[index] = option }) {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 14))
                                .foregroundColor(isSelected ? TarsyTheme.accentAmber : TarsyTheme.textSecondary)

                            Text(option)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(TarsyTheme.textPrimary)

                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(isSelected ? TarsyTheme.accentAmber.opacity(0.1) : TarsyTheme.backgroundTertiary)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isSelected ? TarsyTheme.accentAmber : Color.clear, lineWidth: 1)
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(8)
    }

    private func submit() {
        var result: [String: String] = [:]
        for (index, question) in questions.enumerated() {
            if let answer = answers[index] {
                result[question.question] = answer
            }
        }
        onSubmit(result)
    }
}

// MARK: - Single-Question Options (for simple yes/no, allow/deny)

struct InteractiveOptionsView: View {
    let options: [InteractiveOption]
    let onSelect: (InteractiveOption) -> Void

    var body: some View {
        VStack(spacing: 6) {
            if options.count <= 3 && options.contains(where: { $0.style != .numbered }) {
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

// MARK: - Parser for terminal text prompts

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

        return nil
    }
}
