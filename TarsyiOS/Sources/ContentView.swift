import SwiftUI
import TarsyShared

struct ContentView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var machineService: MachineService
    @EnvironmentObject var profileService: ProfileService

    @State private var showSudoAlert = false
    @State private var showSudoE2EError = false
    @State private var sudoPassword = ""
    @State private var sudoReason = ""
    @State private var sudoRequestId = ""
    @State private var showPermissionOnboarding = !AgentPermissionConfig.hasBeenConfigured
    @State private var showNameOnboarding = false
    @State private var showNotificationPrimer = false
    @State private var isAutoConnecting = false
    @AppStorage("hasSeenNotificationPrimer") private var hasSeenNotificationPrimer = false

    /// Safety net for unexpected system dialogs on the Mac (TCC /
    /// Automation / Keychain prompts that slipped past onboarding).
    /// Surfaces a banner + sheet so the user can approve them without
    /// being at the Mac.
    @StateObject private var systemDialogService = SystemDialogService()
    @State private var showSystemDialogSheet = false

    var body: some View {
        ZStack {
            Group {
                if authManager.isLoading {
                    SplashView()
                } else if authManager.isAuthenticated {
                    VStack(spacing: 0) {
                        StatusBanner()
                        SystemDialogBanner(
                            service: systemDialogService,
                            showSheet: $showSystemDialogSheet
                        )
                        DashboardView()
                    }
                    .environmentObject(systemDialogService)
                } else {
                    LoginView()
                }
            }
        }
        .fullScreenCover(isPresented: $showNameOnboarding) {
            NameOnboardingView {
                showNameOnboarding = false
            }
            .environmentObject(profileService)
        }
        .fullScreenCover(isPresented: $showPermissionOnboarding) {
            PermissionOnboardingView {
                showPermissionOnboarding = false
                if !hasSeenNotificationPrimer {
                    showNotificationPrimer = true
                }
            }
        }
        .fullScreenCover(isPresented: $showNotificationPrimer) {
            NotificationPrimerView {
                hasSeenNotificationPrimer = true
                showNotificationPrimer = false
            }
        }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onChange(of: machineService.isOnline) { _, isOnline in
            if !isOnline && connectionManager.isConnected {
                connectionManager.disconnect()
            } else if isOnline && !connectionManager.isConnected && authManager.isAuthenticated {
                Task { await connectToMachine() }
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuth in
            if isAuth {
                Task {
                    await AppDelegate.savePushTokenIfNeeded()
                    await profileService.loadProfile()
                    checkOnboardingState()
                    if !connectionManager.isConnected {
                        await autoConnect()
                    }
                }
            }
        }
        .onChange(of: authManager.isLoading) { _, isLoading in
            if !isLoading && authManager.isAuthenticated {
                Task {
                    if profileService.profile == nil {
                        await profileService.loadProfile()
                    }
                    checkOnboardingState()
                    if !connectionManager.isConnected {
                        await autoConnect()
                    }
                }
            }
        }
        .onAppear {
            connectionManager.onSudoRequest = { packet in
                sudoReason = packet.payload?["reason"] ?? "A command requires administrator privileges."
                sudoRequestId = packet.id
                showSudoAlert = true
            }
            connectionManager.onReconnected = { [weak connectionManager] in
                // Re-request workspace state so UI syncs after reconnection
                connectionManager?.send(WSPacket(action: .workspaceList))
            }
            // Attach the system dialog safety net to the active
            // connection. `attach` re-subscribes idempotently so it's
            // safe to call on every onAppear.
            systemDialogService.attach(to: connectionManager)

            // Global listener for Live Activity updates — runs even when WorkspaceView is not on screen.
            // This catches engineComplete/engineError replayed on reconnect so activities don't stay stuck.
            connectionManager.addListener("live-activity-global") { packet in
                Task { @MainActor in
                    switch packet.action {
                    case .engineComplete, .claudeComplete:
                        let wsId = packet.payload?["workspaceId"] ?? ""
                        if !wsId.isEmpty {
                            LiveActivityManager.shared.endActivity(workspaceId: wsId)
                        }
                    case .engineError:
                        let wsId = packet.payload?["workspaceId"] ?? ""
                        if !wsId.isEmpty {
                            LiveActivityManager.shared.endActivity(workspaceId: wsId, status: "error")
                        }
                    default:
                        break
                    }
                }
            }
        }
        .alert("Administrator Password", isPresented: $showSudoAlert) {
            SecureField("Password", text: $sudoPassword)
            Button("OK") {
                guard connectionManager.e2e.isReady,
                      let encrypted = connectionManager.e2e.encrypt(sudoPassword) else {
                    sudoPassword = ""
                    showSudoE2EError = true
                    return
                }
                connectionManager.send(WSPacket(
                    action: .sudoResponse,
                    payload: ["encryptedPassword": encrypted],
                    id: sudoRequestId
                ))
                sudoPassword = ""
            }
            Button("Cancel", role: .cancel) {
                connectionManager.send(WSPacket(
                    action: .sudoResponse,
                    payload: [:],
                    id: sudoRequestId
                ))
                sudoPassword = ""
            }
        } message: {
            Text(sudoReason)
        }
        .alert("Secure Connection Required", isPresented: $showSudoE2EError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Cannot send password — encrypted connection not established. Please reconnect and try again.")
        }
        .sheet(isPresented: $showSystemDialogSheet) {
            if let dialog = systemDialogService.currentDialog {
                SystemDialogSheet(dialog: dialog) { label in
                    systemDialogService.click(label, on: dialog)
                    showSystemDialogSheet = false
                }
            }
        }
    }

    private func checkOnboardingState() {
        guard let profile = profileService.profile else { return }

        if profile.onboarded {
            showPermissionOnboarding = false
        }

        if profile.displayName == nil || profile.displayName?.isEmpty == true {
            // Auto-populate from Apple/GitHub metadata if available
            Task {
                // Try full_name first (Apple Sign In), then name or user_name (GitHub)
                let session = try? await supabase.auth.session
                let meta = session?.user.userMetadata
                let fullName: String? = (meta?["full_name"]?.value as? String)
                    ?? (meta?["name"]?.value as? String)
                    ?? (meta?["user_name"]?.value as? String)

                if let fullName, !fullName.isEmpty {
                    await profileService.updateDisplayName(fullName)
                } else {
                    showNameOnboarding = true
                }
            }
        }
    }

    private func autoConnect() async {
        guard !isAutoConnecting && !connectionManager.isConnected else { return }
        isAutoConnecting = true
        defer { isAutoConnecting = false }

        await machineService.fetchMachine()

        guard machineService.isOnline else {
#if DEBUG
            print("[AutoConnect] Mac is offline, skipping connection")
#endif
            return
        }

        await connectToMachine()
    }

    /// Connect without re-fetching machine status (used when onChange already confirmed online)
    private func connectToMachine() async {
        guard !connectionManager.isConnected else { return }
        do {
            let session = try await supabase.auth.session
            let lanHost = machineService.bestIP
#if DEBUG
            print("[AutoConnect] LAN host: \(lanHost ?? "none")")
#endif

            connectionManager.smartConnect(
                lanHost: lanHost,
                port: TarsyConfig.websocketPort,
                token: session.accessToken
            )
        } catch {
#if DEBUG
            print("[AutoConnect] Failed: \(error)")
#endif
        }
    }
}

#if DEBUG
#Preview {
    PreviewWrapper {
        ContentView()
    }
}
#endif
