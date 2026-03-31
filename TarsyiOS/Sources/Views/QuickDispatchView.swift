import SwiftUI
import TarsyShared

struct QuickDispatchView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var connectionManager: ConnectionManager

    let workspaces: [Workspace]
    @State private var selectedWorkspace: Workspace?
    @State private var command = ""
    @State private var isSending = false
    @FocusState private var isCommandFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary.ignoresSafeArea()

                VStack(spacing: 20) {
                    // Workspace selector
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WORKSPACE")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(workspaces) { ws in
                                    Button {
                                        selectedWorkspace = ws
                                    } label: {
                                        Text(ws.name)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(selectedWorkspace?.id == ws.id ? TarsyTheme.backgroundPrimary : TarsyTheme.textPrimary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(selectedWorkspace?.id == ws.id ? TarsyTheme.accentAmber : TarsyTheme.backgroundSecondary)
                                            .cornerRadius(8)
                                    }
                                }
                            }
                        }
                    }

                    // Command input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("COMMAND")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)

                        TextEditor(text: $command)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(TarsyTheme.textPrimary)
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .frame(minHeight: 100, maxHeight: 200)
                            .background(TarsyTheme.backgroundSecondary)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(TarsyTheme.backgroundTertiary, lineWidth: 1)
                            )
                            .focused($isCommandFocused)
                    }

                    // Send button
                    Button {
                        dispatch()
                    } label: {
                        HStack(spacing: 8) {
                            if isSending {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(TarsyTheme.backgroundPrimary)
                            } else {
                                Image(systemName: "bolt.fill")
                            }
                            Text(isSending ? "dispatching..." : "dispatch")
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(TarsyTheme.backgroundPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canSend ? TarsyTheme.accentAmber : TarsyTheme.backgroundTertiary)
                        .cornerRadius(12)
                    }
                    .disabled(!canSend)

                    Text("The agent will run in the background. You'll get a push notification when it needs input or finishes.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .multilineTextAlignment(.center)

                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle("quick dispatch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("cancel") { dismiss() }
                        .foregroundColor(TarsyTheme.accentAmber)
                }
            }
            .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            selectedWorkspace = workspaces.first
            isCommandFocused = true
        }
    }

    private var canSend: Bool {
        selectedWorkspace != nil && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func dispatch() {
        guard let ws = selectedWorkspace else { return }
        let msg = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }

        isSending = true

        let dispatchTabId = "dispatch-\(UUID().uuidString.prefix(8))"

        // Start Live Activity for dispatched task
        LiveActivityManager.shared.startActivity(
            workspaceId: ws.id.uuidString,
            workspaceName: ws.name,
            engineType: .claude,
            tabId: dispatchTabId
        )

        // Send engineCreate with initial message — the macOS side will create the session
        connectionManager.send(WSPacket(
            action: .engineCreate,
            payload: [
                "path": ws.localPath,
                "engineType": "claude",
                "aiContext": ws.aiContext ?? "",
                "message": msg,
                "workspaceId": ws.id.uuidString,
                "tabId": dispatchTabId
            ]
        ))

        // Dismiss after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            dismiss()
        }
    }
}

#if DEBUG
#Preview {
    QuickDispatchView(workspaces: [PreviewData.workspace, PreviewData.idleWorkspace])
        .environmentObject(ConnectionManager())
        .preferredColorScheme(.dark)
}
#endif
