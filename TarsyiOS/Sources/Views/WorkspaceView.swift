import SwiftUI
import TarsyShared
import PhotosUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    let workspace: Workspace
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var machineService: MachineService
    @EnvironmentObject var workspaceService: WorkspaceService

    @State private var selectedTabIndex = 0
    @State private var tabs: [TerminalTab] = [
        TerminalTab(id: "openclaw", title: "OpenClaw", isFixed: true, type: .openclaw),
        TerminalTab(id: "claude-1", title: "Claude Code", isFixed: false, type: .claude, sessionId: nil, engineType: .claude)
    ]
    @State private var messageText = ""
    @State private var isStreamActive = false
    @State private var isAgentThinking = false
    @State private var agentActivity: String? = nil // Current tool use activity
    @StateObject private var chatService = ChatService()
    @State private var showGitSheet = false
    @State private var checkpointFeedback: String? = nil
    @State private var isRecording = false
    @StateObject private var voiceInput = VoiceInputManager()

    private var currentTab: TerminalTab {
        tabs[selectedTabIndex]
    }

    @FocusState private var isInputFocused: Bool

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Stream area
                StreamPlayerView(workspace: workspace, isActive: $isStreamActive) { image in
                    let data = image.jpegData(compressionQuality: 0.8)
                    attachments.append(Attachment(
                        name: "screenshot",
                        type: .image,
                        thumbnail: image,
                        data: data
                    ))
                }
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.height * 0.35)

                // Tabs bar
                tabBar

                Divider().background(TarsyTheme.backgroundTertiary)

                // Chat area + floating question card
                ZStack(alignment: .bottom) {
                    chatArea

                    if let questions = interactiveQuestions {
                        PaginatedQuestionCard(
                            questions: questions,
                            onSubmitAll: { answers in
                                submitMultiQuestionAnswers(answers)
                            },
                            onDismiss: {
                                withAnimation {
                                    interactiveQuestions = nil
                                }
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .shadow(color: .black.opacity(0.3), radius: 12, y: -2)
                    }
                }

                // Input bar
                inputBar
            }
            .onTapGesture { isInputFocused = false }

            // Checkpoint feedback toast
            if let feedback = checkpointFeedback {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: feedback.contains("Saving") ? "arrow.triangle.2.circlepath" : feedback.contains("Saved") ? "checkmark.shield" : "xmark.shield")
                            .foregroundColor(feedback.contains("Failed") ? TarsyTheme.accentTerracotta : TarsyTheme.accentMoss)
                        Text(feedback)
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.textPrimary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(TarsyTheme.backgroundSecondary)
                    .cornerRadius(20)
                    .shadow(color: .black.opacity(0.3), radius: 8)
                    Spacer()
                }
                .padding(.top, 60)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeInOut, value: checkpointFeedback)
            }
        }
        .sheet(isPresented: $showGitSheet) {
            GitSafetyNetView(workspace: workspace)
                .environmentObject(connectionManager)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(workspace.status == .running ? TarsyTheme.statusRunning : TarsyTheme.statusIdle)
                        .frame(width: 8, height: 8)
                    Text(workspace.name)
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(TarsyTheme.textPrimary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { createCheckpoint() }) {
                    Image(systemName: "shield.checkered")
                        .foregroundColor(TarsyTheme.accentMoss)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: { showGitSheet = true }) {
                        Label("git safety net", systemImage: "shield.checkered")
                    }
                    NavigationLink(destination: AIContextEditorView(workspace: workspace).environmentObject(workspaceService)) {
                        Label("ai context", systemImage: "brain")
                    }
                    NavigationLink(destination: WorkspaceSettingsView(workspace: workspace).environmentObject(workspaceService)) {
                        Label("settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(TarsyTheme.accentAmber)
                }
            }
        }
        .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await chatService.loadMessages(workspaceId: workspace.id, tabId: currentTab.id)
            setupOutputHandler()
            await waitForConnectionAndStartClaude()
        }
        .onDisappear {
            cleanupHandler()
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    TabButton(
                        tab: tab,
                        isSelected: selectedTabIndex == index,
                        action: {
                            selectedTabIndex = index
                            Task {
                                await chatService.loadMessages(workspaceId: workspace.id, tabId: tab.id)
                            }
                        },
                        onClose: tab.isFixed ? nil : {
                            closeTab(at: index)
                        }
                    )
                }

                Menu {
                    Button(action: { addEngineTab(.claude) }) {
                        Label("Claude Code", systemImage: "brain.head.profile")
                    }
                    Button(action: { addEngineTab(.gemini) }) {
                        Label("Gemini CLI", systemImage: "sparkles")
                    }
                    Button(action: { addEngineTab(.codex) }) {
                        Label("Codex CLI", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Button(action: { addEngineTab(.aider) }) {
                        Label("Aider", systemImage: "wrench.and.screwdriver")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundColor(TarsyTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 8)
        }
        .background(TarsyTheme.backgroundSecondary)
    }

    // MARK: - Chat Area

    @State private var interactiveOptions: [InteractiveOption]? = nil
    @State private var interactiveQuestions: [InteractiveQuestion]? = nil

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(chatService.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    // Agent activity / thinking indicator
                    if let activity = agentActivity {
                        AgentActivityView(text: activity)
                            .id("activity")
                    } else if isAgentThinking {
                        ThinkingIndicator()
                            .id("thinking")
                    }

                    // Simple interactive options (yes/no, allow/deny from terminal)
                    if let options = interactiveOptions {
                        InteractiveOptionsView(options: options) { selected in
                            sendInteractiveChoice(selected)
                        }
                        .id("interactive-options")
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(12)
            }
            .onChange(of: chatService.messages.count) { _, _ in
                scrollToBottom(proxy)
                checkForInteractivePrompt()
            }
            .onChange(of: interactiveOptions?.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: chatService.updateCounter) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: isAgentThinking) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: agentActivity) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if interactiveOptions != nil {
                proxy.scrollTo("interactive-options", anchor: .bottom)
            } else if agentActivity != nil {
                proxy.scrollTo("activity", anchor: .bottom)
            } else if isAgentThinking {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if let last = chatService.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func checkForInteractivePrompt() {
        guard let lastMessage = chatService.messages.last,
              lastMessage.role == .assistant else {
            interactiveOptions = nil
            return
        }

        // Check the last part of the message for interactive prompts
        let lines = lastMessage.content.components(separatedBy: "\n")
        let lastLines = lines.suffix(5).joined(separator: "\n")

        if let options = InteractiveParser.parse(lastLines) {
            withAnimation { interactiveOptions = options }
        } else {
            interactiveOptions = nil
        }
    }

    private func sendInteractiveChoice(_ option: InteractiveOption) {
        withAnimation {
            interactiveOptions = nil
            interactiveQuestions = nil
        }

        let msg = ChatMessage(
            workspaceId: workspace.id,
            tabId: currentTab.id,
            role: .user,
            content: option.label
        )

        Task {
            await chatService.addMessage(msg)
            if let sessionId = currentTab.sessionId {
                isAgentThinking = true
                let engineType = currentTab.engineType?.rawValue ?? "claude"
                connectionManager.send(WSPacket(
                    action: .engineMessage,
                    payload: ["sessionId": sessionId, "message": option.label, "engineType": engineType]
                ))
            }
        }
    }

    private func submitMultiQuestionAnswers(_ answers: [String: String]) {
        withAnimation {
            interactiveQuestions = nil
            interactiveOptions = nil
        }

        // Format answers as readable text
        let answerText = answers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")

        let msg = ChatMessage(
            workspaceId: workspace.id,
            tabId: currentTab.id,
            role: .user,
            content: answerText
        )

        Task {
            await chatService.addMessage(msg)
            if let sessionId = currentTab.sessionId {
                isAgentThinking = true
                let engineType = currentTab.engineType?.rawValue ?? "claude"
                connectionManager.send(WSPacket(
                    action: .engineMessage,
                    payload: ["sessionId": sessionId, "message": answerText, "engineType": engineType]
                ))
            }
        }
    }

    // MARK: - Input Bar

    @State private var showAttachmentPicker = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var attachments: [Attachment] = []

    struct Attachment: Identifiable {
        let id = UUID()
        let name: String
        let type: AttachmentType
        let thumbnail: UIImage?
        let data: Data?

        enum AttachmentType {
            case image
            case file
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Attachments preview
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            attachmentChip(attachment)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(TarsyTheme.backgroundPrimary)
            }

            // Input row
            HStack(spacing: 8) {
                Button(action: { showAttachmentPicker.toggle() }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(TarsyTheme.textSecondary)
                }

                // Mic button
                Button(action: { toggleVoiceInput() }) {
                    Image(systemName: isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 18))
                        .foregroundColor(isRecording ? TarsyTheme.accentTerracotta : TarsyTheme.textSecondary)
                        .symbolEffect(.pulse, isActive: isRecording)
                }

                HStack(spacing: 0) {
                    TextField("", text: $messageText, prompt: Text("send a command...").foregroundColor(TarsyTheme.textSecondary.opacity(0.5)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(TarsyTheme.textPrimary)
                        .padding(.leading, 16)
                        .padding(.vertical, 10)
                        .focused($isInputFocused)
                        .onSubmit { sendMessage() }

                    Button(action: { sendMessage() }) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(canSend ? TarsyTheme.backgroundPrimary : TarsyTheme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(canSend ? TarsyTheme.accentAmber : Color.clear)
                            .cornerRadius(15)
                    }
                    .disabled(!canSend)
                    .padding(.trailing, 4)
                }
                .background(TarsyTheme.backgroundSecondary)
                .cornerRadius(22)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(TarsyTheme.backgroundPrimary)
        .confirmationDialog("Attach", isPresented: $showAttachmentPicker) {
            Button("Photo Library") { showPhotoPicker = true }
            Button("Camera") { /* TODO */ }
            Button("File") { showFilePicker = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, item in
            if let item {
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let thumb = UIImage(data: data)
                        attachments.append(Attachment(
                            name: "photo",
                            type: .image,
                            thumbnail: thumb,
                            data: data
                        ))
                    }
                    selectedPhotoItem = nil
                }
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                let data = try? Data(contentsOf: url)
                attachments.append(Attachment(
                    name: url.lastPathComponent,
                    type: .file,
                    thumbnail: nil,
                    data: data
                ))
            }
        }
    }

    private var canSend: Bool {
        !messageText.isEmpty || !attachments.isEmpty
    }

    @ViewBuilder
    private func attachmentChip(_ attachment: Attachment) -> some View {
        HStack(spacing: 6) {
            if attachment.type == .image, let thumb = attachment.thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .cornerRadius(6)
                    .clipped()
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 14))
                    .foregroundColor(TarsyTheme.accentAmber)
                    .frame(width: 32, height: 32)
                    .background(TarsyTheme.backgroundTertiary)
                    .cornerRadius(6)
            }

            Text(attachment.name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(TarsyTheme.textPrimary)
                .lineLimit(1)

            Button(action: {
                withAnimation { attachments.removeAll { $0.id == attachment.id } }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(TarsyTheme.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(10)
    }

    // MARK: - Actions

    private func sendMessage() {
        guard !messageText.isEmpty || !attachments.isEmpty else { return }

        // Build message with attachment references
        var text = messageText
        if !attachments.isEmpty {
            let attachmentNames = attachments.map { att in
                att.type == .image ? "[image: \(att.name)]" : "[file: \(att.name)]"
            }.joined(separator: " ")
            text = text.isEmpty ? attachmentNames : "\(text) \(attachmentNames)"
        }

        messageText = ""
        let sentAttachments = attachments
        attachments = []
        isInputFocused = false

        let msg = ChatMessage(
            workspaceId: workspace.id,
            tabId: currentTab.id,
            role: .user,
            content: text
        )
        // TODO: Upload sentAttachments data to Mac via WebSocket

        Task {
            await chatService.addMessage(msg)

            isAgentThinking = true
            print("[Chat] sendMessage: tab=\(currentTab.type), sessionId=\(currentTab.sessionId ?? "nil"), connected=\(connectionManager.isConnected), path=\(workspace.localPath)")

            if currentTab.type == .claude || currentTab.type == .engine {
                let engineType = currentTab.engineType ?? .claude
                if let sessionId = currentTab.sessionId {
                    print("[Chat] Sending engineMessage to session \(sessionId)")
                    connectionManager.send(WSPacket(
                        action: .engineMessage,
                        payload: ["sessionId": sessionId, "message": text, "engineType": engineType.rawValue]
                    ))
                } else {
                    print("[Chat] Sending engineCreate type=\(engineType.rawValue) path=\(workspace.localPath)")
                    connectionManager.send(WSPacket(
                        action: .engineCreate,
                        payload: [
                            "path": workspace.localPath,
                            "engineType": engineType.rawValue,
                            "aiContext": workspace.aiContext ?? "",
                            "message": text
                        ]
                    ))
                }
            } else if currentTab.type == .openclaw {
                // Send to OpenClaw via gateway
                connectionManager.send(WSPacket(
                    action: .openclawMessage,
                    payload: ["message": text]
                ))
            } else {
                // Regular terminal input
                if let sessionId = currentTab.sessionId {
                    connectionManager.send(WSPacket(
                        action: .terminalInput,
                        payload: ["sessionId": sessionId, "input": text]
                    ))
                }
            }
        }
    }

    private func waitForConnectionAndStartClaude() async {
        // Wait for WebSocket to be connected and authenticated
        var attempts = 0
        while !connectionManager.isConnected && attempts < 30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            attempts += 1
        }

        guard connectionManager.isConnected else {
            print("[Workspace] Could not connect to Mac after \(attempts) attempts")
            return
        }

        print("[Workspace] Connected! Auto-starting engine session for \(workspace.name)")

        // Find the first engine tab without a session
        if let tabIndex = tabs.firstIndex(where: { ($0.type == .claude || $0.type == .engine) && $0.sessionId == nil }) {
            selectedTabIndex = tabIndex
            let engineType = tabs[tabIndex].engineType ?? .claude
            connectionManager.send(WSPacket(
                action: .engineCreate,
                payload: [
                    "path": workspace.localPath,
                    "engineType": engineType.rawValue,
                    "aiContext": workspace.aiContext ?? ""
                ]
            ))
            print("[Workspace] Sent engineCreate type=\(engineType.rawValue) for path=\(workspace.localPath)")
        }
    }

    private func addEngineTab(_ engineType: AIEngineType) {
        let count = tabs.filter { $0.engineType == engineType || ($0.type == .claude && engineType == .claude) }.count + 1
        let tabType: TerminalTab.TabType = engineType == .claude ? .claude : .engine
        let title = count > 1 ? "\(engineType.displayName) \(count)" : engineType.displayName
        let tab = TerminalTab(id: "\(engineType.rawValue)-\(count)", title: title, isFixed: false, type: tabType, sessionId: nil, engineType: engineType)
        tabs.append(tab)
        selectedTabIndex = tabs.count - 1
    }

    private func closeTab(at index: Int) {
        let tab = tabs[index]
        if let sessionId = tab.sessionId {
            if tab.type == .claude || tab.type == .engine {
                let engineType = tab.engineType?.rawValue ?? "claude"
                connectionManager.send(WSPacket(action: .engineClose, payload: ["sessionId": sessionId, "engineType": engineType]))
            } else {
                connectionManager.send(WSPacket(action: .terminalClose, payload: ["sessionId": sessionId]))
            }
        }
        tabs.remove(at: index)
        if selectedTabIndex >= tabs.count {
            selectedTabIndex = max(0, tabs.count - 1)
        }
    }

    private func setupOutputHandler() {
        connectionManager.addListener("workspace-\(workspace.id)") { [self] packet in
            Task { @MainActor in
                switch packet.action {
                // Legacy Claude events (backward compat)
                case .claudeOutput:
                    handleEngineOutput(packet)
                case .claudeComplete:
                    isAgentThinking = false
                    agentActivity = nil
                    await chatService.saveLastAssistantMessage()
                case .claudeCreate:
                    if let sessionId = packet.payload?["sessionId"] {
                        tabs[selectedTabIndex].sessionId = sessionId
                    }
                case .claudeAskUser:
                    handleEngineAskUser(packet)

                // Multi-engine events
                case .engineOutput:
                    handleEngineOutput(packet)
                case .engineComplete:
                    isAgentThinking = false
                    agentActivity = nil
                    await chatService.saveLastAssistantMessage()
                case .engineCreate:
                    if let sessionId = packet.payload?["sessionId"] {
                        tabs[selectedTabIndex].sessionId = sessionId
                    }
                case .engineAskUser:
                    handleEngineAskUser(packet)

                // OpenClaw
                case .openclawOutput:
                    if let output = packet.payload?["output"] {
                        chatService.addAssistantChunk(workspaceId: workspace.id, tabId: "openclaw", content: output)
                    }
                case .openclawComplete:
                    await chatService.saveLastAssistantMessage()

                // Terminal
                case .terminalOutput:
                    if let output = packet.payload?["output"] {
                        chatService.addAssistantChunk(workspaceId: workspace.id, tabId: currentTab.id, content: output)
                    }

                default:
                    break
                }
            }
        }
    }

    private func handleEngineOutput(_ packet: WSPacket) {
        isAgentThinking = false
        if let output = packet.payload?["output"] {
            if output.hasPrefix("🔧") {
                let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
                agentActivity = clean
            } else {
                agentActivity = nil
                chatService.addAssistantChunk(workspaceId: workspace.id, tabId: currentTab.id, content: output)
            }
        }
    }

    private func handleEngineAskUser(_ packet: WSPacket) {
        isAgentThinking = false
        if let questionsJson = packet.payload?["questions"],
           let questionsData = questionsJson.data(using: .utf8),
           let questions = try? JSONDecoder().decode([InteractiveQuestion].self, from: questionsData) {
            if !questions.isEmpty {
                withAnimation {
                    interactiveOptions = nil
                    interactiveQuestions = questions
                }
            }
        }
    }

    // MARK: - Voice Input

    private func toggleVoiceInput() {
        if isRecording {
            voiceInput.stopRecording()
            isRecording = false
        } else {
            voiceInput.startRecording { transcription in
                messageText += transcription
            }
            isRecording = true
            Haptics.light()
        }
    }

    // MARK: - Git Safety Net

    private func createCheckpoint() {
        Haptics.medium()
        connectionManager.send(WSPacket(
            action: .gitCheckpoint,
            payload: ["path": workspace.localPath, "message": "manual checkpoint"]
        ))
        checkpointFeedback = "Saving..."

        // Listen for result
        connectionManager.addListener("git-checkpoint-\(workspace.id)") { [self] packet in
            Task { @MainActor in
                if packet.action == .gitCheckpointResult {
                    connectionManager.removeListener("git-checkpoint-\(workspace.id)")
                    if packet.payload?["success"] == "true" {
                        let files = packet.payload?["filesChanged"] ?? "0"
                        checkpointFeedback = "Saved (\(files) files)"
                        Haptics.success()
                    } else {
                        checkpointFeedback = "Failed"
                        Haptics.error()
                    }
                    // Auto-dismiss
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    checkpointFeedback = nil
                }
            }
        }
    }

    private func cleanupHandler() {
        connectionManager.removeListener("workspace-\(workspace.id)")
    }
}

// MARK: - Supporting Types

struct TerminalTab: Identifiable {
    let id: String
    let title: String
    let isFixed: Bool
    let type: TabType
    var sessionId: String?
    var engineType: AIEngineType?

    enum TabType {
        case openclaw
        case claude
        case engine
        case terminal
    }
}

struct TabButton: View {
    let tab: TerminalTab
    let isSelected: Bool
    let action: () -> Void
    let onClose: (() -> Void)?

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if tab.isFixed {
                    Image(systemName: "terminal")
                        .font(.caption2)
                }

                switch tab.type {
                case .claude:
                    Image(systemName: "brain.head.profile")
                        .font(.caption2)
                case .openclaw:
                    Image(systemName: "hand.raised")
                        .font(.caption2)
                case .engine:
                    Image(systemName: tab.engineType?.iconName ?? "terminal")
                        .font(.caption2)
                case .terminal:
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.caption2)
                }

                Text(tab.title)
                    .font(TarsyTheme.monoFontSmall)

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                }
            }
            .foregroundColor(isSelected ? TarsyTheme.accentAmber : TarsyTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? TarsyTheme.backgroundTertiary : Color.clear)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 6))
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.role == .user ? "you" : "agent")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(TarsyTheme.textSecondary.opacity(0.6))

                Text(message.content)
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(message.role == .user ? TarsyTheme.backgroundPrimary : TarsyTheme.textPrimary)
                    .padding(10)
                    .background(message.role == .user ? TarsyTheme.accentAmber : TarsyTheme.backgroundSecondary)
                    .cornerRadius(10)
                    .textSelection(.enabled)
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}
