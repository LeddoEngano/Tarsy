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

// MARK: - Paginated Question Card (Anthropic-style)

struct PaginatedQuestionCard: View {
    let questions: [InteractiveQuestion]
    let onSubmitAll: ([String: String]) -> Void
    let onDismiss: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var currentIndex: Int = 0
    @State private var singleAnswers: [Int: String] = [:]
    @State private var multiAnswers: [Int: Set<String>] = [:]
    @State private var customInputs: [Int: String] = [:]

    private var isCompact: Bool { verticalSizeClass == .compact }

    private var safeIndex: Int {
        max(0, min(currentIndex, questions.count - 1))
    }

    private var totalQuestions: Int {
        questions.count
    }

    var body: some View {
        Group {
            if questions.isEmpty {
                EmptyView()
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        let question = questions[safeIndex]
        return VStack(alignment: .leading, spacing: 0) {
            // Navigation header / dismiss
            if totalQuestions > 1 {
                navigationHeader
            } else {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(TarsyTheme.font(size: 13, weight: .medium))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, isCompact ? 8 : 14)
            }

            // Question text
            Text(question.question)
                .font(TarsyTheme.font(size: isCompact ? 13 : 15, weight: .semibold))
                .foregroundColor(TarsyTheme.textPrimary)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.top, isCompact ? 4 : 6)
                .padding(.bottom, isCompact ? 6 : 8)

            // Options (scrollable)
            ScrollView {
                optionsList(for: question)
            }
            .frame(maxHeight: isCompact ? 180 : .infinity)

            // Custom text input
            customInputField(for: question)
        }
        .frame(maxWidth: isCompact ? 400 : .infinity)
        .background(TarsyTheme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 12 : 16))
        .overlay(
            RoundedRectangle(cornerRadius: isCompact ? 12 : 16)
                .stroke(TarsyTheme.textSecondary.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Navigation Header

    private var navigationHeader: some View {
        HStack {
            Button(action: goToPrevious) {
                Image(systemName: "chevron.left")
                    .font(TarsyTheme.font(size: 14, weight: .medium))
                    .foregroundColor(currentIndex > 0 ? TarsyTheme.textPrimary : TarsyTheme.textSecondary.opacity(0.4))
            }
            .disabled(currentIndex == 0)

            Text("\(currentIndex + 1) de \(totalQuestions)")
                .font(TarsyTheme.font(size: 13, weight: .medium))
                .foregroundColor(TarsyTheme.textSecondary)

            Button(action: goToNext) {
                Image(systemName: "chevron.right")
                    .font(TarsyTheme.font(size: 14, weight: .medium))
                    .foregroundColor(currentIndex < totalQuestions - 1 ? TarsyTheme.textPrimary : TarsyTheme.textSecondary.opacity(0.4))
            }
            .disabled(currentIndex >= totalQuestions - 1)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(TarsyTheme.font(size: 13, weight: .medium))
                    .foregroundColor(TarsyTheme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isCompact ? 8 : 14)
    }

    // MARK: - Options List

    private func optionsList(for question: InteractiveQuestion) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { optIndex, option in
                if question.multiSelect {
                    multiSelectRow(option: option, optIndex: optIndex)
                } else {
                    singleSelectRow(option: option, optIndex: optIndex + 1)
                }

                if optIndex < question.options.count - 1 {
                    Divider()
                        .background(TarsyTheme.textSecondary.opacity(0.15))
                        .padding(.leading, 52)
                }
            }
        }
    }

    // MARK: - Single Select Row (numbered)

    private func singleSelectRow(option: String, optIndex: Int) -> some View {
        let idx = safeIndex
        return Button(action: {
            singleAnswers[idx] = option
            // Auto-advance or submit
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if currentIndex < totalQuestions - 1 {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentIndex += 1
                    }
                } else {
                    submitAll()
                }
            }
        }) {
            HStack(spacing: isCompact ? 8 : 12) {
                Text("\(optIndex)")
                    .font(TarsyTheme.font(size: isCompact ? 12 : 14, weight: .medium))
                    .foregroundColor(singleAnswers[idx] == option ? TarsyTheme.accentAmber : TarsyTheme.textSecondary)
                    .frame(width: isCompact ? 22 : 28)

                Text(option)
                    .font(TarsyTheme.font(size: isCompact ? 13 : 15))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Spacer()
            }
            .padding(.horizontal, isCompact ? 12 : 16)
            .padding(.vertical, isCompact ? 8 : 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Multi Select Row (checkbox)

    private func multiSelectRow(option: String, optIndex: Int) -> some View {
        let idx = safeIndex
        let selected = multiAnswers[idx]?.contains(option) ?? false

        return Button(action: {
            var current = multiAnswers[idx] ?? []
            if current.contains(option) {
                current.remove(option)
            } else {
                current.insert(option)
            }
            multiAnswers[idx] = current
        }) {
            HStack(spacing: isCompact ? 8 : 12) {
                ZStack {
                    Circle()
                        .fill(selected ? TarsyTheme.accentAmber : Color.clear)
                        .frame(width: isCompact ? 22 : 28, height: isCompact ? 22 : 28)
                        .overlay(
                            Circle()
                                .stroke(selected ? TarsyTheme.accentAmber : TarsyTheme.textSecondary.opacity(0.4), lineWidth: 2)
                        )

                    if selected {
                        Image(systemName: "checkmark")
                            .font(TarsyTheme.font(size: isCompact ? 10 : 13, weight: .bold))
                            .foregroundColor(.white)
                    }
                }

                Text(option)
                    .font(TarsyTheme.font(size: isCompact ? 13 : 15))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Spacer()
            }
            .padding(.horizontal, isCompact ? 12 : 16)
            .padding(.vertical, isCompact ? 6 : 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Custom Input Field

    private func customInputField(for question: InteractiveQuestion) -> some View {
        let idx = safeIndex
        let hasMultiSelections = !(multiAnswers[idx] ?? []).isEmpty
        let showSendButton = question.multiSelect && hasMultiSelections

        return HStack(spacing: 8) {
            Image(systemName: "paperclip")
                .font(TarsyTheme.font(size: isCompact ? 12 : 14))
                .foregroundColor(TarsyTheme.textSecondary.opacity(0.4))

            TextField("", text: Binding(
                get: { customInputs[idx] ?? "" },
                set: { customInputs[idx] = $0 }
            ), prompt: Text("Digite sua resposta...")
                .foregroundColor(TarsyTheme.textSecondary.opacity(0.4)))
                .font(TarsyTheme.font(size: isCompact ? 12 : 14))
                .foregroundColor(TarsyTheme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit {
                    handleCustomInputSubmit()
                }

            if showSendButton {
                Button(action: {
                    if currentIndex < totalQuestions - 1 {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentIndex += 1
                        }
                    } else {
                        submitAll()
                    }
                }) {
                    Circle()
                        .fill(TarsyTheme.accentAmber)
                        .frame(width: isCompact ? 26 : 32, height: isCompact ? 26 : 32)
                        .overlay(
                            Image(systemName: "arrow.up")
                                .font(TarsyTheme.font(size: isCompact ? 12 : 14, weight: .bold))
                                .foregroundColor(.white)
                        )
                }
            }
        }
        .padding(.horizontal, isCompact ? 12 : 16)
        .padding(.vertical, isCompact ? 8 : 12)
        .overlay(
            Divider()
                .background(TarsyTheme.textSecondary.opacity(0.15)),
            alignment: .top
        )
    }

    // MARK: - Navigation

    private func goToPrevious() {
        withAnimation(.easeInOut(duration: 0.25)) {
            currentIndex = max(0, currentIndex - 1)
        }
    }

    private func goToNext() {
        withAnimation(.easeInOut(duration: 0.25)) {
            currentIndex = min(totalQuestions - 1, currentIndex + 1)
        }
    }

    private func handleCustomInputSubmit() {
        let idx = safeIndex
        let text = customInputs[idx] ?? ""
        guard !text.isEmpty else { return }

        if questions[idx].multiSelect {
            multiAnswers[idx] = nil
        }
        singleAnswers[idx] = text
        customInputs[idx] = ""

        if currentIndex < totalQuestions - 1 {
            withAnimation(.easeInOut(duration: 0.25)) {
                currentIndex += 1
            }
        } else {
            submitAll()
        }
    }

    // MARK: - Submit

    private func submitAll() {
        var result: [String: String] = [:]
        for (index, question) in questions.enumerated() {
            if let custom = singleAnswers[index], !custom.isEmpty {
                result[question.question] = custom
            } else if let selections = multiAnswers[index], !selections.isEmpty {
                result[question.question] = selections.sorted().joined(separator: ", ")
            }
        }
        onSubmitAll(result)
    }
}

// MARK: - Single-Question Options (for simple yes/no, allow/deny)

struct InteractiveOptionsView: View {
    let options: [InteractiveOption]
    let onSelect: (InteractiveOption) -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isCompact: Bool { verticalSizeClass == .compact }

    var body: some View {
        VStack(spacing: 6) {
            if options.count <= 3 && options.contains(where: { $0.style != .numbered }) {
                HStack(spacing: 6) {
                    ForEach(options) { option in
                        Button(action: { onSelect(option) }) {
                            Text(option.label)
                                .font(TarsyTheme.font(size: 12, weight: .medium))
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
                            .font(TarsyTheme.font(size: 12))
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
        .frame(maxWidth: isCompact ? 400 : .infinity, alignment: .leading)
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

#if DEBUG
#Preview("PaginatedQuestionCard") {
    PaginatedQuestionCard(
        questions: [
            InteractiveQuestion(
                question: "Which files should I modify?",
                header: "File Selection",
                options: ["src/App.swift", "src/Models/User.swift", "src/Views/HomeView.swift"],
                multiSelect: true
            ),
            InteractiveQuestion(
                question: "What testing framework?",
                header: "Testing",
                options: ["XCTest", "Quick/Nimble", "Skip tests"],
                multiSelect: false
            )
        ],
        onSubmitAll: { _ in },
        onDismiss: {}
    )
    .padding()
    .background(TarsyTheme.backgroundPrimary)
    .preferredColorScheme(.dark)
}

#Preview("InteractiveOptionsView") {
    InteractiveOptionsView(
        options: [
            InteractiveOption(label: "Yes, proceed", value: "y", style: .primary),
            InteractiveOption(label: "No, cancel", value: "n", style: .secondary),
            InteractiveOption(label: "Option 1", value: "1", style: .numbered),
            InteractiveOption(label: "Option 2", value: "2", style: .numbered)
        ],
        onSelect: { _ in }
    )
    .padding()
    .background(TarsyTheme.backgroundPrimary)
    .preferredColorScheme(.dark)
}
#endif
