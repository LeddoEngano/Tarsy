import SwiftUI
import TarsyShared

struct WorkspaceView: View {
    let workspace: Workspace
    @State private var selectedTab = 0
    @State private var tabs: [TerminalTab] = [
        TerminalTab(id: "openclaw", title: "OpenClaw", isFixed: true),
        TerminalTab(id: "claude-1", title: "Claude Code", isFixed: false)
    ]
    @State private var messageText = ""
    @State private var messages: [ChatMessage] = []
    @State private var isStreamActive = false

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Stream area
                StreamView(isActive: $isStreamActive, workspace: workspace)
                    .frame(maxWidth: .infinity)
                    .frame(height: UIScreen.main.bounds.height * 0.4)

                // Tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                            TabButton(
                                tab: tab,
                                isSelected: selectedTab == index,
                                action: { selectedTab = index }
                            )
                        }

                        Button(action: { addTab() }) {
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

                Divider()
                    .background(TarsyTheme.backgroundTertiary)

                // Chat area
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(messages) { message in
                                    MessageBubble(message: message)
                                        .id(message.id)
                                }
                            }
                            .padding(12)
                        }
                        .onChange(of: messages.count) { _, _ in
                            if let last = messages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }

                    // Input
                    HStack(spacing: 8) {
                        TextField("", text: $messageText, prompt: Text("send a command...").foregroundColor(TarsyTheme.textSecondary))
                            .textFieldStyle(.plain)
                            .font(TarsyTheme.monoFont)
                            .foregroundColor(TarsyTheme.textPrimary)
                            .padding(12)
                            .background(TarsyTheme.backgroundSecondary)
                            .cornerRadius(8)

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
        }
        .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        let msg = ChatMessage(
            workspaceId: workspace.id,
            tabId: tabs[selectedTab].id,
            role: .user,
            content: messageText
        )
        messages.append(msg)
        messageText = ""
        // TODO: Send via WebSocket to Mac
    }

    private func addTab() {
        let count = tabs.filter { !$0.isFixed }.count + 1
        let tab = TerminalTab(id: "claude-\(count)", title: "Claude Code \(count)", isFixed: false)
        tabs.append(tab)
        selectedTab = tabs.count - 1
    }
}

struct TerminalTab: Identifiable {
    let id: String
    let title: String
    let isFixed: Bool
}

struct TabButton: View {
    let tab: TerminalTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if tab.isFixed {
                    Image(systemName: "terminal")
                        .font(.caption2)
                }
                Text(tab.title)
                    .font(TarsyTheme.monoFontSmall)
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

            Text(message.content)
                .font(TarsyTheme.monoFontSmall)
                .foregroundColor(message.role == .user ? TarsyTheme.backgroundPrimary : TarsyTheme.textPrimary)
                .padding(10)
                .background(message.role == .user ? TarsyTheme.accentAmber : TarsyTheme.backgroundSecondary)
                .cornerRadius(10)

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}

struct StreamView: View {
    @Binding var isActive: Bool
    let workspace: Workspace

    var body: some View {
        ZStack {
            TarsyTheme.backgroundSecondary

            if isActive {
                // TODO: WebRTC stream view
                Text("stream active")
                    .font(TarsyTheme.monoFont)
                    .foregroundColor(TarsyTheme.textSecondary)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "eye")
                        .font(.system(size: 40))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))

                    Text("stream offline")
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(TarsyTheme.textSecondary)

                    Button(action: { isActive = true }) {
                        Text("start stream")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.accentAmber)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(TarsyTheme.accentAmber, lineWidth: 1)
                            )
                    }
                }
            }
        }
        .cornerRadius(12)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
