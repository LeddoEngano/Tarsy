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
    /// Deterministic ID derived from name + type (avoids UUID churn in SwiftUI diffing)
    var id: String { "\(type.rawValue):\(name)" }
    let name: String
    let type: CompletionType

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

    static func == (lhs: TerminalCompletion, rhs: TerminalCompletion) -> Bool {
        lhs.name == rhs.name && lhs.type == rhs.type
    }
}

// MARK: - Terminal Content View

struct TerminalContentView: View {
    let workspace: Workspace
    @ObservedObject var chatService: ChatService
    @Binding var isKeyboardActive: Bool
    /// Absolute path of the current working directory for this terminal tab.
    /// Driven by the parent so it stays in sync as the user issues `cd` commands.
    var currentDirectory: String
    var onSendCommand: (String) -> Void
    /// Called with the extracted partial word (not the full input)
    var onRequestCompletion: (String) -> Void
    var onClearCompletions: () -> Void
    var onInterrupt: () -> Void
    var completions: [TerminalCompletion]

    @State private var inputText = ""
    /// Debounce task for auto-completion requests
    @State private var debounceTask: Task<Void, Never>?
    /// Set to true when applying a completion to skip the debounce cycle
    @State private var isApplyingCompletion = false
    /// Command history index (-1 = not browsing, 0 = most recent)
    @State private var historyIndex: Int = -1
    /// Saved input before entering history browse mode
    @State private var savedInput: String = ""
    /// Cached terminal output lines (rebuilt only when messages change)
    @State private var cachedLines: [TerminalLine] = []

    /// Last path component of the current working directory for the prompt (e.g. "mobile")
    private var promptDirectory: String {
        (currentDirectory as NSString).lastPathComponent
    }

    /// Extracts the last word from the input for completion context
    private var lastWord: String {
        let trimmed = inputText.trimmingCharacters(in: .whitespaces)
        guard let lastSpace = trimmed.lastIndex(of: " ") else { return trimmed }
        return String(trimmed[trimmed.index(after: lastSpace)...])
    }

    /// Previous commands in reverse order (most recent first)
    private var commandHistory: [String] {
        chatService.messages
            .filter { $0.role == .user }
            .map { $0.content }
            .reversed()
            .filter { !$0.isEmpty }
    }

    private func historyUp() {
        let history = commandHistory
        guard !history.isEmpty else { return }
        if historyIndex == -1 {
            savedInput = inputText
        }
        let nextIndex = min(historyIndex + 1, history.count - 1)
        if nextIndex == historyIndex {
            // At boundary — give feedback
            Haptics.light()
            return
        }
        historyIndex = nextIndex
        isApplyingCompletion = true
        inputText = history[nextIndex]
    }

    private func historyDown() {
        if historyIndex < 0 {
            // At boundary — give feedback
            Haptics.light()
            return
        }
        let nextIndex = historyIndex - 1
        historyIndex = nextIndex
        isApplyingCompletion = true
        if nextIndex < 0 {
            inputText = savedInput
        } else {
            inputText = commandHistory[nextIndex]
        }
    }

    /// Rebuild cached terminal lines from messages
    private func rebuildLines() {
        var lines: [TerminalLine] = []
        for (index, msg) in chatService.messages.enumerated() {
            if msg.role == .user {
                lines.append(TerminalLine(id: "u\(index)", text: "$ \(msg.content)", isCommand: true))
            } else {
                let msgLines = msg.content.components(separatedBy: "\n")
                for (lineIdx, line) in msgLines.enumerated() {
                    lines.append(TerminalLine(id: "o\(index)_\(lineIdx)", text: line, isCommand: false))
                }
            }
        }
        cachedLines = lines
    }

    var body: some View {
        GeometryReader { geo in
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Push content to bottom when there's little output
                    // Uses flexible spacer that shrinks as content grows
                    Color.clear
                        .frame(height: max(0, geo.size.height - 80))

                    // Path header
                    Text(currentDirectory)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    // Terminal output lines (lazily rendered from cache)
                    ForEach(cachedLines) { line in
                        Text(line.text)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(line.isCommand ? TarsyTheme.textSecondary : TarsyTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .textSelection(.enabled)
                    }

                    // Autocomplete suggestions (above prompt)
                    if !completions.isEmpty {
                        completionOverlay
                            .id("completions")
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Inline prompt + input
                    HStack(spacing: 0) {
                        Text("\(promptDirectory) $ ")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .lineLimit(1)

                        TerminalInputField(
                            text: $inputText,
                            isActive: $isKeyboardActive,
                            onSubmit: { command in
                                Haptics.light()
                                historyIndex = -1
                                savedInput = ""
                                onSendCommand(command)
                            }
                        )
                        .frame(height: 20)

                        Spacer(minLength: 4)

                        // Ctrl+C + History arrows
                        HStack(spacing: 4) {
                            Button(action: {
                                Haptics.medium()
                                onInterrupt()
                            }) {
                                Text("⌃C")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(TarsyTheme.textSecondary)
                                    .frame(width: 30, height: 22)
                                    .background(TarsyTheme.backgroundTertiary.opacity(0.6))
                                    .cornerRadius(5)
                            }

                            HStack(spacing: 2) {
                                Button(action: historyUp) {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(commandHistory.isEmpty ? TarsyTheme.textSecondary.opacity(0.2) : TarsyTheme.textSecondary)
                                        .frame(width: 26, height: 22)
                                }
                                .disabled(commandHistory.isEmpty)

                                Button(action: historyDown) {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(historyIndex < 0 ? TarsyTheme.textSecondary.opacity(0.2) : TarsyTheme.textSecondary)
                                        .frame(width: 26, height: 22)
                                }
                                .disabled(historyIndex < 0)
                            }
                            .background(TarsyTheme.backgroundTertiary.opacity(0.6))
                            .cornerRadius(5)
                        }
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
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture {
                if !isKeyboardActive {
                    isKeyboardActive = true
                }
            }
            // Single scroll trigger — updateCounter fires for both new messages and chunk appends
            .onChange(of: chatService.updateCounter) { _, _ in
                rebuildLines()
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
            .onChange(of: completions) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
                }
            }
            .onChange(of: inputText) { _, newValue in
                scheduleCompletion(for: newValue)
            }
            .onAppear {
                rebuildLines()
            }
            .onDisappear {
                isKeyboardActive = false
                debounceTask?.cancel()
            }
        }
        } // GeometryReader
    }

    // MARK: - Auto-completion Debounce

    private func scheduleCompletion(for input: String) {
        debounceTask?.cancel()

        // If we just applied a completion (e.g. directory), request immediately for chaining
        if isApplyingCompletion {
            isApplyingCompletion = false
            let word = lastWord
            if !word.isEmpty {
                onRequestCompletion(word)
            }
            return
        }

        let word = lastWord
        // Clear completions if input is empty or last word is too short
        if input.trimmingCharacters(in: .whitespaces).isEmpty || word.count < 2 {
            onClearCompletions()
            return
        }

        // Debounce: wait 300ms before requesting
        let partial = word
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            onRequestCompletion(partial)
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
        if item.type == .dir && !completed.hasSuffix("/") {
            completed += "/"
        }

        isApplyingCompletion = true

        let word = lastWord
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
