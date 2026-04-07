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

// MARK: - Terminal Content View

struct TerminalContentView: View {
    let workspace: Workspace
    @ObservedObject var chatService: ChatService
    var onSendCommand: (String) -> Void

    @State private var inputText = ""
    @State private var isKeyboardActive = false

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

                    // Inline prompt + input
                    HStack(spacing: 0) {
                        Text("$ ")
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
            .onDisappear {
                isKeyboardActive = false
            }
        }
    }
}

private struct TerminalLine: Identifiable {
    let id: String
    let text: String
    let isCommand: Bool
}
