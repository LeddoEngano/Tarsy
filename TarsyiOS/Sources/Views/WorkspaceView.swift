import SwiftUI
import TarsyShared

struct WorkspaceView: View {
    let workspace: Workspace
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var machineService: MachineService
    @EnvironmentObject var workspaceService: WorkspaceService

    @State private var selectedTabIndex = 0
    @State private var tabs: [TerminalTab] = [
        TerminalTab(id: "openclaw", title: "OpenClaw", isFixed: true, type: .openclaw),
        TerminalTab(id: "claude-1", title: "Claude Code", isFixed: false, type: .claude, sessionId: nil)
    ]
    @State private var messageText = ""
    @State private var isStreamActive = false
    @StateObject private var chatService = ChatService()

    private var currentTab: TerminalTab {
        tabs[selectedTabIndex]
    }

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Stream area
                StreamPlayerView(workspace: workspace, isActive: $isStreamActive)
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.height * 0.35)

                // Tabs bar
                tabBar

                Divider().background(TarsyTheme.backgroundTertiary)

                // Chat area
                chatArea

                // Input bar
                inputBar
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
                Menu {
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

                Button(action: { addClaudeTab() }) {
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

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(chatService.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: chatService.messages.count) { _, _ in
                if let last = chatService.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("", text: $messageText, prompt: Text("send a command...").foregroundColor(TarsyTheme.textSecondary))
                .textFieldStyle(.plain)
                .font(TarsyTheme.monoFont)
                .foregroundColor(TarsyTheme.textPrimary)
                .padding(12)
                .background(TarsyTheme.backgroundSecondary)
                .cornerRadius(8)
                .onSubmit { sendMessage() }

            Button(action: { sendMessage() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(messageText.isEmpty ? TarsyTheme.textSecondary : TarsyTheme.accentAmber)
            }
            .disabled(messageText.isEmpty)
        }
        .padding(12)
        .background(TarsyTheme.backgroundPrimary)
    }

    // MARK: - Actions

    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        let text = messageText
        messageText = ""

        let msg = ChatMessage(
            workspaceId: workspace.id,
            tabId: currentTab.id,
            role: .user,
            content: text
        )

        Task {
            await chatService.addMessage(msg)

            if currentTab.type == .claude {
                if let sessionId = currentTab.sessionId {
                    // Send to existing Claude session
                    connectionManager.send(WSPacket(
                        action: .claudeMessage,
                        payload: ["sessionId": sessionId, "message": text]
                    ))
                } else {
                    // Create new Claude session
                    connectionManager.send(WSPacket(
                        action: .claudeCreate,
                        payload: [
                            "path": workspace.localPath,
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

    private func addClaudeTab() {
        let count = tabs.filter { $0.type == .claude }.count + 1
        let tab = TerminalTab(id: "claude-\(count)", title: "Claude \(count)", isFixed: false, type: .claude, sessionId: nil)
        tabs.append(tab)
        selectedTabIndex = tabs.count - 1
    }

    private func closeTab(at index: Int) {
        let tab = tabs[index]
        if let sessionId = tab.sessionId {
            if tab.type == .claude {
                connectionManager.send(WSPacket(action: .claudeClose, payload: ["sessionId": sessionId]))
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
        connectionManager.onPacketReceived = { [self] packet in
            Task { @MainActor in
                switch packet.action {
                case .claudeOutput:
                    if let output = packet.payload?["output"] {
                        chatService.addAssistantChunk(workspaceId: workspace.id, tabId: currentTab.id, content: output)
                    }
                case .claudeComplete:
                    await chatService.saveLastAssistantMessage()
                case .claudeCreate:
                    if let sessionId = packet.payload?["sessionId"] {
                        tabs[selectedTabIndex].sessionId = sessionId
                    }
                case .openclawOutput:
                    if let output = packet.payload?["output"] {
                        chatService.addAssistantChunk(workspaceId: workspace.id, tabId: "openclaw", content: output)
                    }
                case .openclawComplete:
                    await chatService.saveLastAssistantMessage()
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
}

// MARK: - Supporting Types

struct TerminalTab: Identifiable {
    let id: String
    let title: String
    let isFixed: Bool
    let type: TabType
    var sessionId: String?

    enum TabType {
        case openclaw
        case claude
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
            .cornerRadius(6)
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
