import SwiftUI
import TarsyShared

// MARK: - Terminal Inline Text Field

/// A UITextField embedded in the terminal that looks like part of the terminal output.
/// Captures keyboard input with a blinking cursor, sends full lines on Return.
private struct TerminalInputField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isActive: Bool
    var onSubmit: (String) -> Void

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.delegate = context.coordinator
        tf.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tf.textColor = UIColor(TarsyTheme.textPrimary)
        tf.tintColor = UIColor(TarsyTheme.textPrimary)
        tf.backgroundColor = .clear
        tf.borderStyle = .none
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.spellCheckingType = .no
        tf.smartQuotesType = .no
        tf.smartDashesType = .no
        tf.smartInsertDeleteType = .no
        tf.keyboardType = .default
        tf.keyboardAppearance = .dark
        tf.returnKeyType = .send
        tf.inputAssistantItem.leadingBarButtonGroups = []
        tf.inputAssistantItem.trailingBarButtonGroups = []
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Invisible placeholder
        tf.attributedPlaceholder = NSAttributedString(
            string: "command...",
            attributes: [
                .foregroundColor: UIColor(TarsyTheme.textSecondary.opacity(0.3)),
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            ]
        )

        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if isActive && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isActive && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        let parent: TerminalInputField

        init(parent: TerminalInputField) {
            self.parent = parent
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            DispatchQueue.main.async {
                self.parent.text = textField.text ?? ""
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            let command = textField.text ?? ""
            guard !command.isEmpty else { return false }
            parent.onSubmit(command)
            textField.text = ""
            DispatchQueue.main.async {
                self.parent.text = ""
            }
            return false
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async {
                self.parent.isActive = true
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            DispatchQueue.main.async {
                self.parent.isActive = false
            }
        }
    }
}

// MARK: - Terminal Completion Item

struct TerminalCompletion: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let type: CompletionType // dir, file, or cmd

    enum CompletionType: String {
        case dir, file, cmd
    }

    var icon: String {
        switch type {
        case .dir: return "folder.fill"
        case .file: return "doc.fill"
        case .cmd: return "terminal.fill"
        }
    }

    var iconColor: Color {
        switch type {
        case .dir: return TarsyTheme.accentAmber
        case .file: return TarsyTheme.textSecondary
        case .cmd: return TarsyTheme.textPrimary
        }
    }
}

// MARK: - Terminal Content View

struct TerminalContentView: View {
    let workspace: Workspace
    @ObservedObject var chatService: ChatService
    var onSendCommand: (String) -> Void
    var onRequestCompletion: (String) -> Void
    var onClearCompletions: () -> Void
    var completions: [TerminalCompletion]
    var isCompletionLoading: Bool

    @State private var inputText = ""
    @State private var isKeyboardActive = false
    /// Tracks whether completions are currently visible (to clear on next input change)
    @State private var hadCompletions = false

    /// Terminal output split into lines for lazy rendering.
    /// ANSI codes are already stripped at receive time in WorkspaceView.
    private var terminalLines: [TerminalLine] {
        var lines: [TerminalLine] = []
        for (index, msg) in chatService.messages.enumerated() {
            if msg.role == .user {
                lines.append(TerminalLine(id: "u\(index)", text: "$ \(msg.content)", isCommand: true))
            } else {
                // Split assistant output into individual lines for lazy rendering
                let msgLines = msg.content.components(separatedBy: "\n")
                for (lineIdx, line) in msgLines.enumerated() {
                    lines.append(TerminalLine(id: "o\(index)_\(lineIdx)", text: line, isCommand: false))
                }
            }
        }
        return lines
    }

    /// Extracts the last word from the input for completion context
    private var lastWord: String {
        let trimmed = inputText.trimmingCharacters(in: .whitespaces)
        guard let lastSpace = trimmed.lastIndex(of: " ") else { return trimmed }
        return String(trimmed[trimmed.index(after: lastSpace)...])
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Path header
                    Text(workspace.localPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    // Terminal output lines (lazily rendered)
                    ForEach(terminalLines) { line in
                        Text(line.text)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(line.isCommand ? TarsyTheme.textSecondary : TarsyTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .textSelection(.enabled)
                    }

                    // Autocomplete overlay (above prompt)
                    if isCompletionLoading {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .tint(TarsyTheme.textSecondary)
                            Text("completing...")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(TarsyTheme.textSecondary.opacity(0.6))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .id("completion-loading")
                    } else if !completions.isEmpty {
                        completionOverlay
                            .id("completions")
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Inline prompt + input
                    HStack(spacing: 0) {
                        // Tab button
                        Button(action: {
                            Haptics.light()
                            onRequestCompletion(inputText)
                        }) {
                            Text("⇥")
                                .font(.system(size: 15, weight: .medium, design: .monospaced))
                                .foregroundColor(inputText.isEmpty ? TarsyTheme.textSecondary.opacity(0.3) : TarsyTheme.textSecondary)
                                .frame(width: 28, height: 24)
                                .background(TarsyTheme.backgroundTertiary.opacity(inputText.isEmpty ? 0.3 : 0.8))
                                .cornerRadius(5)
                        }
                        .disabled(inputText.isEmpty)

                        Text(" $ ")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)

                        TerminalInputField(
                            text: $inputText,
                            isActive: $isKeyboardActive,
                            onSubmit: { command in
                                Haptics.light()
                                onSendCommand(command)
                            }
                        )
                        .frame(height: 20)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                    .id("terminal-prompt")

                    Color.clear
                        .frame(height: 1)
                        .id("terminal-bottom")
                }
            }
            .background(Color(hex: "0a0a0a"))
            .contentShape(Rectangle())
            .onTapGesture {
                isKeyboardActive = true
            }
            .onChange(of: chatService.updateCounter) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
                }
            }
            .onChange(of: chatService.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
                }
            }
            .onChange(of: isKeyboardActive) { _, active in
                if active {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("terminal-bottom", anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: completions) { _, newValue in
                hadCompletions = !newValue.isEmpty
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
                }
            }
            .onChange(of: inputText) { _, _ in
                // Clear stale completions when user types after completions were shown
                if hadCompletions {
                    hadCompletions = false
                    onClearCompletions()
                }
            }
            .onDisappear {
                isKeyboardActive = false
            }
        }
    }

    // MARK: - Completion Overlay

    private var completionOverlay: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(completions) { item in
                    Button(action: {
                        Haptics.light()
                        applyCompletion(item)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: item.icon)
                                .font(.system(size: 10))
                                .foregroundColor(item.iconColor)
                            Text(item.name)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(TarsyTheme.textPrimary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(TarsyTheme.backgroundTertiary)
                        .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Apply Completion

    private func applyCompletion(_ item: TerminalCompletion) {
        var completed = item.name
        // Append / for directories to allow continued path completion
        if item.type == .dir && !completed.hasSuffix("/") {
            completed += "/"
        }

        let word = lastWord
        // Replace from the known end position to avoid ambiguous backwards search
        if !word.isEmpty && inputText.hasSuffix(word) {
            inputText = String(inputText.dropLast(word.count)) + completed
        } else if !word.isEmpty, let range = inputText.range(of: word, options: .backwards) {
            inputText = inputText.replacingCharacters(in: range, with: completed)
        } else {
            inputText += completed
        }
    }
}

private struct TerminalLine: Identifiable {
    let id: String
    let text: String
    let isCommand: Bool
}
