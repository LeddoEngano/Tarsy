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
    /// The workspace passed in at navigation time. Kept as a fallback so the
    /// view still renders if the workspaceService list hasn't been hydrated
    /// yet (or the workspace was just deleted).
    private let initialWorkspace: Workspace
    private let workspaceId: UUID

    init(workspace: Workspace) {
        self.initialWorkspace = workspace
        self.workspaceId = workspace.id
    }

    /// Live workspace lookup so changes persisted via `workspaceService`
    /// (e.g. the monorepo migration sheet) propagate to this open view
    /// without requiring the user to back out and re-navigate.
    private var workspace: Workspace {
        workspaceService.workspaces.first(where: { $0.id == workspaceId }) ?? initialWorkspace
    }

    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var machineService: MachineService
    @EnvironmentObject var workspaceService: WorkspaceService
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var badgeService: NotificationBadgeService

    @State private var selectedTabIndex = 0
    @State private var tabs: [TerminalTab] = []
    @State private var messageText = ""
    @State private var isStreamActive = false
    @State private var isBrowserActive = false
    @State private var isAgentThinking = false
    @State private var agentActivity: String? = nil // Current tool use activity
    @State private var activityLines: [String] = [] // Accumulated activity narration (📋)
    @StateObject private var chatService = ChatService()
    private let ultraContextClient = UltraContextClient()
    @State private var showGitSheet = false
    @State private var showFileExplorer = false
    @State private var showMCPStore = false
    /// Sub-projects detected by `repoAnalyze` for legacy workspaces missing
    /// a saved `subPath`. Non-empty when the migration sheet should be shown.
    @State private var pendingMonorepoProjects: [DetectedSubProject] = []
    @State private var showMonorepoMigration = false
    /// Guards against firing `repoAnalyze` more than once per appear.
    @State private var didCheckSubPath = false
    @State private var showDevTools = false
    @State private var showPaywall = false
    @State private var importedSessionTabs: Set<String> = []
    @State private var checkpointFeedback: String? = nil
    @StateObject private var voiceRecorder = VoiceRecorderController()
    @StateObject private var todoManager = VoiceTodoManager()
    @StateObject private var streamViewModel = StreamViewModel()
    @State private var engineModel = ""
    @State private var contextPercent: Double = 0
    @State private var currentBranch = ""
    private var detectedAgents: [AIEngineType] {
        connectionManager.detectedAgents
    }
    @State private var autocompleteItems: [AutocompleteItem] = []
    @State private var cachedFileEntries: [AutocompleteItem] = []
    @State private var viewMode: ViewMode = .stream
    @State private var showSessionPicker = false
    @State private var showCommitConfirmation = false
    @State private var isFullscreenStream = false
    @State private var isFullscreenBrowser = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardAnimation: Animation = .easeInOut(duration: 0.25)
    @State private var isTerminalInputActive = false

    private enum ViewMode: String {
        case stream, browser
    }

    // Per-tab state isolation
    private struct TabState {
        var isThinking = false
        var activity: String? = nil
        var activityLines: [String] = []
        var options: [InteractiveOption]? = nil
        var questions: [InteractiveQuestion]? = nil
        var engineModel = ""
        var contextPercent: Double = 0
    }
    @State private var tabStates: [String: TabState] = [:]
    /// Maps WSPacket.id → tab.id for pending engineCreate requests
    @State private var pendingCreateRequests: [String: String] = [:]
    /// Queued commands for terminal tabs whose session hasn't been created yet
    @State private var pendingTerminalCommands: [String: String] = [:]
    /// Autocomplete results for the terminal tab
    @State private var terminalCompletions: [TerminalCompletion] = []
    /// Tracks which tab requested the current completions (discard stale responses)
    @State private var completionRequestTabId: String = ""
    /// Current working directory per terminal tab (tabId → absolute path).
    /// Updated client-side by parsing `cd` commands the user issues.
    @State private var terminalCwds: [String: String] = [:]
    /// Tab IDs for terminal tabs that currently have a command executing.
    /// Set on command submit and cleared when the macOS daemon emits a
    /// `terminalPromptReady` packet — the sentinel-driven signal that
    /// replaced the old silence-timer heuristic (which misfired on
    /// commands with quiet stretches like `npx expo run:ios`).
    @State private var runningTerminals: Set<String> = []

    // MARK: - Build & Hot Reload State
    @State private var buildOutput: [String] = []
    @State private var buildPhase: String = ""
    @State private var buildPercent: Int = 0
    @State private var hotReloadStatus: String = "idle"
    @State private var lastInjectedFile: String = ""
    @State private var hotReloadInjectionCount: Int = 0
    @State private var isBuildRunning: Bool = false
    /// One-shot trigger consumed by `BuildRunView.onChange` to auto-start a
    /// build immediately after the tab opens. Set to true by the bottom-bar
    /// quick-action; reset to false by `BuildRunView` once the build kicks
    /// off so the next openBuildAndRun click can re-fire it.
    @State private var autoStartBuild: Bool = false
    /// Simulator devices reported by the macOS daemon in response to
    /// `simulatorList` requests. Populated on first workspace appear so
    /// the Build & Run picker menu has something to show.
    @State private var availableSimulators: [SimulatorDevice] = []
    /// UDID of the simulator the user wants the next Build & Run to target.
    /// Nil = "let macOS pick" (first booted, fall back to first available).
    /// Persisted to `workspace.config["preferredSimulator"]` via the save
    /// path so reopening the workspace restores the choice.
    @State private var selectedSimulatorUDID: String? = nil

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
            .onTapGesture {
                isInputFocused = false
                // Also dismiss terminal keyboard via responder chain
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }

            // Checkpoint feedback toast
            if let feedback = checkpointFeedback {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: feedback.contains("Saving") ? "arrow.triangle.2.circlepath" : feedback.contains("Committed") ? "checkmark" : "xmark")
                            .font(TarsyTheme.font(size: 12, weight: .semibold))
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
            MCPStoreView(workspacePath: workspace.effectivePath)
                .environmentObject(connectionManager)
        }
        .sheet(isPresented: $showDevTools) {
            DevToolsView(workspace: workspace)
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
        .sheet(isPresented: $showMonorepoMigration) {
            MonorepoMigrationSheet(workspace: workspace, projects: pendingMonorepoProjects)
                .environmentObject(workspaceService)
                .environmentObject(connectionManager)
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
                                .font(TarsyTheme.font(size: 8, weight: .bold))
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
                        Button(action: { showDevTools = true }) {
                            Label("devtools", systemImage: "wrench.and.screwdriver")
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
            configureVoiceRecorder()
            await badgeService.clearBadge(for: workspace.id)

            // Legacy workspaces created before sub-path / framework
            // persistence shipped need a one-time backfill on open. Two
            // independent triggers:
            //   1. `subPath` was never resolved → user might still need
            //      to pick a sub-project for monorepo workspaces.
            //   2. `framework` is missing → `isSwiftMobile` falls back to
            //      `stack==.mobile` and falsely shows the Build & Run tab
            //      for React Native / Expo projects whose stack was
            //      tagged "mobile" but never got a framework string saved.
            // Re-running `repoAnalyze` covers both cases — it returns
            // root-level language/framework AND the sub-project list.
            let needsBackfill = !workspace.subPathConfigured || workspace.framework == nil
            if needsBackfill && !didCheckSubPath {
                didCheckSubPath = true
                await checkForMonorepoMigration()
            }

            // Wait for agent detection before initializing tabs.
            // The macOS app sends .agentsDetected after WebSocket connects.
            // Use reactive wait: listen for the @Published change with a timeout.
            if detectedAgents.isEmpty && connectionManager.isConnected {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await agents in connectionManager.$detectedAgents.values {
                            if !agents.isEmpty { return }
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s timeout
                    }
                    // Return as soon as either completes
                    await group.next()
                    group.cancelAll()
                }
            }

            // Initialize tabs
            if tabs.isEmpty {
                // Show OpenClaw tab if installed (fixed tab, first position)
                if connectionManager.openclawAvailable {
                    tabs.append(TerminalTab(id: "openclaw", title: "OpenClaw", isFixed: true, type: .openclaw))
                }
                if let preferredEngine = detectedAgents.first {
                    let tabType: TerminalTab.TabType = preferredEngine == .claude ? .claude : .engine
                    tabs.append(TerminalTab(id: "\(preferredEngine.rawValue)-1", title: preferredEngine.displayName, isFixed: false, type: tabType, sessionId: nil, engineType: preferredEngine))
                } else {
                    // No agents detected — fall back to terminal
                    tabs.append(TerminalTab(id: "terminal-1", title: "Terminal", isFixed: false, type: .terminal, sessionId: nil, engineType: nil))
                }
                // Default to last tab (engine or terminal)
                if tabs.count > 1 {
                    selectedTabIndex = tabs.count - 1
                }
            }
            chatService.switchTab(tabId: currentTab.id)
            await chatService.loadFromUltraContext(workspacePath: workspace.effectivePath, client: ultraContextClient)
            setupOutputHandler()
            await waitForConnectionAndStartClaude()

            // Preload file tree for @ autocomplete (scoped to sub-project for monorepos)
            connectionManager.send(WSPacket(action: .fileTree, payload: ["path": workspace.effectivePath]))

            // Preload simulators for the Build & Run menu. Only fetch for
            // workspaces that actually support Build & Run so we don't
            // spam `simctl list` for web/backend workspaces.
            if workspace.supportsBuildAndRun {
                connectionManager.send(WSPacket(action: .simulatorList))
                selectedSimulatorUDID = workspace.config?["preferredSimulator"]
            }

            // Request slash commands for this workspace
            connectionManager.send(WSPacket(action: .slashCommandsRequest, payload: ["path": workspace.effectivePath]))

            // Auto-start stream since stream mode is default
            if viewMode == .stream {
                isStreamActive = true
            }
        }
        .onDisappear {
            cleanupHandler()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            guard isInputFocused || isTerminalInputActive else { return }
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
                                activityLines: activityLines,
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
                            terminalCompletions = []
                            // Restore new tab state
                            let restored = tabStates[tab.id] ?? TabState()
                            isAgentThinking = restored.isThinking
                            agentActivity = restored.activity
                            activityLines = restored.activityLines
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

                Menu {
                    if detectedAgents.count == 1 {
                        Button(action: { addEngineTab(detectedAgents[0]) }) {
                            Label("New chat", systemImage: "plus.bubble")
                        }
                    } else if detectedAgents.count > 1 {
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
                                                .font(TarsyTheme.font(size: 14))
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Button(action: { addTerminalTab() }) {
                        Label("Terminal", systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    // Build & Run only makes sense for native Apple projects
                    // (Xcode / Swift Package). Hide the entry point for web,
                    // backend, and JS-based mobile (Expo / React Native) workspaces.
                    if workspace.isSwiftMobile {
                        Button(action: { addBuildRunTab() }) {
                            Label {
                                Text("Build & Run ") + Text("(Hot Reload)")
                                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                                    .foregroundColor(TarsyTheme.textSecondary)
                            } icon: {
                                Image(systemName: "hammer.fill")
                            }
                        }
                    }

                    if !detectedAgents.isEmpty {
                        Button(action: { showSessionPicker = true }) {
                            Label("Import session", systemImage: "clock.arrow.circlepath")
                        }
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
        .fixedSize(horizontal: false, vertical: true)
        .background(TarsyTheme.backgroundSecondary)
    }

    // MARK: - Chat Area

    @State private var interactiveOptions: [InteractiveOption]? = nil
    @State private var interactiveQuestions: [InteractiveQuestion]? = nil
    @State private var pendingPermissionRequestId: String? = nil
    @State private var pendingQuestionId: String? = nil

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if chatService.isLoading && chatService.messages.isEmpty {
                        ChatSkeletonView()
                            .transition(.opacity)
                    }

                    // Load older messages button
                    if chatService.hasOlderMessages {
                        Button {
                            Task { await chatService.loadOlderMessages(client: ultraContextClient) }
                        } label: {
                            HStack(spacing: 6) {
                                if chatService.isLoadingOlder {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .tint(TarsyTheme.textSecondary)
                                } else {
                                    Image(systemName: "arrow.up.circle")
                                }
                                Text(chatService.isLoadingOlder ? "Loading..." : "Load older messages")
                            }
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .disabled(chatService.isLoadingOlder)
                    }

                    ForEach(chatService.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    // Agent activity / thinking indicator
                    if !activityLines.isEmpty {
                        ActivityNarrationView(lines: activityLines)
                            .id("activity-narration")
                    } else if let activity = agentActivity {
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
            .onChange(of: activityLines.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: messageText) { _, newValue in
                updateAutocomplete(newValue)
            }
            .onReceive(NotificationCenter.default.publisher(for: .widgetPermissionResponseProcessed)) { notification in
                guard let wsId = notification.userInfo?["workspaceId"] as? String,
                      wsId == workspace.id.uuidString else { return }
                // Clear question UI — response was sent from Live Activity widget
                withAnimation {
                    interactiveQuestions = nil
                    interactiveOptions = nil
                    pendingPermissionRequestId = nil
                    pendingQuestionId = nil
                }
                isAgentThinking = true
                if let sessionId = notification.userInfo?["sessionId"] as? String {
                    todoManager.markResumed(sessionId: sessionId)
                }
            }
        }
    }

    // MARK: - Terminal

    private static let ansiRegex = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if interactiveOptions != nil {
                proxy.scrollTo("interactive-options", anchor: .bottom)
            } else if !activityLines.isEmpty {
                proxy.scrollTo("activity-narration", anchor: .bottom)
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
                var payload: [String: String] = [
                    "sessionId": sessionId,
                    "answer": answerText,
                    "engineType": engineType
                ]
                // Include permission request ID if this was a permission prompt
                if let permId = pendingPermissionRequestId {
                    payload["permissionRequestId"] = permId
                    pendingPermissionRequestId = nil
                }
                if let qId = pendingQuestionId {
                    payload["questionId"] = qId
                    pendingQuestionId = nil
                }
                connectionManager.send(WSPacket(
                    action: .engineUserResponse,
                    payload: payload
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
                activeTabId: currentTab.id,
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
                                    .font(TarsyTheme.font(size: 14))
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
                                .font(TarsyTheme.font(size: 20))
                                .foregroundColor(TarsyTheme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    tabBar

                    Divider().background(TarsyTheme.backgroundTertiary)

                    if currentTab.type == .buildAndRun {
                        BuildRunView(
                            workspace: workspace,
                            buildOutput: $buildOutput,
                            buildPhase: $buildPhase,
                            buildPercent: $buildPercent,
                            hotReloadStatus: $hotReloadStatus,
                            hotReloadInjectionCount: $hotReloadInjectionCount,
                            isBuildRunning: $isBuildRunning,
                            autoStart: $autoStartBuild,
                            preferredSimulatorUDID: selectedSimulatorUDID
                        )
                    } else if currentTab.type == .terminal {
                        TerminalContentView(
                            workspace: workspace,
                            chatService: chatService,
                            isKeyboardActive: $isTerminalInputActive,
                            currentDirectory: terminalCwd(for: currentTab.id),
                            isRunning: runningTerminals.contains(currentTab.id),
                            onSendCommand: { command in
                                terminalCompletions = []
                                sendTerminalCommand(command)
                            },
                            onRequestCompletion: { partial in
                                sendTerminalCompletionRequest(partial)
                            },
                            onClearCompletions: {
                                withAnimation(.easeOut(duration: 0.1)) {
                                    terminalCompletions = []
                                }
                            },
                            onInterrupt: {
                                interruptTerminal()
                            },
                            completions: terminalCompletions
                        )
                        .padding(.bottom, keyboardHeight)
                    } else {
                        chatArea
                    }

                    if currentTab.type != .terminal && currentTab.type != .buildAndRun {
                        inputBar
                    }
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
                        activeTabId: currentTab.id,
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
                    if currentTab.type == .buildAndRun {
                        BuildRunView(
                            workspace: workspace,
                            buildOutput: $buildOutput,
                            buildPhase: $buildPhase,
                            buildPercent: $buildPercent,
                            hotReloadStatus: $hotReloadStatus,
                            hotReloadInjectionCount: $hotReloadInjectionCount,
                            isBuildRunning: $isBuildRunning,
                            autoStart: $autoStartBuild,
                            preferredSimulatorUDID: selectedSimulatorUDID
                        )
                    } else if currentTab.type == .terminal {
                        TerminalContentView(
                            workspace: workspace,
                            chatService: chatService,
                            isKeyboardActive: $isTerminalInputActive,
                            currentDirectory: terminalCwd(for: currentTab.id),
                            isRunning: runningTerminals.contains(currentTab.id),
                            onSendCommand: { command in
                                terminalCompletions = []
                                sendTerminalCommand(command)
                            },
                            onRequestCompletion: { partial in
                                sendTerminalCompletionRequest(partial)
                            },
                            onClearCompletions: {
                                withAnimation(.easeOut(duration: 0.1)) {
                                    terminalCompletions = []
                                }
                            },
                            onInterrupt: {
                                interruptTerminal()
                            },
                            completions: terminalCompletions
                        )
                        .padding(.bottom, keyboardHeight)
                    } else {
                        chatArea

                        if !autocompleteItems.isEmpty {
                            AutocompleteOverlay(items: autocompleteItems) { item in
                                handleAutocompleteSelection(item)
                            }
                            .padding(.horizontal, 12)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }

                    if currentTab.type != .terminal && currentTab.type != .buildAndRun {
                        inputBar
                    }
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
            activeTabId: currentTab.id,
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
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { viewMode = .stream }
                // Signal StreamPlayerView to auto-start if not already running
                if !isStreamActive {
                    isStreamActive = true
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "display")
                        .font(TarsyTheme.font(size: 10))
                    Text("stream")
                        .font(TarsyTheme.font(size: 11))
                }
                    .foregroundColor(viewMode == .stream ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { viewMode = .browser }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "iphone")
                        .font(TarsyTheme.font(size: 10))
                    Text("browser")
                        .font(TarsyTheme.font(size: 11))
                }
                    .foregroundColor(viewMode == .browser ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
        }
        .background(
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 12)
                    .fill(TarsyTheme.backgroundTertiary)
                    .frame(width: geo.size.width / 2, height: geo.size.height)
                    .offset(x: viewMode == .stream ? 0 : geo.size.width / 2)
                    .animation(.easeInOut(duration: 0.2), value: viewMode)
            }
        )
        .background(TarsyTheme.backgroundSecondary.opacity(0.9))
        .cornerRadius(12)
    }

    private var infoBar: some View {
        VStack(spacing: 0) {
            // Divider above info bar for terminal tabs
            if currentTab.type == .terminal {
                Rectangle()
                    .fill(TarsyTheme.textSecondary.opacity(0.15))
                    .frame(height: 0.5)
                    .padding(.bottom, 8)
            }

            // Info bar
            HStack(spacing: 0) {
                // Branch + pull
                Button(action: { pullBranch() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(TarsyTheme.font(size: 10))
                        Text(currentBranch.isEmpty ? workspace.currentBranch ?? "main" : currentBranch)
                            .lineLimit(1)
                        Image(systemName: "arrow.down")
                            .font(TarsyTheme.font(size: 8))
                    }
                    .font(TarsyTheme.font(size: 11))
                    .foregroundColor(TarsyTheme.textSecondary)
                }

                if currentTab.type != .terminal {
                    Text("  |  ")
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.3))

                    // Engine + model
                    HStack(spacing: 3) {
                        AgentIcon(engineType: currentTab.engineType ?? .claude, size: 14)
                        Text(engineDisplayName)
                            .lineLimit(1)
                    }
                    .font(TarsyTheme.font(size: 11))
                    .foregroundColor(TarsyTheme.textSecondary)

                    if contextPercent > 0 {
                        Text("  |  ")
                            .font(TarsyTheme.font(size: 11))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.3))

                        // Context %
                        Text("\(Int(contextPercent))% ctx")
                            .font(TarsyTheme.font(size: 11))
                            .foregroundColor(contextPercent > 80 ? TarsyTheme.accentTerracotta : TarsyTheme.textSecondary)
                    }
                }

                Spacer()

                // Build & Run quick action — primary tap runs with the
                // last-used simulator; the menu exposes per-simulator
                // choices and (for cross-platform stacks like Expo/Flutter)
                // a "Run on Android in Terminal" escape hatch for platforms
                // Tarsy can't stream natively. Only shown when the workspace
                // has a supported runner.
                if workspace.supportsBuildAndRun {
                    buildAndRunMenu
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)

            // Extra space for home indicator when safe area is ignored
            if !isInputFocused {
                Color.clear.frame(height: 20)
            }
        }
        .background(currentTab.type == .terminal ? Color(hex: "0a0a0a") : TarsyTheme.backgroundPrimary)
    }

    /// Right-aligned "running" bar with a cancel button next to a spinner.
    /// Used above the chat text editor (agent tabs) and above the terminal
    /// prompt row to give the user a consistent way to abort an in-flight
    /// command across both surfaces.
    @ViewBuilder
    private func runningBar(onCancel: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Button(action: onCancel) {
                Text("cancel")
                    .font(TarsyTheme.font(size: 12, weight: .semibold))
                    .foregroundColor(TarsyTheme.accentTerracotta)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(TarsyTheme.accentTerracotta.opacity(0.12))
                    .cornerRadius(8)
            }
            .accessibilityLabel("Cancel running command")

            ProgressView()
                .scaleEffect(0.7)
                .tint(TarsyTheme.accentTerracotta)
                .frame(width: 20, height: 20)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Input bar
            VStack(spacing: 0) {
                // "Running" bar above the text editor — visible while the
                // agent is working. Cancel button sits immediately left of
                // the spinner, both right-aligned.
                if isAgentThinking || agentActivity != nil {
                    runningBar(onCancel: {
                        Haptics.medium()
                        interruptEngine()
                    })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Text field (replaced by VoiceRecordingHUD while recording)
                if voiceRecorder.isRecording {
                    VoiceRecordingHUD(recorder: voiceRecorder, style: .inlineBar)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    ZStack(alignment: .topLeading) {
                        if messageText.isEmpty {
                            Text(currentTab.type == .terminal ? "$ run a command..." : "send a command...")
                                .font(currentTab.type == .terminal ? .system(size: 16, design: .monospaced) : TarsyTheme.font(size: 16))
                                .foregroundColor(TarsyTheme.textSecondary.opacity(0.35))
                                .padding(.horizontal, 20)
                                .padding(.top, 22)
                        }
                        TextEditor(text: $messageText)
                            .font(TarsyTheme.font(size: 16))
                            .foregroundColor(TarsyTheme.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 36, maxHeight: 200)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 8)
                            .focused($isInputFocused)
                    }
                }

                // Action buttons row
                HStack(spacing: 4) {
                    if currentTab.type != .terminal {
                        Button(action: { showAttachmentPicker.toggle() }) {
                            Image(systemName: "plus")
                                .font(TarsyTheme.font(size: 18, weight: .medium))
                                .foregroundColor(TarsyTheme.textSecondary)
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Add attachment")
                    }

                    Spacer()

                    if workspace.stack == .web || workspace.stack == .fullstack {
                        viewModeSwitch
                    }

                    Spacer()

                    if currentTab.type != .terminal {
                        // Voice tasks button (left of mic)
                        if todoManager.hasActiveItems {
                            Button { todoManager.isMinimized ? todoManager.expand() : todoManager.minimize() } label: {
                                ZStack {
                                    if todoManager.hasQuestionItems {
                                        Image(systemName: "questionmark")
                                            .font(TarsyTheme.font(size: 14, weight: .bold))
                                            .foregroundColor(TarsyTheme.accentAmber)
                                    } else if let tool = todoManager.items.last(where: { $0.status == .working })?.currentTool {
                                        Image(systemName: VoiceTodoManager.iconForTool(tool))
                                            .font(TarsyTheme.font(size: 14))
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
                                                .font(TarsyTheme.font(size: 9, weight: .bold))
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

                        Image(systemName: voiceRecorder.isRecording ? "mic.fill" : "mic")
                            .font(TarsyTheme.font(size: 16))
                            .foregroundColor(
                                voiceRecorder.isCancelling
                                    ? TarsyTheme.accentTerracotta
                                    : (voiceRecorder.isRecording ? TarsyTheme.accentTerracotta : TarsyTheme.textSecondary)
                            )
                            .frame(width: 36, height: 36)
                            .scaleEffect(voiceRecorder.isCancelling ? 1.2 : (voiceRecorder.isRecording ? 1.15 : 1.0))
                            .offset(x: voiceRecorder.dragOffsetX * 0.3)
                            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.8), value: voiceRecorder.dragOffsetX)
                            .animation(.easeInOut(duration: 0.15), value: voiceRecorder.isCancelling)
                            .voiceRecordGesture(recorder: voiceRecorder)
                            .accessibilityLabel(voiceRecorder.isRecording ? "Stop recording" : "Hold to record voice")
                    }

                    Button(action: { sendMessage() }) {
                        Image(systemName: "arrow.up")
                            .font(TarsyTheme.font(size: 14, weight: .bold))
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
                .animation(.easeInOut(duration: 0.2), value: voiceRecorder.isRecording)
                .animation(.easeInOut(duration: 0.25), value: todoManager.hasActiveItems)
            }
            .background(currentTab.type == .terminal ? TarsyTheme.backgroundPrimary : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        currentTab.type == .terminal
                            ? TarsyTheme.textSecondary.opacity(0.15)
                            : (voiceRecorder.isCancelling
                                ? TarsyTheme.accentTerracotta
                                : (voiceRecorder.isRecording ? TarsyTheme.accentAmber : Color.clear)),
                        lineWidth: 1.5
                    )
            )
            .if_iOS26GlassEffect()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.2), value: isAgentThinking)
            .animation(.easeInOut(duration: 0.2), value: agentActivity)
        }
        .background(TarsyTheme.backgroundPrimary)
        .overlay(alignment: .topLeading) {
            if !attachments.isEmpty && currentTab.type != .terminal {
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
                    .font(TarsyTheme.font(size: 11))
                    .foregroundColor(TarsyTheme.accentAmber)
                    .frame(width: 24, height: 24)
                    .background(TarsyTheme.backgroundTertiary)
                    .cornerRadius(4)
            }

            Text(attachment.name)
                .font(TarsyTheme.font(size: 10))
                .foregroundColor(TarsyTheme.textPrimary)
                .lineLimit(1)

            Button(action: {
                withAnimation { attachments.removeAll { $0.id == attachment.id } }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(TarsyTheme.font(size: 11))
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

    // MARK: - Autocomplete

    private func updateAutocomplete(_ text: String) {
        // Terminal tabs never get context injection
        if currentTab.type == .terminal {
            if !autocompleteItems.isEmpty {
                withAnimation(.easeOut(duration: 0.15)) { autocompleteItems = [] }
            }
            return
        }

        // Slash commands: only at start of message, only for Claude Code tabs
        let isClaudeTab = (currentTab.engineType ?? .claude) == .claude
        if text.hasPrefix("/") && isClaudeTab {
            let filter = String(text.dropFirst()).lowercased()

            // Read detected commands directly from ConnectionManager (always latest)
            let detected: [AutocompleteItem] = connectionManager.detectedSlashCommands.map { cmd in
                AutocompleteItem(
                    icon: "terminal",
                    label: cmd["name"] ?? "",
                    insertText: cmd["name"] ?? "",
                    description: cmd["description"] ?? ""
                )
            }

            // Merge: simple detected first, then builtins (deduped), then namespaced detected
            let allCommands: [AutocompleteItem]
            if detected.isEmpty {
                allCommands = AutocompleteOverlay.slashCommands
            } else {
                let simple = detected.filter { !$0.label.contains(":") }
                let namespaced = detected.filter { $0.label.contains(":") }
                let builtins = AutocompleteOverlay.slashCommands.filter { builtin in
                    !detected.contains(where: { $0.label == builtin.label })
                }
                allCommands = simple + builtins + namespaced
            }
            withAnimation(.easeOut(duration: 0.15)) {
                autocompleteItems = allCommands.filter {
                    filter.isEmpty || $0.label.lowercased().contains(filter)
                }
            }
            return
        }

        // @ file mentions: match @word at end of text (@ must be at start or after whitespace)
        if let range = text.range(of: "@[^\\s]*$", options: .regularExpression),
           (range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)].isWhitespace) {
            let query = String(text[range].dropFirst()).lowercased()
            withAnimation(.easeOut(duration: 0.15)) {
                autocompleteItems = cachedFileEntries.filter {
                    query.isEmpty || $0.label.lowercased().contains(query)
                }
            }
            return
        }

        if !autocompleteItems.isEmpty {
            withAnimation(.easeOut(duration: 0.15)) {
                autocompleteItems = []
            }
        }
    }

    private func handleAutocompleteSelection(_ item: AutocompleteItem) {
        if messageText.hasPrefix("/") {
            messageText = item.insertText
        } else if let range = messageText.range(of: "@[^\\s]*$", options: .regularExpression) {
            messageText.replaceSubrange(range, with: item.insertText + " ")
        }
        withAnimation(.easeOut(duration: 0.15)) {
            autocompleteItems = []
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

            // Terminal doesn't have a thinking/activity state
            if currentTab.type != .terminal {
                isAgentThinking = true
            }

            // Start Live Activity when user sends a real task
            if currentTab.type == .claude || currentTab.type == .engine {
                let engine = currentTab.engineType ?? .claude
                LiveActivityManager.shared.startActivity(
                    workspaceId: workspace.id.uuidString,
                    workspaceName: workspace.name,
                    engineType: engine,
                    tabId: currentTab.id
                )
                LiveActivityManager.shared.updateUserPrompt(
                    workspaceId: workspace.id.uuidString,
                    prompt: displayText,
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
                    print("[Chat] Sending engineCreate type=\(engineType.rawValue) path=\(workspace.effectivePath)")
#endif
                    let permConfig = AgentPermissionConfig.load()
                    var payload = [
                        "path": workspace.effectivePath,
                        "engineType": engineType.rawValue,
                        "aiContext": workspace.aiContext ?? "",
                        "message": messageText,
                        "permissionMode": permConfig.mode(for: engineType).rawValue,
                        "workspaceId": workspace.id.uuidString
                    ]
                    if let images = imagesPayload { payload["images"] = images }
                    let createPacket = WSPacket(action: .engineCreate, payload: payload)
                    pendingCreateRequests[createPacket.id] = currentTab.id
                    connectionManager.send(createPacket)
                }
            } else if currentTab.type == .openclaw {
                connectionManager.send(WSPacket(
                    action: .openclawMessage,
                    payload: ["message": messageText]
                ))
            }
        }
    }

    /// Mark a terminal tab as running a command. Cleared by either an
    /// explicit `interruptTerminal` or the `terminalPromptReady` packet
    /// from macOS — whichever happens first.
    private func markTerminalRunning(_ tabId: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            runningTerminals.insert(tabId)
        }
    }

    /// Immediately clear the running flag for a terminal tab.
    private func clearTerminalRunning(_ tabId: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            _ = runningTerminals.remove(tabId)
        }
    }

    private func sendTerminalCommand(_ command: String) {
        // Optimistically update the tab's cwd if the command is a `cd`.
        // The shell on the macOS side authoritatively changes directory;
        // this just keeps the prompt label in sync for typical usage.
        let priorCwd = terminalCwd(for: currentTab.id)
        if let newCwd = resolveCdCommand(command, relativeTo: priorCwd) {
            terminalCwds[currentTab.id] = newCwd
        }

        markTerminalRunning(currentTab.id)

        let msg = ChatMessage(
            workspaceId: workspace.id,
            tabId: currentTab.id,
            role: .user,
            content: command
        )
        Task {
            await chatService.addMessage(msg)
            if let sessionId = currentTab.sessionId {
                connectionManager.send(WSPacket(
                    action: .terminalInput,
                    payload: ["sessionId": sessionId, "input": command]
                ))
            } else {
                // Terminal session not yet created — create it and queue the command
                let createPacket = WSPacket(
                    action: .terminalCreate,
                    payload: ["path": workspace.effectivePath]
                )
                pendingCreateRequests[createPacket.id] = currentTab.id
                pendingTerminalCommands[currentTab.id] = command
                connectionManager.send(createPacket)
            }
        }
    }

    /// Resolved cwd for a terminal tab (falls back to the workspace effective path,
    /// which honors `subPath` for monorepos).
    private func terminalCwd(for tabId: String) -> String {
        terminalCwds[tabId] ?? workspace.effectivePath
    }

    /// Parses a shell command and returns the new absolute cwd if it's a `cd`.
    /// Returns nil if the command doesn't change directory or can't be parsed
    /// reliably (e.g. `cd -`, `cd ~`, `cd $VAR`).
    ///
    /// Handles simple chains like `cd foo && ls` by inspecting the first segment.
    private func resolveCdCommand(_ command: String, relativeTo currentDir: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Take the first segment up to a chain separator (;, &&, ||, |).
        let separators: Set<Character> = [";", "&", "|"]
        var firstSegment = trimmed
        if let idx = trimmed.firstIndex(where: { separators.contains($0) }) {
            firstSegment = String(trimmed[..<idx]).trimmingCharacters(in: .whitespaces)
        }

        // Must be `cd` optionally followed by whitespace and an argument.
        guard firstSegment == "cd"
            || firstSegment.hasPrefix("cd ")
            || firstSegment.hasPrefix("cd\t") else { return nil }

        var arg = String(firstSegment.dropFirst(2)).trimmingCharacters(in: .whitespaces)

        // Strip a single pair of surrounding quotes
        if arg.count >= 2,
           (arg.hasPrefix("\"") && arg.hasSuffix("\"")) ||
           (arg.hasPrefix("'") && arg.hasSuffix("'")) {
            arg = String(arg.dropFirst().dropLast())
        }

        // Edge cases we can't resolve reliably without querying the shell
        if arg.isEmpty || arg == "-" || arg.hasPrefix("~") || arg.contains("$") {
            return nil
        }

        let combined: String
        if arg.hasPrefix("/") {
            combined = arg
        } else {
            combined = (currentDir as NSString).appendingPathComponent(arg)
        }

        // Resolve `.` and `..` segments
        return (combined as NSString).standardizingPath
    }

    /// Send a completion request with an already-extracted partial word
    private func sendTerminalCompletionRequest(_ partial: String) {
        guard !partial.isEmpty else { return }
        // Tag the request with the current tab so we can discard stale responses
        completionRequestTabId = currentTab.id
        connectionManager.send(WSPacket(
            action: .terminalComplete,
            payload: ["partial": partial, "path": terminalCwd(for: currentTab.id)]
        ))
    }

    private func interruptTerminal() {
        if let sessionId = currentTab.sessionId {
            connectionManager.send(WSPacket(
                action: .terminalInterrupt,
                payload: ["sessionId": sessionId]
            ))
        } else {
            // No session yet — clear any queued command so it doesn't run
            pendingTerminalCommands.removeValue(forKey: currentTab.id)
        }
        clearTerminalRunning(currentTab.id)
    }

    private func interruptEngine() {
        guard let sessionId = currentTab.sessionId else { return }
        connectionManager.send(WSPacket(
            action: .engineInterrupt,
            payload: ["sessionId": sessionId]
        ))
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
            let createPacket = WSPacket(
                action: .engineCreate,
                payload: [
                    "path": workspace.effectivePath,
                    "engineType": engineType.rawValue,
                    "aiContext": workspace.aiContext ?? "",
                    "workspaceId": workspace.id.uuidString
                ]
            )
            pendingCreateRequests[createPacket.id] = tabs[tabIndex].id
            connectionManager.send(createPacket)
#if DEBUG
            print("[Workspace] Sent engineCreate type=\(engineType.rawValue) for path=\(workspace.effectivePath)")
#endif
        }

        // Start terminal session if the initial tab is a terminal
        if let tabIndex = tabs.firstIndex(where: { $0.type == .terminal && $0.sessionId == nil }) {
            let createPacket = WSPacket(
                action: .terminalCreate,
                payload: ["path": workspace.effectivePath]
            )
            pendingCreateRequests[createPacket.id] = tabs[tabIndex].id
            connectionManager.send(createPacket)
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
        let createPacket = WSPacket(
            action: .engineCreate,
            payload: [
                "path": workspace.effectivePath,
                "engineType": engineType.rawValue,
                "aiContext": workspace.aiContext ?? "",
                "permissionMode": permConfig.mode(for: engineType).rawValue,
                "workspaceId": workspace.id.uuidString
            ]
        )
        pendingCreateRequests[createPacket.id] = uniqueId
        connectionManager.send(createPacket)
    }

    private func addTerminalTab() {
        let count = tabs.filter { $0.type == .terminal }.count + 1
        let title = count > 1 ? "Terminal \(count)" : "Terminal"
        let uniqueId = "terminal-\(UUID().uuidString.prefix(8))"
        let tab = TerminalTab(id: uniqueId, title: title, isFixed: false, type: .terminal, sessionId: nil, engineType: nil)
        tabs.append(tab)
        selectedTabIndex = tabs.count - 1
        chatService.switchTab(tabId: uniqueId)

        // Create terminal session on Mac (in sub-project dir for monorepos)
        let createPacket = WSPacket(
            action: .terminalCreate,
            payload: ["path": workspace.effectivePath]
        )
        pendingCreateRequests[createPacket.id] = uniqueId
        connectionManager.send(createPacket)
    }

    /// One-shot: ask the macOS daemon to re-analyze the workspace's
    /// `localPath`. If multiple sub-projects come back, surface the
    /// migration sheet so the user can pick one. If the response shows a
    /// single project (or none), persist `subPathConfigured=true` so we
    /// don't ask again.
    ///
    /// Awaits up to 5 s for the response (matching the timeout used by the
    /// new-workspace analysis path), then either presents the sheet or
    /// silently records that the check ran.
    private func checkForMonorepoMigration() async {
        // Need a connection to talk to the macOS daemon. If we're not yet
        // connected, give it up to 3 s — the .task block right after this
        // also waits on connection state, so this small grace window keeps
        // the migration logic from racing the WebSocket handshake.
        if !connectionManager.isConnected {
            for _ in 0..<30 {
                if connectionManager.isConnected { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard connectionManager.isConnected else { return }
        }

        struct Analysis: Codable {
            let language: String?
            let framework: String?
            let stack: String?
            let suggestedCommand: String?
            let isMonorepo: Bool?
            let projects: [DetectedSubProject]?
        }

        let analysis: Analysis? = await withCheckedContinuation { continuation in
            var didResume = false
            let listenerKey = "monorepo-migration-\(workspaceId.uuidString)"

            connectionManager.addListener(listenerKey) { packet in
                guard packet.action == .repoAnalysis,
                      let json = packet.payload?["analysis"],
                      let data = json.data(using: .utf8),
                      let analysis = try? JSONDecoder().decode(Analysis.self, from: data) else { return }
                guard !didResume else { return }
                didResume = true
                connectionManager.removeListener(listenerKey)
                continuation.resume(returning: analysis)
            }

            connectionManager.send(WSPacket(action: .repoAnalyze, payload: ["path": workspace.localPath]))

            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !didResume else { return }
                didResume = true
                connectionManager.removeListener(listenerKey)
                continuation.resume(returning: nil)
            }
        }

        await MainActor.run {
            let projects = analysis?.projects ?? []
            if projects.count > 1 {
                pendingMonorepoProjects = projects
                showMonorepoMigration = true
            } else {
                // Single-project repo (or analysis failed). Mark configured
                // so we never re-prompt — there's nothing to choose. Also
                // backfill language/framework while we're at it: legacy
                // workspaces with no `config` would otherwise stay
                // mis-classified by `isSwiftMobile` (e.g. an Expo project
                // with `stack=mobile` falsely shows the Build & Run tab
                // because the language=Swift signal is missing).
                Task {
                    var merged = workspace.config ?? [:]
                    merged["subPathConfigured"] = "true"
                    if let lang = analysis?.language, !lang.isEmpty {
                        merged["language"] = lang
                    }
                    if let fw = analysis?.framework, !fw.isEmpty {
                        merged["framework"] = fw
                    }
                    var req = UpdateWorkspaceRequest()
                    req.config = merged
                    try? await workspaceService.updateWorkspace(id: workspaceId, req)
                }
            }
        }
    }

    private func addBuildRunTab() {
        // Only allow one Build & Run tab
        if let existing = tabs.firstIndex(where: { $0.type == .buildAndRun }) {
            selectedTabIndex = existing
            return
        }
        let tab = TerminalTab(id: "build-run", title: "Build & Run", isFixed: false, type: .buildAndRun, sessionId: nil, engineType: nil)
        tabs.append(tab)
        selectedTabIndex = tabs.count - 1
    }

    /// Bottom-bar entry point: jump straight into Build & Run from anywhere
    /// in the workspace. Opens or focuses the tab AND auto-starts the build
    /// — without this the user has to (a) open the menu, (b) tap Build &
    /// Run, (c) tap the in-tab Build & Run button. Three-tap workflow for
    /// what should be one tap.
    private func openBuildAndRun() {
        addBuildRunTab()
        autoStartBuild = true
    }

    /// Picker menu backing the bottom-bar Build & Run button. Primary tap
    /// label reflects the currently selected simulator; menu items let the
    /// user switch simulator or (for Expo/Flutter) punt Android to the
    /// terminal since Tarsy can't stream Android emulators.
    @ViewBuilder
    private var buildAndRunMenu: some View {
        let runnerIsCrossPlatform = workspace.buildRunner == .expo || workspace.buildRunner == .flutter
        let defaultSim = availableSimulators.first(where: { $0.udid == selectedSimulatorUDID })
            ?? availableSimulators.first(where: { $0.isBooted })
            ?? availableSimulators.first

        Menu {
            // Primary action — run with the currently selected simulator.
            Button(action: { runBuildOnIOS(udid: selectedSimulatorUDID) }) {
                Label(
                    defaultSim.map { "Run on \($0.name)" } ?? "Build & Run (auto-pick simulator)",
                    systemImage: "play.fill"
                )
            }

            // Explicit per-simulator picker. Hidden when there's zero/one
            // simulator — a picker with one item is just noise.
            if availableSimulators.count > 1 {
                Divider()
                Section("iOS Simulator") {
                    ForEach(availableSimulators) { sim in
                        Button(action: {
                            selectedSimulatorUDID = sim.udid
                            Task { await persistPreferredSimulator(sim.udid) }
                            runBuildOnIOS(udid: sim.udid)
                        }) {
                            if sim.udid == selectedSimulatorUDID {
                                Label("\(sim.name) — \(sim.runtimeShortName)", systemImage: "checkmark")
                            } else if sim.isBooted {
                                Label("\(sim.name) — \(sim.runtimeShortName) (booted)", systemImage: "iphone")
                            } else {
                                Label("\(sim.name) — \(sim.runtimeShortName)", systemImage: "iphone")
                            }
                        }
                    }
                }
            }

            // Android escape hatch. Tarsy has no Android streaming/input
            // integration so we opt out of the native Build & Run tab and
            // drop the user into a terminal with the right command — they
            // still have to watch the emulator window physically on the
            // Mac, but they can at least kick the build off from iOS.
            if runnerIsCrossPlatform {
                Divider()
                Button(action: { runAndroidInTerminal() }) {
                    Label("Run on Android (in terminal)", systemImage: "terminal")
                }
            }
        } label: {
            HStack(spacing: 4) {
                if isBuildRunning {
                    ProgressView()
                        .scaleEffect(0.5)
                        .tint(TarsyTheme.backgroundPrimary)
                } else {
                    Image(systemName: "play.fill")
                        .font(TarsyTheme.font(size: 9))
                }
                Text(isBuildRunning ? "building..." : "Build & Run")
                    .font(TarsyTheme.font(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(TarsyTheme.font(size: 8))
                    .opacity(0.7)
            }
            .foregroundColor(TarsyTheme.backgroundPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isBuildRunning ? TarsyTheme.backgroundTertiary : TarsyTheme.accentAmber)
            .cornerRadius(6)
        }
        .disabled(isBuildRunning)
    }

    /// Kicks off an iOS Build & Run with an optional specific simulator.
    /// Passing nil lets the macOS daemon auto-pick (first booted, fall
    /// back to first available + boot it).
    private func runBuildOnIOS(udid: String?) {
        selectedSimulatorUDID = udid
        openBuildAndRun()
    }

    /// Opens a terminal tab pre-populated with the Android equivalent of
    /// the current workspace's runner command. Not integrated with stream
    /// or input — this is the "we told you we can't do Android natively
    /// but here's the command" honest-middle-ground UX.
    private func runAndroidInTerminal() {
        let command: String
        switch workspace.buildRunner {
        case .expo:
            command = "npx expo run:android"
        case .flutter:
            // Flutter doesn't auto-pick between multiple emulators like
            // simctl does for us; leave -d off so the CLI prints its own
            // picker to the terminal, which the user can respond to.
            command = "flutter run"
        default:
            return
        }
        addTerminalTab()
        // After addTerminalTab(), currentTab is the newly-created terminal.
        // Queue the command for after the session is created so it runs
        // once macOS finishes spawning the shell.
        if let newTabId = tabs.last?.id {
            pendingTerminalCommands[newTabId] = command
        }
    }

    /// Persists the user's simulator choice into the workspace `config`
    /// jsonb. Merges into the existing dict so language/framework/subPath
    /// keys are preserved — Supabase PATCH replaces the whole column.
    private func persistPreferredSimulator(_ udid: String) async {
        var merged = workspace.config ?? [:]
        merged["preferredSimulator"] = udid
        var req = UpdateWorkspaceRequest()
        req.config = merged
        try? await workspaceService.updateWorkspace(id: workspaceId, req)
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

        // Start Live Activity for continued session
        LiveActivityManager.shared.startActivity(
            workspaceId: workspace.id.uuidString,
            workspaceName: workspace.name,
            engineType: engineType,
            tabId: uniqueId
        )

        let createPacket = WSPacket(
            action: .engineCreate,
            payload: [
                "workspacePath": workspace.effectivePath,
                "workspaceId": workspace.id.uuidString,
                "engineType": engineType.rawValue,
                "message": String(message.prefix(4000)),
                "tabId": uniqueId
            ]
        )
        pendingCreateRequests[createPacket.id] = uniqueId
        connectionManager.send(createPacket)
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
        // Clean up any pending create requests for the closed tab
        pendingCreateRequests = pendingCreateRequests.filter { $0.value != tab.id }
        tabStates.removeValue(forKey: tab.id)
        if wasSelected, !tabs.isEmpty {
            let newTab = tabs[selectedTabIndex]
            let restored = tabStates[newTab.id] ?? TabState()
            isAgentThinking = restored.isThinking
            agentActivity = restored.activity
            activityLines = restored.activityLines
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
                        activityLines = []
                    } else {
                        updateBackgroundTabState(sessionId: sid) { $0.isThinking = false; $0.activity = nil; $0.activityLines = [] }
                    }
                    todoManager.markCompleted(sessionId: sid)
                    // End Live Activity
                    if let tid = tabId(forSession: sid) {
                        LiveActivityManager.shared.endActivity(workspaceId: workspace.id.uuidString, tabId: tid)
                    } else {
                        LiveActivityManager.shared.endActivity(workspaceId: workspace.id.uuidString, tabId: currentTab.id)
                    }
                case .claudeCreate:
                    if let sessionId = packet.payload?["sessionId"], !tabs.isEmpty {
                        let targetTabId = pendingCreateRequests.removeValue(forKey: packet.id)
                        if let targetTabId, let tabIndex = tabs.firstIndex(where: { $0.id == targetTabId }) {
                            tabs[tabIndex].sessionId = sessionId
                        } else {
                            tabs[safeTabIndex].sessionId = sessionId
                        }
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
                        activityLines = []
                    } else {
                        updateBackgroundTabState(sessionId: eSid) { $0.isThinking = false; $0.activity = nil; $0.activityLines = [] }
                    }
                    // End Live Activity (scoped to tab)
                    if let tid = tabId(forSession: eSid) {
                        LiveActivityManager.shared.endActivity(workspaceId: workspace.id.uuidString, tabId: tid)
                    } else {
                        LiveActivityManager.shared.endActivity(workspaceId: workspace.id.uuidString, tabId: currentTab.id)
                    }
                case .engineError:
                    let errSid = packet.payload?["sessionId"] ?? currentTab.sessionId ?? ""
                    todoManager.markCompleted(sessionId: errSid)
                    if isActiveTabSession(packet) {
                        isAgentThinking = false
                        agentActivity = nil
                        activityLines = []
                    } else {
                        updateBackgroundTabState(sessionId: errSid) { $0.isThinking = false; $0.activity = nil; $0.activityLines = [] }
                    }
                    if let tid = tabId(forSession: errSid) {
                        LiveActivityManager.shared.endActivity(workspaceId: workspace.id.uuidString, status: "error", tabId: tid)
                    } else {
                        LiveActivityManager.shared.endActivity(workspaceId: workspace.id.uuidString, status: "error", tabId: currentTab.id)
                    }
                case .engineCreate:
                    if let sessionId = packet.payload?["sessionId"], !tabs.isEmpty {
                        let targetTabId = pendingCreateRequests.removeValue(forKey: packet.id)
                        if let targetTabId, let tabIndex = tabs.firstIndex(where: { $0.id == targetTabId }) {
                            tabs[tabIndex].sessionId = sessionId
                        } else {
                            tabs[safeTabIndex].sessionId = sessionId
                        }
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
                case .terminalCreate:
                    if let sessionId = packet.payload?["sessionId"],
                       let tabId = pendingCreateRequests.removeValue(forKey: packet.id) {
                        if let idx = tabs.firstIndex(where: { $0.id == tabId }) {
                            tabs[idx].sessionId = sessionId
                        }
                        // Send any queued command that was waiting for this session
                        if let queuedCommand = pendingTerminalCommands.removeValue(forKey: tabId) {
                            connectionManager.send(WSPacket(
                                action: .terminalInput,
                                payload: ["sessionId": sessionId, "input": queuedCommand]
                            ))
                        }
                    }

                case .terminalOutput:
                    if let output = packet.payload?["output"] {
                        let termSid = packet.payload?["sessionId"] ?? ""
                        let termTabId = tabId(forSession: termSid) ?? currentTab.id
                        // Strip ANSI escape codes at receive time to avoid repeated regex on render
                        let range = NSRange(output.startIndex..., in: output)
                        let cleaned = Self.ansiRegex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
                        chatService.addAssistantChunk(workspaceId: workspace.id, tabId: termTabId, content: cleaned)
                    }

                case .terminalPromptReady:
                    // macOS wraps every command with a sentinel printf, so
                    // we get a precise "shell is ready for next input"
                    // signal instead of guessing from output silence. Clear
                    // the matching tab's running state.
                    let readySid = packet.payload?["sessionId"] ?? ""
                    if let readyTabId = tabId(forSession: readySid) {
                        clearTerminalRunning(readyTabId)
                    }

                case .terminalCompleteResult:
                    // Discard if user switched tabs since the request was sent
                    guard completionRequestTabId == currentTab.id else { break }
                    if let json = packet.payload?["completions"],
                       let data = json.data(using: .utf8),
                       let items = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                        withAnimation(.easeOut(duration: 0.15)) {
                            terminalCompletions = items.compactMap { dict in
                                guard let name = dict["name"], let typeStr = dict["type"],
                                      let type = TerminalCompletion.CompletionType(rawValue: typeStr) else { return nil }
                                return TerminalCompletion(name: name, type: type)
                            }
                        }
                    }

                // Engine status (model, tokens, context %)
                case .engineStatus:
                    let statusModel = packet.payload?["model"] ?? ""
                    let statusSessionId = packet.payload?["sessionId"] ?? ""
                    let statusTabId = tabId(forSession: statusSessionId) ?? currentTab.id

                    if let input = packet.payload?["inputTokens"].flatMap({ Int($0) }),
                       let output = packet.payload?["outputTokens"].flatMap({ Int($0) }) {
                        let total = input + output
                        let model = statusModel.isEmpty ? engineModel : statusModel
                        // Use contextWindow from CLI when available, fallback to model-based estimate
                        let windowSize: Int
                        if let cw = packet.payload?["contextWindow"].flatMap({ Int($0) }), cw > 0 {
                            windowSize = cw
                        } else if model.contains("opus") { windowSize = 1_000_000 }
                        else { windowSize = 200_000 }
                        let percent = Double(total) / Double(windowSize) * 100

                        if isActiveTabSession(packet) {
                            if !statusModel.isEmpty { engineModel = statusModel }
                            contextPercent = percent
                        } else {
                            updateBackgroundTabState(sessionId: statusSessionId) { state in
                                if !statusModel.isEmpty { state.engineModel = statusModel }
                                state.contextPercent = percent
                            }
                        }
                        LiveActivityManager.shared.updateContext(workspaceId: workspace.id.uuidString, contextPercent: percent, tabId: statusTabId)
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

                // File tree for autocomplete
                case .fileTreeResult:
                    if cachedFileEntries.isEmpty,
                       let json = packet.payload?["tree"],
                       let data = json.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        let root = workspace.effectivePath
                        let basePath = root.hasSuffix("/") ? root : root + "/"
                        cachedFileEntries = parsed.compactMap { dict -> AutocompleteItem? in
                            guard let name = dict["name"] as? String,
                                  let path = dict["path"] as? String,
                                  let type = dict["type"] as? String,
                                  type == "file" else { return nil }
                            let ext = (name as NSString).pathExtension
                            let relativePath = path.hasPrefix(basePath) ? String(path.dropFirst(basePath.count)) : name
                            return AutocompleteItem(
                                icon: AutocompleteOverlay.iconForExtension(ext),
                                label: relativePath,
                                insertText: "@" + relativePath,
                                description: ext
                            )
                        }
                    }

                // Build & Run
                case .buildProgress:
                    // Only update build log if the Build & Run tab is visible
                    if let output = packet.payload?["output"], !output.isEmpty,
                       currentTab.type == .buildAndRun || output.contains("error:") {
                        buildOutput.append(output)
                        if buildOutput.count > 200 { buildOutput.removeFirst(buildOutput.count - 200) }
                    }
                    if let phase = packet.payload?["phase"] { buildPhase = phase }
                    if let pct = packet.payload?["percent"], let p = Int(pct) { buildPercent = p }

                case .buildComplete:
                    isBuildRunning = false
                    buildPhase = "complete"
                    buildPercent = 100
                    hotReloadStatus = "watching"
                    Haptics.success()

                case .buildError:
                    isBuildRunning = false
                    buildPhase = "error"
                    if let msg = packet.payload?["message"] {
                        buildOutput.append("ERROR: \(msg)")
                    }
                    Haptics.error()

                case .hotReloadStatus:
                    hotReloadStatus = packet.payload?["status"] ?? "idle"
                    if let file = packet.payload?["file"] { lastInjectedFile = file }

                case .hotReloadInjection:
                    hotReloadInjectionCount += 1
                    if let file = packet.payload?["file"],
                       let duration = packet.payload?["durationMs"] {
                        buildOutput.append("Hot reloaded \(file) in \(duration)ms")
                    }
                    Haptics.light()

                case .hotReloadError:
                    hotReloadStatus = "error"
                    if let msg = packet.payload?["message"] {
                        buildOutput.append("Hot reload: \(msg)")
                    }
                    if packet.payload?["recoverable"] == "false" {
                        hotReloadStatus = "rebuild_needed"
                    }

                case .simulatorListResult:
                    if let json = packet.payload?["devices"],
                       let data = json.data(using: .utf8),
                       let list = try? JSONDecoder().decode([SimulatorDevice].self, from: data) {
                        availableSimulators = list
                    }

                case .simulatorStatus:
                    if let status = packet.payload?["status"] {
                        buildOutput.append("Simulator: \(status)")
                    }

                default:
                    break
                }
            }
        }
    }

    private func handleEngineOutput(_ packet: WSPacket) {
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

        let isForActiveTab = resolvedTabId == nil || resolvedTabId == currentTab.id
        let targetTabId = resolvedTabId ?? currentTab.id

        if isForActiveTab {
            isAgentThinking = false
        } else {
            updateBackgroundTabState(sessionId: sessionId) { $0.isThinking = false }
        }

        if let output = packet.payload?["output"] {
            if output.hasPrefix("🔧") {
                let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if isForActiveTab {
                    agentActivity = clean
                } else {
                    updateBackgroundTabState(sessionId: sessionId) { $0.activity = clean }
                }
                // Extract tool name (format: "🔧 ToolName: description")
                let withoutEmoji = clean.dropFirst(2) // Remove "🔧 "
                let toolName = String(withoutEmoji.prefix(while: { $0 != ":" })).trimmingCharacters(in: .whitespaces)
                if !toolName.isEmpty {
                    todoManager.updateTool(sessionId: sessionId, tool: toolName)
                }
                // Update Live Activity with current tool
                if let tool = AgentToolType.parse(from: clean) {
                    LiveActivityManager.shared.updateLastAgentMessage(workspaceId: workspace.id.uuidString, message: clean, tabId: targetTabId)
                    LiveActivityManager.shared.updateTool(workspaceId: workspace.id.uuidString, tool: tool, tabId: targetTabId, contextPercent: contextPercent)
                }
            } else if output == "📋CLEAR" {
                // Clear activity narration (final message being promoted to chat)
                if isForActiveTab {
                    activityLines = []
                    agentActivity = nil
                } else {
                    updateBackgroundTabState(sessionId: sessionId) { $0.activityLines = []; $0.activity = nil }
                }
            } else if output.hasPrefix("📋") {
                // Activity narration from Codex — show as collapsible activity, not chat bubble
                let text = String(output.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) // 📋 (1 char) + space
                if !text.isEmpty {
                    if isForActiveTab {
                        activityLines.append(text)
                        agentActivity = text
                    } else {
                        updateBackgroundTabState(sessionId: sessionId) { state in
                            state.activityLines.append(text)
                            state.activity = text
                        }
                    }
                }
            } else {
                if isForActiveTab {
                    agentActivity = nil
                    activityLines = []
                } else {
                    updateBackgroundTabState(sessionId: sessionId) { $0.activity = nil; $0.activityLines = [] }
                }
                chatService.addAssistantChunk(workspaceId: workspace.id, tabId: targetTabId, content: output)
                // Parse tool from raw output too
                if let tool = AgentToolType.parse(from: output) {
                    LiveActivityManager.shared.updateTool(workspaceId: workspace.id.uuidString, tool: tool, tabId: targetTabId, contextPercent: contextPercent)
                }
            }
        }
    }

    private func handleEngineAskUser(_ packet: WSPacket) {
        let sessionId = packet.payload?["sessionId"] ?? currentTab.sessionId ?? ""
        let isForActiveTab = isActiveTabSession(packet)
        todoManager.markQuestion(sessionId: sessionId)

        if isForActiveTab {
            isAgentThinking = false
        } else {
            updateBackgroundTabState(sessionId: sessionId) { $0.isThinking = false }
        }

        // Track permission request ID if this is a permission prompt (only for active tab)
        if isForActiveTab {
            if packet.payload?["isPermission"] == "true" {
                pendingPermissionRequestId = packet.payload?["permissionRequestId"]
                pendingQuestionId = packet.payload?["questionId"]
            } else {
                pendingPermissionRequestId = nil
                pendingQuestionId = nil
            }
        }

        // Update Live Activity to waiting (scoped to tab) with question text for the alert
        var questionText: String?
        var questionKey: String?
        var questionOptions: [String]?
        if let questionsJson = packet.payload?["questions"],
           let questionsData = questionsJson.data(using: .utf8),
           let questions = try? JSONDecoder().decode([InteractiveQuestion].self, from: questionsData) {
            questionText = questions.first?.question
            // For Live Activity interactive buttons: only for single, simple questions (≤4 options, single-select)
            if questions.count == 1 && !questions[0].multiSelect && questions[0].options.count <= 4 && !questions[0].options.isEmpty {
                questionKey = questions[0].question
                questionOptions = questions[0].options
            }
            if !questions.isEmpty {
                if isForActiveTab {
                    withAnimation {
                        interactiveOptions = nil
                        interactiveQuestions = questions
                    }
                } else {
                    updateBackgroundTabState(sessionId: sessionId) { state in
                        state.options = nil
                        state.questions = questions
                    }
                }
            }
        }
        let askTabId = tabId(forSession: sessionId) ?? currentTab.id
        let engineType = currentTab.engineType?.rawValue ?? "claude"
        LiveActivityManager.shared.updateStatus(
            workspaceId: workspace.id.uuidString,
            status: "waiting",
            tabId: askTabId,
            message: questionText,
            sessionId: sessionId,
            engineType: engineType,
            questionKey: questionKey,
            questionOptions: questionOptions,
            permissionRequestId: pendingPermissionRequestId
        )
    }

    private var engineDisplayName: String {
        let engine = currentTab.engineType ?? .claude
        if engineModel.isEmpty { return engine.displayName }
        // Shorten model name: "claude-opus-4-6" -> "Opus 4.6"
        let model = engineModel
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-?20\\d{6}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(\\d)-(\\d)", with: "$1.$2", options: .regularExpression)
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

    /// Wires `voiceRecorder` callbacks to chat input state. Called once in onAppear.
    private func configureVoiceRecorder() {
        voiceRecorder.onStart = {
            textBeforeVoice = messageText
            if voiceRecorder.voiceInput.needsLanguageSelection {
                // First run — immediately tear down and ask for language.
                voiceRecorder.voiceInput.stopRecording(commit: false, completion: nil)
                showLanguagePicker = true
            }
        }
        voiceRecorder.onPartial = { partial in
            messageText = textBeforeVoice + (textBeforeVoice.isEmpty ? "" : " ") + partial
        }
        voiceRecorder.onCommit = { finalText in
            messageText = textBeforeVoice + (textBeforeVoice.isEmpty ? "" : " ") + finalText
        }
        voiceRecorder.onCancel = {
            // Slid-to-cancel — revert the text input to what it was before recording.
            messageText = textBeforeVoice
        }
    }

    private func pickLanguageAndStart(_ code: String) {
        voiceRecorder.voiceInput.setLanguage(code)
        voiceRecorder.voiceInput.needsLanguageSelection = false
        showLanguagePicker = false
        // User already released the button; they'll need to press again to record.
        // Previous behavior auto-started here but that's jarring on first run.
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
        case buildAndRun
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
                        .font(TarsyTheme.font(size: 10))
                case .engine:
                    AgentIcon(engineType: tab.engineType ?? .custom, size: 12)
                case .terminal:
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.caption2)
                case .buildAndRun:
                    Image(systemName: "hammer.fill")
                        .font(.caption2)
                }

                Text(tab.title)
                    .font(TarsyTheme.monoFontSmall)

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(TarsyTheme.font(size: 8))
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

    private enum ContentSegment {
        case text(String)
        case codeBlock(language: String?, code: String)
    }

    private let parsedSegments: [(offset: Int, segment: ContentSegment)]

    init(message: ChatMessage) {
        self.message = message
        self.parsedSegments = Self.parseSegments(message.content)
    }

    private static func parseSegments(_ content: String) -> [(offset: Int, segment: ContentSegment)] {
        var result: [ContentSegment] = []
        var remaining = content[...]

        while let tripleBacktickRange = remaining.range(of: "```") {
            let textBefore = String(remaining[remaining.startIndex..<tripleBacktickRange.lowerBound])
            if !textBefore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.text(textBefore))
            }

            let afterOpening = remaining[tripleBacktickRange.upperBound...]
            // Extract optional language hint on the opening line
            var language: String? = nil
            if let newline = afterOpening.firstIndex(of: "\n") {
                let langHint = afterOpening[afterOpening.startIndex..<newline]
                    .trimmingCharacters(in: .whitespaces)
                if !langHint.isEmpty && !langHint.contains(" ") {
                    language = langHint
                }
            }

            // Closing ``` must be at start of a line to avoid matching inner backticks
            if let closingRange = afterOpening.range(of: "\n```") {
                var codeStart = afterOpening.startIndex
                // Skip the language line if present
                if let newline = afterOpening.firstIndex(of: "\n"),
                   newline < closingRange.lowerBound {
                    codeStart = afterOpening.index(after: newline)
                }
                let code = String(afterOpening[codeStart..<closingRange.lowerBound])
                    .trimmingCharacters(in: .newlines)
                result.append(.codeBlock(language: language, code: code))
                // Skip past the closing \n```
                let afterClosing = afterOpening.index(closingRange.upperBound, offsetBy: 0)
                remaining = afterOpening[afterClosing...]
            } else {
                // No closing ```, treat rest as code block
                var codeStart = afterOpening.startIndex
                if let newline = afterOpening.firstIndex(of: "\n") {
                    codeStart = afterOpening.index(after: newline)
                }
                let code = String(afterOpening[codeStart...])
                    .trimmingCharacters(in: .newlines)
                result.append(.codeBlock(language: language, code: code))
                remaining = afterOpening[afterOpening.endIndex...]
            }
        }

        let trailing = String(remaining)
        if !trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.text(trailing))
        }

        if result.isEmpty {
            result.append(.text(content))
        }

        return result.enumerated().map { ($0.offset, $0.element) }
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.role == .user ? "you" : "agent")
                    .font(TarsyTheme.font(size: 9))
                    .foregroundColor(TarsyTheme.textSecondary.opacity(0.6))

                if message.role == .user {
                    Text(message.content)
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.backgroundPrimary)
                        .padding(10)
                        .background(TarsyTheme.accentAmber)
                        .cornerRadius(10)
                        .textSelection(.enabled)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(parsedSegments, id: \.offset) { item in
                            switch item.segment {
                            case .text(let text):
                                Text(text)
                                    .font(TarsyTheme.monoFontSmall)
                                    .foregroundColor(TarsyTheme.textPrimary)

                            case .codeBlock(let language, let code):
                                CodeBlockView(language: language, code: code)
                            }
                        }
                    }
                    .padding(10)
                    .background(TarsyTheme.backgroundSecondary)
                    .cornerRadius(10)
                    .textSelection(.enabled)
                }
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                if let language {
                    Text(language)
                        .font(TarsyTheme.font(size: 9))
                        .foregroundColor(TarsyTheme.textSecondary)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    Haptics.light()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copied ? "copied" : "copy")
                            .font(TarsyTheme.font(size: 9))
                    }
                    .foregroundColor(copied ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(TarsyTheme.backgroundPrimary.opacity(0.6))

            // Code content
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(TarsyTheme.textPrimary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(TarsyTheme.backgroundPrimary)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(TarsyTheme.backgroundTertiary, lineWidth: 1)
        )
    }
}

private struct ChatSkeletonView: View {
    @State private var shimmer = false

    private let lines: [(isUser: Bool, widths: [CGFloat])] = [
        (false, [180, 140]),
        (true, [120]),
        (false, [200, 160, 100]),
        (true, [150]),
        (false, [170, 130]),
    ]

    var body: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            HStack {
                if line.isUser { Spacer(minLength: 60) }

                VStack(alignment: line.isUser ? .trailing : .leading, spacing: 4) {
                    skeletonPill(width: 36, height: 8)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(line.widths.enumerated()), id: \.offset) { _, w in
                            skeletonPill(width: w, height: 10)
                        }
                    }
                    .padding(10)
                    .background(line.isUser ? TarsyTheme.accentAmber.opacity(0.15) : TarsyTheme.backgroundSecondary)
                    .cornerRadius(10)
                }

                if !line.isUser { Spacer(minLength: 60) }
            }
        }
        .onAppear { shimmer = true }
    }

    private func skeletonPill(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(TarsyTheme.backgroundTertiary)
            .frame(width: width, height: height)
            .opacity(shimmer ? 0.4 : 0.8)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: shimmer)
    }
}
