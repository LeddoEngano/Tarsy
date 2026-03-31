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

    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

private struct RoundedCornerShape: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

struct WorkspaceView: View {
    let workspace: Workspace
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var machineService: MachineService
    @EnvironmentObject var workspaceService: WorkspaceService
    @EnvironmentObject var subscriptionManager: SubscriptionManager

    @State private var selectedTabIndex = 0
    @State private var tabs: [TerminalTab] = []
    @State private var messageText = ""
    @State private var isStreamActive = false
    @State private var isBrowserActive = false
    @State private var isAgentThinking = false
    @State private var agentActivity: String? = nil // Current tool use activity
    @StateObject private var chatService = ChatService()
    private let ultraContextClient = UltraContextClient()
    @State private var showGitSheet = false
    @State private var showFileExplorer = false
    @State private var showMCPStore = false
    @State private var showPaywall = false
    @State private var importedSessionTabs: Set<String> = []
    @State private var checkpointFeedback: String? = nil
    @State private var isRecording = false
    @StateObject private var voiceInput = VoiceInputManager()
    @StateObject private var todoManager = VoiceTodoManager()
    @StateObject private var streamViewModel = StreamViewModel()
    @State private var engineModel = ""
    @State private var contextPercent: Double = 0
    @State private var currentBranch = ""
    private var detectedAgents: [AIEngineType] {
        connectionManager.detectedAgents.isEmpty ? [.claude] : connectionManager.detectedAgents
    }
    @State private var viewMode: ViewMode = .browser
    @State private var showSessionPicker = false
    @State private var showCommitConfirmation = false
    @State private var isFullscreenStream = false
    @State private var isFullscreenBrowser = false
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

    private var safeTabIndex: Int {
        guard !tabs.isEmpty else { return 0 }
        return min(selectedTabIndex, tabs.count - 1)
    }

    private var currentTab: TerminalTab {
        guard !tabs.isEmpty else {
            return TerminalTab(id: "empty", title: "", isFixed: false, type: .claude)
        }
        return tabs[safeTabIndex]
    }

    private var activeSessionIdBinding: Binding<String?> {
        Binding(
            get: {
                guard !tabs.isEmpty else { return nil }
                return tabs[safeTabIndex].sessionId
            },
            set: {
                guard !tabs.isEmpty else { return }
                tabs[safeTabIndex].sessionId = $0
            }
        )
    }

    private func handleSessionCreated(_ sessionId: String) {
        guard !tabs.isEmpty else { return }
        tabs[safeTabIndex].sessionId = sessionId
    }

    @FocusState private var isInputFocused: Bool

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if workspace.isFullScreen {
                    // OpenClaw: stream-first layout
                    openClawLayout
                } else {
                    // Standard workspace layout
                    standardLayout
                }
            }
            .ignoresSafeArea(.keyboard)
            .onTapGesture { isInputFocused = false }

            // Checkpoint feedback toast
            if let feedback = checkpointFeedback {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: feedback.contains("Saving") ? "arrow.triangle.2.circlepath" : feedback.contains("Committed") ? "checkmark" : "xmark")
                            .font(.system(size: 12, weight: .semibold))
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
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(subscriptionManager)
        }
        .sheet(isPresented: $showSessionPicker) {
            WorkspaceSessionPicker(workspace: workspace, detectedAgents: detectedAgents) { session, engine in
                showSessionPicker = false
                continueSessionInTab(session, engineType: engine)
            }
        }
        .alert("Create Checkpoint", isPresented: $showCommitConfirmation) {
            Button("Commit", role: nil) { createCheckpoint() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Save a git checkpoint of the current state?")
        }
        .navigationBarTitleDisplayMode(.inline)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Text(workspace.name)
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(TarsyTheme.textPrimary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 6) {
                    Button(action: { showCommitConfirmation = true }) {
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
                    .accessibilityLabel("Create git checkpoint")

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
                    .accessibilityLabel("More options")
                }
            }
        }
        .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            // Initialize tabs
            if tabs.isEmpty {
                // Show OpenClaw tab if installed (fixed tab, first position)
                if connectionManager.openclawAvailable {
                    tabs.append(TerminalTab(id: "openclaw", title: "OpenClaw", isFixed: true, type: .openclaw))
                }
                let preferredEngine = detectedAgents.first ?? .claude
                let tabType: TerminalTab.TabType = preferredEngine == .claude ? .claude : .engine
                tabs.append(TerminalTab(id: "\(preferredEngine.rawValue)-1", title: preferredEngine.displayName, isFixed: false, type: tabType, sessionId: nil, engineType: preferredEngine))
                // Default to engine tab
                if tabs.count > 1 {
                    selectedTabIndex = tabs.count - 1
                }
            }
            chatService.switchTab(tabId: currentTab.id)
            await chatService.loadFromUltraContext(workspacePath: workspace.localPath, client: ultraContextClient)
            setupOutputHandler()
            await waitForConnectionAndStartClaude()
        }
        .onDisappear {
            cleanupHandler()
            // Don't end activities when navigating away — agent keeps running in background.
            // Activities end naturally via engineComplete/engineError packets.
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            guard isInputFocused else { return }
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
            guard keyboardHeight > 0 else { return }
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
                            guard !tabs.isEmpty else { return }
                            let currentTab = tabs[safeTabIndex]
                            tabStates[currentTab.id] = TabState(
                                isThinking: isAgentThinking,
                                activity: agentActivity,
                                options: interactiveOptions,
                                questions: interactiveQuestions,
                                engineModel: engineModel,
                                contextPercent: contextPercent
                            )
                            // Pro gate for OpenClaw tab
                            if tab.type == .openclaw && !subscriptionManager.isPro {
                                showPaywall = true
                                return
                            }
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
                            chatService.switchTab(tabId: tab.id)
                        },
                        onClose: tab.isFixed ? nil : {
                            closeTab(at: index)
                        }
                    )
                }

                if detectedAgents.count <= 1 {
                    Menu {
                        Button(action: { addEngineTab(detectedAgents.first ?? .claude) }) {
                            Label("New chat", systemImage: "plus.bubble")
                        }

                        Button(action: { showSessionPicker = true }) {
                            Label("Import session", systemImage: "clock.arrow.circlepath")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                            .foregroundColor(TarsyTheme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                } else {
                    Menu {
                        Section("New chat") {
                            ForEach(detectedAgents, id: \.self) { engine in
                                Button(action: { addEngineTab(engine) }) {
                                    Label {
                                        Text(engine.displayName)
                                    } icon: {
                                        if let asset = engine.iconAsset {
                                            Image(asset)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 20, height: 20)
                                        } else {
                                            Image(systemName: engine.iconName)
                                                .font(.system(size: 14))
                                        }
                                    }
                                }
                            }
                        }

                        Button(action: { showSessionPicker = true }) {
                            Label("Import session", systemImage: "clock.arrow.circlepath")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                            .foregroundColor(TarsyTheme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
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

        if let sessionId = currentTab.sessionId {
            todoManager.markResumed(sessionId: sessionId)
        }
        // Resume Live Activity to running
        LiveActivityManager.shared.updateStatus(workspaceId: workspace.id.uuidString, status: "running", tabId: currentTab.id)

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
        // Resume Live Activity to running
        LiveActivityManager.shared.updateStatus(workspaceId: workspace.id.uuidString, status: "running", tabId: currentTab.id)

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
                    action: .engineUserResponse,
                    payload: ["sessionId": sessionId, "answer": answerText, "engineType": engineType]
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

    // MARK: - OpenClaw Layout (stream-first, chat as overlay)

    @State private var showOpenClawChat = false

    private var openClawLayout: some View {
        ZStack(alignment: .bottom) {
            // Full-screen stream
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
                onVoiceMessage: { persistVoiceMessage($0) },
                isFullscreen: $isFullscreenStream
            )
            .ignoresSafeArea()

            // Floating chat toggle button
            if !showOpenClawChat {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.3)) { showOpenClawChat = true }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "bubble.left.fill")
                                    .font(.system(size: 14))
                                if isAgentThinking {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .tint(TarsyTheme.backgroundPrimary)
                                }
                            }
                            .foregroundColor(TarsyTheme.backgroundPrimary)
                            .padding(14)
                            .background(TarsyTheme.accentAmber)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                    }
                }
            }

            // Collapsible chat sheet
            if showOpenClawChat {
                VStack(spacing: 0) {
                    // Handle bar + close
                    HStack {
                        Capsule()
                            .fill(TarsyTheme.textSecondary.opacity(0.3))
                            .frame(width: 36, height: 4)

                        Spacer()

                        Button {
                            withAnimation(.spring(response: 0.3)) { showOpenClawChat = false }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(TarsyTheme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    tabBar

                    Divider().background(TarsyTheme.backgroundTertiary)

                    chatArea

                    inputBar
                }
                .frame(height: max(UIScreen.main.bounds.height, UIScreen.main.bounds.width) * 0.4)
                .background(TarsyTheme.backgroundPrimary.opacity(0.95))
                .cornerRadius(20, corners: [.topLeft, .topRight])
                .shadow(color: .black.opacity(0.4), radius: 16, y: -4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .overlay(alignment: .bottomTrailing) {
                    if !todoManager.isMinimized && !todoManager.items.isEmpty {
                        VoiceTodoOverlay(todoManager: todoManager)
                            .padding(.trailing, 16)
                            .padding(.bottom, 130)
                            .allowsHitTesting(true)
                    }
                }
            }

            // Floating question card (above chat)
            if let questions = interactiveQuestions, !showOpenClawChat {
                PaginatedQuestionCard(
                    questions: questions,
                    onSubmitAll: { answers in submitMultiQuestionAnswers(answers) },
                    onDismiss: { withAnimation { interactiveQuestions = nil } }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 80)
                .frame(maxHeight: .infinity)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .shadow(color: .black.opacity(0.3), radius: 12, y: -2)
            }
        }
    }

    // MARK: - Standard Layout

    private var standardLayout: some View {
        VStack(spacing: 0) {
            // Stream area — collapses (but stays in hierarchy) when chat input is focused
            if workspace.stack == .web || workspace.stack == .fullstack {
                ZStack {
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
                        isFullscreen: $isFullscreenBrowser,
                        isActive: $isBrowserActive
                    )
                    .opacity(viewMode == .browser ? 1 : 0)
                    .allowsHitTesting(viewMode == .browser)

                    streamPlayerContent
                        .opacity(viewMode == .stream ? 1 : 0)
                        .allowsHitTesting(viewMode == .stream)
                }
                .frame(maxWidth: .infinity)
                .frame(height: keyboardHeight == 0 ? UIScreen.main.bounds.height * 0.35 : 0)
                .clipped()
            } else {
                streamPlayerContent
                    .frame(maxWidth: .infinity)
                    .frame(height: keyboardHeight == 0 ? UIScreen.main.bounds.height * 0.35 : 0)
                    .clipped()
            }

            if keyboardHeight == 0 {
                // Tabs bar
                tabBar

                Divider().background(TarsyTheme.backgroundTertiary)
            }

            ZStack {
                VStack(spacing: 0) {
                    chatArea
                    inputBar
                }

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
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: -2)
                }
            }

            infoBar
                .padding(.bottom, isInputFocused ? keyboardHeight : 0)
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .bottomTrailing) {
            if !todoManager.isMinimized && !todoManager.items.isEmpty {
                VoiceTodoOverlay(todoManager: todoManager)
                    .padding(.trailing, 16)
                    .padding(.bottom, 130)
                    .allowsHitTesting(true)
            }
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
            onVoiceMessage: { persistVoiceMessage($0) },
            isFullscreen: $isFullscreenStream
        )
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
                // Signal StreamPlayerView to auto-start if not already running
                if !isStreamActive {
                    isStreamActive = true
                }
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
    }

    private var infoBar: some View {
        VStack(spacing: 0) {
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
                    AgentIcon(engineType: currentTab.engineType ?? .claude, size: 14)
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

            // Extra space for home indicator when safe area is ignored
            if !isInputFocused {
                Color.clear.frame(height: 20)
            }
        }
        .background(TarsyTheme.backgroundPrimary)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Input bar
            VStack(spacing: 0) {
                // Text field
                ZStack(alignment: .topLeading) {
                    if messageText.isEmpty {
                        Text("send a command...")
                            .font(.system(size: 16))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.35))
                            .padding(.horizontal, 20)
                            .padding(.top, 22)
                    }
                    TextEditor(text: $messageText)
                        .font(.system(size: 16))
                        .foregroundColor(TarsyTheme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 36, maxHeight: 200)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.top, 14)
                        .padding(.bottom, 8)
                        .focused($isInputFocused)
                }

                // Action buttons row
                HStack(spacing: 4) {
                    Button(action: { showAttachmentPicker.toggle() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Add attachment")

                    Spacer()

                    if workspace.stack == .web || workspace.stack == .fullstack {
                        viewModeSwitch
                    }

                    Spacer()

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
                        .accessibilityLabel("Agent tasks")
                    }

                    HStack(spacing: 3) {
                        if isRecording {
                            Circle()
                                .fill(TarsyTheme.accentTerracotta)
                                .frame(width: 5, height: 5)
                                .opacity(recDotVisible ? 1 : 0.15)
                            Text(recordingTimerText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(TarsyTheme.accentTerracotta)
                                .monospacedDigit()
                        }
                        Image(systemName: isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 16))
                            .foregroundColor(isRecording ? TarsyTheme.accentTerracotta : TarsyTheme.textSecondary)
                            .frame(width: 36, height: 36)
                    }
                        .gesture(
                            LongPressGesture(minimumDuration: 0.15)
                                .onEnded { _ in startVoiceInput() }
                                .sequenced(before: DragGesture(minimumDistance: 0)
                                    .onEnded { _ in stopVoiceInput() }
                                )
                        )
                        .accessibilityLabel(isRecording ? "Stop recording" : "Hold to record voice")

                    Button(action: { sendMessage() }) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(canSend ? TarsyTheme.backgroundPrimary : TarsyTheme.textSecondary.opacity(0.5))
                            .frame(width: 32, height: 32)
                            .background(canSend ? TarsyTheme.accentAmber : TarsyTheme.backgroundSecondary)
                            .cornerRadius(16)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send message")
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(TarsyTheme.backgroundPrimary)
        .overlay(alignment: .topLeading) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            attachmentChip(attachment)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .fixedSize(horizontal: true, vertical: true)
                .background(
                    TarsyTheme.backgroundSecondary
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: -2)
                )
                .padding(.leading, 12)
                .offset(y: -52)
            }
        }
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
        HStack(spacing: 4) {
            if attachment.type == .image, let thumb = attachment.thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .cornerRadius(4)
                    .clipped()
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 11))
                    .foregroundColor(TarsyTheme.accentAmber)
                    .frame(width: 24, height: 24)
                    .background(TarsyTheme.backgroundTertiary)
                    .cornerRadius(4)
            }

            Text(attachment.name)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(TarsyTheme.textPrimary)
                .lineLimit(1)

            Button(action: {
                withAnimation { attachments.removeAll { $0.id == attachment.id } }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(TarsyTheme.textSecondary)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(6)
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

            // Start Live Activity when user sends a real task
            if currentTab.type == .claude || currentTab.type == .engine {
                let engine = currentTab.engineType ?? .claude
                LiveActivityManager.shared.startActivity(
                    workspaceId: workspace.id.uuidString,
                    workspaceName: workspace.name,
                    engineType: engine,
                    tabId: currentTab.id
                )
            }

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
#if DEBUG
                    print("[Chat] Sending engineMessage to session \(sessionId)")
#endif
                    var payload = ["sessionId": sessionId, "message": messageText, "engineType": engineType.rawValue]
                    if let images = imagesPayload { payload["images"] = images }
                    connectionManager.send(WSPacket(action: .engineMessage, payload: payload))
                } else {
#if DEBUG
                    print("[Chat] Sending engineCreate type=\(engineType.rawValue) path=\(workspace.localPath)")
#endif
                    let permConfig = AgentPermissionConfig.load()
                    var payload = [
                        "path": workspace.localPath,
                        "engineType": engineType.rawValue,
                        "aiContext": workspace.aiContext ?? "",
                        "message": messageText,
                        "permissionMode": permConfig.mode(for: engineType).rawValue,
                        "workspaceId": workspace.id.uuidString
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
#if DEBUG
            print("[Workspace] Could not connect to Mac after \(attempts) attempts")
#endif
            return
        }

#if DEBUG
        print("[Workspace] Connected! Auto-starting engine session for \(workspace.name)")
#endif

        // Find the first engine tab without a session
        if let tabIndex = tabs.firstIndex(where: { ($0.type == .claude || $0.type == .engine) && $0.sessionId == nil }) {
            selectedTabIndex = tabIndex
            let engineType = tabs[tabIndex].engineType ?? .claude
            connectionManager.send(WSPacket(
                action: .engineCreate,
                payload: [
                    "path": workspace.localPath,
                    "engineType": engineType.rawValue,
                    "aiContext": workspace.aiContext ?? "",
                    "workspaceId": workspace.id.uuidString
                ]
            ))
#if DEBUG
            print("[Workspace] Sent engineCreate type=\(engineType.rawValue) for path=\(workspace.localPath)")
#endif
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
        chatService.switchTab(tabId: uniqueId)

        // Connect to the agent immediately
        let permConfig = AgentPermissionConfig.load()
        connectionManager.send(WSPacket(
            action: .engineCreate,
            payload: [
                "path": workspace.localPath,
                "engineType": engineType.rawValue,
                "aiContext": workspace.aiContext ?? "",
                "permissionMode": permConfig.mode(for: engineType).rawValue,
                "workspaceId": workspace.id.uuidString
            ]
        ))
    }

    private func continueSessionInTab(_ session: UltraContextSession, engineType: AIEngineType? = nil) {
        let engineType = engineType ?? AIEngineType(rawValue: session.engineType ?? "claude") ?? .claude
        let uniqueId = "\(engineType.rawValue)-\(UUID().uuidString.prefix(8))"
        let title = session.displayTitle.prefix(20).description
        let tabType: TerminalTab.TabType = engineType == .claude ? .claude : .engine
        let tab = TerminalTab(id: uniqueId, title: title, isFixed: false, type: tabType, sessionId: nil, engineType: engineType)
        tabs.append(tab)
        selectedTabIndex = tabs.count - 1
        chatService.switchTab(tabId: uniqueId)

        // Load imported session messages into the chat
        for msg in session.messages {
            let chatMsg = ChatMessage(
                workspaceId: workspace.id,
                tabId: uniqueId,
                role: msg.role == "user" ? .user : .assistant,
                content: msg.content
            )
            Task { await chatService.addMessage(chatMsg) }
        }

        // Mark tab to suppress the first "ready" greeting from the engine
        importedSessionTabs.insert(uniqueId)

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
        chatService.removeTab(tab.id)
        if let sessionId = tab.sessionId {
            if tab.type == .claude || tab.type == .engine {
                let engineType = tab.engineType?.rawValue ?? "claude"
                connectionManager.send(WSPacket(action: .engineClose, payload: ["sessionId": sessionId, "engineType": engineType]))
            } else {
                connectionManager.send(WSPacket(action: .terminalClose, payload: ["sessionId": sessionId]))
            }
        }
        let wasSelected = selectedTabIndex == index
        tabs.remove(at: index)
        if selectedTabIndex >= tabs.count {
            selectedTabIndex = max(0, tabs.count - 1)
        } else if index < selectedTabIndex {
            selectedTabIndex -= 1
        }
        if wasSelected, !tabs.isEmpty {
            let newTab = tabs[selectedTabIndex]
            let restored = tabStates[newTab.id] ?? TabState()
            isAgentThinking = restored.isThinking
            agentActivity = restored.activity
            interactiveOptions = restored.options
            interactiveQuestions = restored.questions
            engineModel = restored.engineModel
            contextPercent = restored.contextPercent
            chatService.switchTab(tabId: newTab.id)
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

                    } else {
                        updateBackgroundTabState(sessionId: sid) { $0.isThinking = false; $0.activity = nil }
                    }
                    todoManager.markCompleted(sessionId: sid)
                case .claudeCreate:
                    if let sessionId = packet.payload?["sessionId"], !tabs.isEmpty {
                        tabs[safeTabIndex].sessionId = sessionId
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

                    } else {
                        updateBackgroundTabState(sessionId: eSid) { $0.isThinking = false; $0.activity = nil }
                    }
                    // End Live Activity (scoped to tab)
                    if let tid = tabId(forSession: eSid) {
                        LiveActivityManager.shared.endActivity(workspaceId: workspace.id.uuidString, tabId: tid)
                    } else {
                        LiveActivityManager.shared.endActivity(workspaceId: workspace.id.uuidString, tabId: currentTab.id)
                    }
                case .engineCreate:
                    if let sessionId = packet.payload?["sessionId"], !tabs.isEmpty {
                        tabs[safeTabIndex].sessionId = sessionId
                        // Update pending todo items with real sessionId
                        for i in todoManager.items.indices where todoManager.items[i].sessionId == "pending" {
                            todoManager.items[i].sessionId = sessionId
                        }
                        // NOTE: Live Activity is NOT started here — it starts when the
                        // agent actually begins working (first engineOutput after a user message).
                        // Starting here would trigger on workspace open (auto-connect).
                    }
                case .engineAskUser:
                    handleEngineAskUser(packet)

                // OpenClaw
                case .openclawOutput:
                    if let output = packet.payload?["output"] {
                        chatService.addAssistantChunk(workspaceId: workspace.id, tabId: "openclaw", content: output)
                    }
                case .openclawComplete:
                    break

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
                        LiveActivityManager.shared.updateContext(workspaceId: workspace.id.uuidString, contextPercent: contextPercent, tabId: currentTab.id)
                    }

                // Git pull result
                case .gitPullResult:
                    if packet.payload?["success"] == "true" {
                        Haptics.success()
                    }

                // Agent detection
                case .agentsDetected:
                    // Update initial tab if it has no session yet and preferred engine changed
                    if let preferred = detectedAgents.first,
                       let idx = tabs.firstIndex(where: { ($0.type == .claude || $0.type == .engine) && $0.sessionId == nil && $0.engineType != preferred }) {
                        let tabType: TerminalTab.TabType = preferred == .claude ? .claude : .engine
                        tabs[idx] = TerminalTab(id: "\(preferred.rawValue)-1", title: preferred.displayName, isFixed: false, type: tabType, sessionId: nil, engineType: preferred)
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

        // Suppress the first "ready" greeting for imported session tabs.
        // The ready message may arrive before .engineCreate assigns the sessionId to the tab,
        // so also check if the current tab (with no sessionId yet) is in the suppression set.
        let resolvedTabId = tabId(forSession: sessionId)
            ?? (isActiveTabSession(packet) ? currentTab.id : nil)
            ?? (currentTab.sessionId == nil && importedSessionTabs.contains(currentTab.id) ? currentTab.id : nil)
        if let resolvedTabId, importedSessionTabs.contains(resolvedTabId) {
            importedSessionTabs.remove(resolvedTabId)
            return
        }
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
                // Update Live Activity with current tool
                if let tool = AgentToolType.parse(from: clean) {
                    LiveActivityManager.shared.updateTool(workspaceId: workspace.id.uuidString, tool: tool, tabId: currentTab.id, contextPercent: contextPercent)
                }
            } else {
                agentActivity = nil
                chatService.addAssistantChunk(workspaceId: workspace.id, tabId: currentTab.id, content: output)
                // Parse tool from raw output too
                if let tool = AgentToolType.parse(from: output) {
                    LiveActivityManager.shared.updateTool(workspaceId: workspace.id.uuidString, tool: tool, tabId: currentTab.id, contextPercent: contextPercent)
                }
            }
        }
    }

    private func handleEngineAskUser(_ packet: WSPacket) {
        isAgentThinking = false
        let sessionId = packet.payload?["sessionId"] ?? currentTab.sessionId ?? ""
        todoManager.markQuestion(sessionId: sessionId)
        // Update Live Activity to waiting (scoped to tab) with question text for the alert
        var questionText: String?
        if let questionsJson = packet.payload?["questions"],
           let questionsData = questionsJson.data(using: .utf8),
           let questions = try? JSONDecoder().decode([InteractiveQuestion].self, from: questionsData) {
            questionText = questions.first?.question
            if !questions.isEmpty {
                withAnimation {
                    interactiveOptions = nil
                    interactiveQuestions = questions
                }
            }
        }
        LiveActivityManager.shared.updateStatus(workspaceId: workspace.id.uuidString, status: "waiting", tabId: currentTab.id, message: questionText)
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
                        checkpointFeedback = "Committed"
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
                switch tab.type {
                case .claude:
                    AgentIcon(engineType: .claude, size: 12)
                case .openclaw:
                    Text("🦞")
                        .font(.system(size: 10))
                case .engine:
                    AgentIcon(engineType: tab.engineType ?? .custom, size: 12)
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
