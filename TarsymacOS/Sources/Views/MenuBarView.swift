import SwiftUI
import TarsyShared

struct MenuBarView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var daemonManager: DaemonManager
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("TARSY")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))

                Spacer()

                Circle()
                    .fill(daemonManager.isRunning ? .green : .red)
                    .frame(width: 8, height: 8)

                Text(daemonManager.isRunning ? "online" : "offline")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Divider()

            if !authManager.isAuthenticated {
                Button("Sign In...") {
                    openWindow(id: "onboarding")
                }
                .font(.system(size: 12, design: .monospaced))
            } else {
                // Active workspaces
                if daemonManager.activeWorkspaces.isEmpty {
                    Text("no active workspaces")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(daemonManager.activeWorkspaces) { workspace in
                        HStack {
                            Circle()
                                .fill(workspace.status == .running ? .green : .orange)
                                .frame(width: 6, height: 6)
                            Text(workspace.name)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Text(workspace.status.rawValue)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Divider()

                // Stats
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("tailscale:")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(daemonManager.tailscaleStatus)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("ws port:")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("\(TarsyConfig.websocketPort)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("clients:")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("\(daemonManager.connectedClients)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let err = daemonManager.lastError {
                Divider()
                Text(err)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.red)
                    .lineLimit(3)
            }

            if !daemonManager.debugLog.isEmpty {
                Divider()
                ScrollView {
                    Text(daemonManager.debugLog)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }

            Divider()

            Button("Open Setup...") {
                openWindow(id: "onboarding")
            }
            .font(.system(size: 12, design: .monospaced))

            Button("Settings...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .font(.system(size: 12, design: .monospaced))

            Divider()

            Button("Quit Tarsy") {
                daemonManager.stop()
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 12, design: .monospaced))
        }
        .padding(16)
        .frame(width: 280)
        .task {
            if authManager.isAuthenticated {
                await daemonManager.start()
            }
        }
    }
}
