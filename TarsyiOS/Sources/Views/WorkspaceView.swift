import SwiftUI
import TarsyShared
import PhotosUI
import UniformTypeIdentifiers

private extension View {
    @ViewBuilder
    func if_iOS26GlassEffect() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else {
            self
                .background(TarsyTheme.backgroundSecondary)
                .cornerRadius(20)
        }
    }
}

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
    @State private var showFileExplorer = false
    @State private var showMCPStore = false
    @State private var checkpointFeedback: String? = nil
    @State private var isRecording = false
    @StateObject private var voiceInput = VoiceInputManager()
    @StateObject private var todoManager = VoiceTodoManager()
    @StateObject private var streamViewModel = MJPEGStreamViewModel()
    @State private var engineModel = ""
    @State private var contextPercent: Double = 0
    @State private var currentBranch = ""
    @State private var detectedAgents: [AIEngineType] = AIEngineType.allCases.filter { $0 != .custom }
    @State private var viewMode: ViewMode = .browser
    @State private var showSessionPicker = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardAnimation: Animation = .easeInOut(duration: 0.25)

    private enum ViewMode: String {
        case browser, stream
    }

    // Per-tab state isolation
    private struct TabState {
        var isThinking = false
        var activity: String? = nil
        var options: [InteractiveOption]? = nil
        var questions: [InteractiveQuestion]? = nil
        var engineModel = ""
        var contextPercent: Double = 0
    }
    @State private var tabStates: [String: TabState] = [:]

    /// Returns true if the packet's sessionId matches the currently active tab
    private func isActiveTabSession(_ packet: WSPacket) -> Bool {
        let sid = packet.payload?["sessionId"] ?? ""
        return sid.isEmpty || sid == currentTab.sessionId
    }

    /// Find tabId for a given sessionId
    private func tabId(forSession sessionId: String) -> String? {
        tabs.first(where: { $0.sessionId == sessionId })?.id
    }

    /// Update stored state for a background tab
    private func updateBackgroundTabState(sessionId: String, update: (inout TabState) -> Void) {
        guard let tabId = tabId(forSession: sessionId) else { return }
        var state = tabStates[tabId] ?? TabState()
        update(&state)
        tabStates[tabId] = state
    }

    private var currentTab: TerminalTab {
        tabs[selectedTabIndex]
    }

    private var activeSessionIdBinding: Binding<String?> {
        Binding(
            get: { tabs[selectedTabIndex].sessionId },
            set: { tabs[selectedTabIndex].sessionId = $0 }
        )
    }

    private func handleSessionCreated(_ sessionId: String) {
        tabs[selectedTabIndex].sessionId = sessionId
    }

    @FocusState private var isInputFocused: Bool

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Stream area — collapses when keyboard is up
                if keyboardHeight == 0 {
                    if workspace.stack == .web || workspace.stack == .fullstack {
                        if viewMode == .browser {
                            WebBrowserView(
                                workspace: workspace,
                                onScreenshot: { image in
                                    let data = image.jpegData(compressionQuality: 0.8)
                                    attachments.append(Attachment(
                                        name: "screenshot",
                                        type: .image,
                                        thumbnail: image,
                                        data: data
                                    ))
                                },
                                activeSessionId: activeSessionIdBinding,
                                activeEngineType: currentTab.engineType ?? .claude,
                                onSessionCreated: handleSessionCreated,
                                todoManager: todoManager,
                                interactiveQuestions: $interactiveQuestions,
                                interactiveOptions: $interactiveOptions,
                                onInteractiveChoice: { sendInteractiveChoice($0) },
                                onMultiQuestionSubmit: { submitMultiQuestionAnswers($0) },
                                onVoiceMessage: { persistVoiceMessage($0) },
                                isActive: $isStreamActive
                            )
                                .frame(maxWidth: .infinity)
                                .frame(height: UIScreen.main.bounds.height * 0.35)
                                .clipped()
                        } else {
                            streamPlayerContent
                        }
                    } else {
                        streamPlayerContent
                    }

                    // Tabs bar
                    tabBar

                    Divider().background(TarsyTheme.backgroundTertiary)
                }

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

                // View mode switch (web/fullstack only) — fade out when input is focused
                if workspace.stack == .web || workspace.stack == .fullstack {
                    viewModeSwitch
                        .opacity(isInputFocused ? 0 : 1)
                        .animation(isInputFocused ? .easeOut(duration: 0.12) : .easeIn(duration: 0.4), value: isInputFocused)
                        .allowsHitTesting(!isInputFocused)
                }

                // Input bar
                inputBar
                    .padding(.bottom, isInputFocused ? max(keyboardHeight - 34, 0) : 0)
            }
            .ignoresSafeArea(.keyboard)
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
        .sheet(isPresented: $showFileExplorer) {
            FileExplorerView(workspace: workspace)
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $showMCPStore) {
            MCPStoreView(workspacePath: workspace.localPath)
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $showSessionPicker) {
            WorkspaceSessionPicker(workspace: workspace, detectedAgents: detectedAgents) { session, engine in
                showSessionPicker = false
                continueSessionInTab(session, engineType: engine)
            }
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
                HStack(spacing: 6) {
                    Button(action: { createCheckpoint() }) {
                        ZStack(alignment: .bottomTrailing) {
                            Image("GitCommitIcon")
                                .renderingMode(.original)
                                .resizable()
                                .frame(width: 22, height: 22)
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color(red: 0.133, green: 0.773, blue: 0.369))
                                .offset(x: -10, y: -1)
                        }
                    }

                    Menu {
                        Button(action: { showGitSheet = true }) {
                            Label("git", systemImage: "arrow.triangle.branch")
                        }
                        Button(action: { showFileExplorer = true }) {
                            Label("file explorer", systemImage: "folder")
                        }
                        Button(action: { showMCPStore = true }) {
                            Label("integrations", systemImage: "puzzlepiece.extension")
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            let info = notification.userInfo
            let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.3
            let curveRaw = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
            let animation: Animation = curveRaw == 7
                ? .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)
                : .easeOut(duration: duration)
            keyboardAnimation = animation
            if let frame = info?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                withAnimation(animation) {
                    keyboardHeight = frame.height
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            let info = notification.userInfo
            let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.3
            let curveRaw = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
            let animation: Animation = curveRaw == 7
                ? .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)
                : .easeOut(duration: duration)
            withAnimation(animation) {
                keyboardHeight = 0
            }
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
                            // Save current tab state
                            let currentTab = tabs[selectedTabIndex]
                            tabStates[currentTab.id] = TabState(
                                isThinking: isAgentThinking,
                                activity: agentActivity,
                                options: interactiveOptions,
                                questions: interactiveQuestions,
                                engineModel: engineModel,
                                contextPercent: contextPercent
                            )
                            // Switch tab
                            selectedTabIndex = index
                            // Restore new tab state
                            let restored = tabStates[tab.id] ?? TabState()
                            isAgentThinking = restored.isThinking
                            agentActivity = restored.activity
                            interactiveOptions = restored.options
                            interactiveQuestions = restored.questions
                            engineModel = restored.engineModel
                            contextPercent = restored.contextPercent
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
                    Menu {
                        ForEach(detectedAgents, id: \.self) { engine in
                            Button(action: { addEngineTab(engine) }) {
                                Label(engine.displayName, systemImage: engine.iconName)
                            }
                        }
                    } label: {
                        Label("New chat", systemImage: "plus.bubble")
                    }

                    Button(action: { showSessionPicker = true }) {
                        Label("Continue session", systemImage: "clock.arrow.circlepath")
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
                    // Load older messages
                    if chatService.hasMoreMessages {
                        Button {
                            Task { await chatService.loadOlderMessages() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.circle")
                                    .font(.system(size: 12))
                                Text("load earlier messages")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .foregroundColor(TarsyTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .id("load-more")
                    }

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

        if let sessionId = currentTab.sessionId {
            todoManager.markResumed(sessionId: sessionId)
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

        if let sessionId = currentTab.sessionId {
            todoManager.markResumed(sessionId: sessionId)
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

    private var streamPlayerContent: some View {
        StreamPlayerView(
            viewModel: streamViewModel,
            workspace: workspace,
            isActive: $isStreamActive,
            onScreenshot: { image in
                let data = image.jpegData(compressionQuality: 0.8)
                attachments.append(Attachment(name: "screenshot", type: .image, thumbnail: image, data: data))
            },
            activeSessionId: activeSessionIdBinding,
            activeEngineType: currentTab.engineType ?? .claude,
            onSessionCreated: handleSessionCreated,
            todoManager: todoManager,
            interactiveQuestions: $interactiveQuestions,
            interactiveOptions: $interactiveOptions,
            onInteractiveChoice: { sendInteractiveChoice($0) },
            onMultiQuestionSubmit: { submitMultiQuestionAnswers($0) },
            onVoiceMessage: { persistVoiceMessage($0) }
        )
            .frame(maxWidth: .infinity)
            .frame(height: UIScreen.main.bounds.height * 0.35)
            .clipped()
    }

    private var viewModeSwitch: some View {
        HStack(spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { viewMode = .browser } }) {
                HStack(spacing: 4) {
                    Image(systemName: "iphone")
                        .font(.system(size: 10))
                    Text("browser")
                        .font(.system(size: 11, design: .monospaced))
                }
                    .foregroundColor(viewMode == .browser ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { viewMode = .stream }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "display")
                        .font(.system(size: 10))
                    Text("stream")
                        .font(.system(size: 11, design: .monospaced))
                }
                    .foregroundColor(viewMode == .stream ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
        }
        .background(
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 12)
                    .fill(TarsyTheme.backgroundTertiary)
                    .frame(width: geo.size.width / 2, height: geo.size.height)
                    .offset(x: viewMode == .browser ? 0 : geo.size.width / 2)
                    .animation(.easeInOut(duration: 0.2), value: viewMode)
            }
        )
        .background(TarsyTheme.backgroundSecondary.opacity(0.9))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        .padding(.horizontal, 12)
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

            // Input bar
            VStack(spacing: 0) {
                // Text field
                TextField("", text: $messageText, prompt: Text("send a command...").foregroundColor(TarsyTheme.textSecondary.opacity(0.35)), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .lineLimit(1...5)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    .focused($isInputFocused)
                    .onSubmit { sendMessage() }

                // Action buttons row
                HStack(spacing: 4) {
                    Button(action: { showAttachmentPicker.toggle() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .frame(width: 36, height: 36)
                    }

                    Spacer()

                    if isRecording {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(TarsyTheme.accentTerracotta)
                                .frame(width: 6, height: 6)
                                .opacity(recDotVisible ? 1 : 0.15)
                            Text(recordingTimerText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(TarsyTheme.accentTerracotta)
                                .monospacedDigit()
                        }
                        .transition(.opacity)
                    }

                    // Voice tasks button (left of mic)
                    if todoManager.hasActiveItems {
                        Button { todoManager.isMinimized ? todoManager.expand() : todoManager.minimize() } label: {
                            ZStack {
                                if todoManager.hasQuestionItems {
                                    Image(systemName: "questionmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(TarsyTheme.accentAmber)
                                } else if let tool = todoManager.items.last(where: { $0.status == .working })?.currentTool {
                                    Image(systemName: VoiceTodoManager.iconForTool(tool))
                                        .font(.system(size: 14))
                                        .foregroundColor(TarsyTheme.accentAmber)
                                } else {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .tint(TarsyTheme.accentAmber)
                                }
                            }
                            .frame(width: 32, height: 32)
                            .background(TarsyTheme.accentAmber.opacity(0.15))
                            .cornerRadius(16)
                            .overlay(
                                Group {
                                    if todoManager.activeCount > 1 {
                                        Text("\(todoManager.activeCount)")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundColor(.white)
                                            .frame(width: 16, height: 16)
                                            .background(TarsyTheme.accentAmber)
                                            .clipShape(Circle())
                                            .offset(x: 10, y: -10)
                                    }
                                }
                            )
                        }
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }

                    Image(systemName: isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 16))
                        .foregroundColor(isRecording ? TarsyTheme.accentTerracotta : TarsyTheme.textSecondary)
                        .frame(width: 36, height: 36)
                        .gesture(
                            LongPressGesture(minimumDuration: 0.15)
                                .onEnded { _ in startVoiceInput() }
                                .sequenced(before: DragGesture(minimumDistance: 0)
                                    .onEnded { _ in stopVoiceInput() }
                                )
                        )

                    Button(action: { sendMessage() }) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(canSend ? TarsyTheme.backgroundPrimary : TarsyTheme.textSecondary.opacity(0.5))
                            .frame(width: 32, height: 32)
                            .background(canSend ? TarsyTheme.accentAmber : TarsyTheme.backgroundSecondary)
                            .cornerRadius(16)
                    }
                    .disabled(!canSend)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .animation(.easeInOut(duration: 0.2), value: isRecording)
                .animation(.easeInOut(duration: 0.25), value: todoManager.hasActiveItems)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isRecording ? TarsyTheme.accentAmber : Color.clear, lineWidth: 1.5)
            )
            .if_iOS26GlassEffect()
            .overlay(alignment: .bottomTrailing) {
                if !todoManager.isMinimized && !todoManager.items.isEmpty {
                    VoiceTodoOverlay(todoManager: todoManager)
                        .padding(.trailing, 10)
                        .padding(.bottom, 52)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Info bar
            HStack(spacing: 0) {
                // Branch + pull
                Button(action: { pullBranch() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                        Text(currentBranch.isEmpty ? workspace.currentBranch ?? "main" : currentBranch)
                            .lineLimit(1)
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8))
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(TarsyTheme.textSecondary)
                }

                Text("  |  ")
                    .font(.system(size: 11))
                    .foregroundColor(TarsyTheme.textSecondary.opacity(0.3))

                // Engine + model
                HStack(spacing: 3) {
                    Image(systemName: currentTab.engineType?.iconName ?? "brain.head.profile")
                        .font(.system(size: 10))
                    Text(engineDisplayName)
                        .lineLimit(1)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(TarsyTheme.textSecondary)

                if contextPercent > 0 {
                    Text("  |  ")
                        .font(.system(size: 11))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.3))

                    // Context %
                    Text("\(Int(contextPercent))% ctx")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(contextPercent > 80 ? TarsyTheme.accentTerracotta : TarsyTheme.textSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
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
        .confirmationDialog("Voice Language", isPresented: $showLanguagePicker, titleVisibility: .visible) {
            ForEach(VoiceInputManager.supportedLanguages, id: \.code) { lang in
                Button(lang.name) { pickLanguageAndStart(lang.code) }
            }
            Button("Cancel", role: .cancel) {}
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

    private func persistVoiceMessage(_ transcription: String) {
        let msg = ChatMessage(
            workspaceId: workspace.id,
            tabId: currentTab.id,
            role: .user,
            content: transcription
        )
        Task {
            await chatService.addMessage(msg)
        }
    }

    private func sendMessage() {
        guard !messageText.isEmpty || !attachments.isEmpty else { return }

        let text = messageText
        messageText = ""
        let sentAttachments = attachments
        attachments = []
        isInputFocused = false

        // Collect base64-encoded images from attachments
        var imageDataList: [String] = []
        for att in sentAttachments where att.type == .image {
            if let data = att.data {
                imageDataList.append(data.base64EncodedString())
            }
        }

        // Display text for chat UI
        let displayText: String
        if !sentAttachments.isEmpty {
            let attachmentNames = sentAttachments.map { att in
                att.type == .image ? "[image: \(att.name)]" : "[file: \(att.name)]"
            }.joined(separator: " ")
            displayText = text.isEmpty ? attachmentNames : "\(text) \(attachmentNames)"
        } else {
            displayText = text
        }

        let msg = ChatMessage(
            workspaceId: workspace.id,
            tabId: currentTab.id,
            role: .user,
            content: displayText
        )

        Task {
            await chatService.addMessage(msg)

            isAgentThinking = true
            print("[Chat] sendMessage: tab=\(currentTab.type), sessionId=\(currentTab.sessionId ?? "nil"), connected=\(connectionManager.isConnected), path=\(workspace.localPath)")

            // Build payload with optional images
            let messageText = text.isEmpty && !imageDataList.isEmpty ? "Here is a screenshot of the current screen." : text
            var imagesPayload: String? = nil
            if !imageDataList.isEmpty {
                // JSON array of base64 strings
                if let jsonData = try? JSONSerialization.data(withJSONObject: imageDataList),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    imagesPayload = jsonStr
                }
            }

            if currentTab.type == .claude || currentTab.type == .engine {
                let engineType = currentTab.engineType ?? .claude
                if let sessionId = currentTab.sessionId {
                    print("[Chat] Sending engineMessage to session \(sessionId)")
                    var payload = ["sessionId": sessionId, "message": messageText, "engineType": engineType.rawValue]
                    if let images = imagesPayload { payload["images"] = images }
                    connectionManager.send(WSPacket(action: .engineMessage, payload: payload))
                } else {
                    print("[Chat] Sending engineCreate type=\(engineType.rawValue) path=\(workspace.localPath)")
                    var payload = [
                        "path": workspace.localPath,
                        "engineType": engineType.rawValue,
                        "aiContext": workspace.aiContext ?? "",
                        "message": messageText
                    ]
                    if let images = imagesPayload { payload["images"] = images }
                    connectionManager.send(WSPacket(action: .engineCreate, payload: payload))
                }
            } else if currentTab.type == .openclaw {
                connectionManager.send(WSPacket(
                    action: .openclawMessage,
                    payload: ["message": messageText]
                ))
            } else {
                if let sessionId = currentTab.sessionId {
                    connectionManager.send(WSPacket(
                        action: .terminalInput,
                        payload: ["sessionId": sessionId, "input": messageText]
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
        let uniqueId = "\(engineType.rawValue)-\(UUID().uuidString.prefix(8))"
        let tab = TerminalTab(id: uniqueId, title: title, isFixed: false, type: tabType, sessionId: nil, engineType: engineType)
        tabs.append(tab)
        selectedTabIndex = tabs.count - 1
        Task {
            await chatService.loadMessages(workspaceId: workspace.id, tabId: uniqueId)
        }
    }

    private func continueSessionInTab(_ session: UltraContextSession, engineType: AIEngineType? = nil) {
        let engineType = engineType ?? AIEngineType(rawValue: session.engineType ?? "claude") ?? .claude
        let uniqueId = "\(engineType.rawValue)-\(UUID().uuidString.prefix(8))"
        let title = session.displayTitle.prefix(20).description
        let tabType: TerminalTab.TabType = engineType == .claude ? .claude : .engine
        let tab = TerminalTab(id: uniqueId, title: title, isFixed: false, type: tabType, sessionId: nil, engineType: engineType)
        tabs.append(tab)
        selectedTabIndex = tabs.count - 1

        let contextSummary = session.messages
            .suffix(10)
            .map { "[\($0.role)] \($0.content)" }
            .joined(separator: "\n")
        let message = "Continue the following session. Here's the recent context:\n\n\(contextSummary)"

        connectionManager.send(WSPacket(
            action: .engineCreate,
            payload: [
                "workspacePath": workspace.localPath,
                "workspaceId": workspace.id.uuidString,
                "engineType": engineType.rawValue,
                "message": String(message.prefix(4000)),
                "tabId": uniqueId
            ]
        ))
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
                    let sid = packet.payload?["sessionId"] ?? currentTab.sessionId ?? ""
                    if isActiveTabSession(packet) {
                        isAgentThinking = false
                        agentActivity = nil
                        await chatService.saveLastAssistantMessage()
                    } else {
                        updateBackgroundTabState(sessionId: sid) { $0.isThinking = false; $0.activity = nil }
                    }
                    todoManager.markCompleted(sessionId: sid)
                case .claudeCreate:
                    if let sessionId = packet.payload?["sessionId"] {
                        tabs[selectedTabIndex].sessionId = sessionId
                        for i in todoManager.items.indices where todoManager.items[i].sessionId == "pending" {
                            todoManager.items[i].sessionId = sessionId
                        }
                    }
                case .claudeAskUser:
                    handleEngineAskUser(packet)

                // Multi-engine events
                case .engineOutput:
                    handleEngineOutput(packet)
                case .engineComplete:
                    let eSid = packet.payload?["sessionId"] ?? currentTab.sessionId ?? ""
                    todoManager.markCompleted(sessionId: eSid)
                    if isActiveTabSession(packet) {
                        isAgentThinking = false
                        agentActivity = nil
                        await chatService.saveLastAssistantMessage()
                    } else {
                        updateBackgroundTabState(sessionId: eSid) { $0.isThinking = false; $0.activity = nil }
                    }
                case .engineCreate:
                    if let sessionId = packet.payload?["sessionId"] {
                        tabs[selectedTabIndex].sessionId = sessionId
                        // Update pending todo items with real sessionId
                        for i in todoManager.items.indices where todoManager.items[i].sessionId == "pending" {
                            todoManager.items[i].sessionId = sessionId
                        }
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

                // Engine status (model, tokens, context %)
                case .engineStatus:
                    if let model = packet.payload?["model"] {
                        engineModel = model
                    }
                    if let input = packet.payload?["inputTokens"].flatMap({ Int($0) }),
                       let output = packet.payload?["outputTokens"].flatMap({ Int($0) }) {
                        let total = input + output
                        // Context window sizes by model family
                        let windowSize: Int
                        if engineModel.contains("opus") { windowSize = 1_000_000 }
                        else if engineModel.contains("sonnet") { windowSize = 200_000 }
                        else if engineModel.contains("haiku") { windowSize = 200_000 }
                        else { windowSize = 200_000 }
                        contextPercent = Double(total) / Double(windowSize) * 100
                    }

                // Git pull result
                case .gitPullResult:
                    if packet.payload?["success"] == "true" {
                        Haptics.success()
                    }

                // Agent detection
                case .agentsDetected:
                    if let agentsStr = packet.payload?["agents"] {
                        let types = agentsStr.split(separator: ",").compactMap { AIEngineType(rawValue: String($0)) }
                        detectedAgents = types
                    }

                // Branch update
                case .gitBranchesResult:
                    if let branch = packet.payload?["current"] {
                        currentBranch = branch
                    }

                default:
                    break
                }
            }
        }
    }

    private func handleEngineOutput(_ packet: WSPacket) {
        isAgentThinking = false
        // If we get output, the agent is working again (no longer waiting for question)
        let sessionId = packet.payload?["sessionId"] ?? currentTab.sessionId ?? ""
        todoManager.markResumed(sessionId: sessionId)
        todoManager.confirmWorking(sessionId: sessionId)
        if let output = packet.payload?["output"] {
            if output.hasPrefix("🔧") {
                let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
                agentActivity = clean
                // Extract tool name (format: "🔧 ToolName: description")
                let withoutEmoji = clean.dropFirst(2) // Remove "🔧 "
                let toolName = String(withoutEmoji.prefix(while: { $0 != ":" })).trimmingCharacters(in: .whitespaces)
                if !toolName.isEmpty {
                    todoManager.updateTool(sessionId: sessionId, tool: toolName)
                }
            } else {
                agentActivity = nil
                chatService.addAssistantChunk(workspaceId: workspace.id, tabId: currentTab.id, content: output)
            }
        }
    }

    private func handleEngineAskUser(_ packet: WSPacket) {
        isAgentThinking = false
        let sessionId = packet.payload?["sessionId"] ?? currentTab.sessionId ?? ""
        todoManager.markQuestion(sessionId: sessionId)
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

    private var engineDisplayName: String {
        let engine = currentTab.engineType ?? .claude
        if engineModel.isEmpty { return engine.displayName }
        // Shorten model name: "claude-opus-4-6-20260301" -> "Opus 4.6"
        let model = engineModel
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "20\\d{6}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .capitalized
        return model.isEmpty ? engine.displayName : model
    }

    private func pullBranch() {
        Haptics.light()
        connectionManager.send(WSPacket(action: .gitPull, payload: ["path": workspace.localPath]))
    }

    // MARK: - Voice Input

    @State private var textBeforeVoice = ""
    @State private var showLanguagePicker = false
    @State private var recordingSeconds = 0
    @State private var recordingTimer: Timer?
    @State private var recDotVisible = true

    private var recordingTimerText: String {
        let m = recordingSeconds / 60
        let s = recordingSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func startVoiceInput() {
        textBeforeVoice = messageText
        voiceInput.startRecording { transcription in
            messageText = textBeforeVoice + (textBeforeVoice.isEmpty ? "" : " ") + transcription
        }
        if voiceInput.needsLanguageSelection {
            showLanguagePicker = true
        } else {
            isRecording = true
            recordingSeconds = 0
            recDotVisible = true
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in
                    recordingSeconds += 1
                    recDotVisible.toggle()
                }
            }
            Haptics.light()
        }
    }

    private func stopVoiceInput() {
        guard isRecording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        voiceInput.stopRecording()
        isRecording = false
        Haptics.light()
    }

    private func pickLanguageAndStart(_ code: String) {
        voiceInput.setLanguage(code)
        voiceInput.needsLanguageSelection = false
        showLanguagePicker = false
        voiceInput.startRecording { transcription in
            messageText = textBeforeVoice + (textBeforeVoice.isEmpty ? "" : " ") + transcription
        }
        isRecording = true
        Haptics.light()
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
