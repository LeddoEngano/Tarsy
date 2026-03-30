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
    @AppStorage("hasSeenNotificationPrimer") private var hasSeenNotificationPrimer = false

    var body: some View {
        ZStack {
            Group {
                if authManager.isLoading {
                    SplashView()
                } else if authManager.isAuthenticated {
                    VStack(spacing: 0) {
                        StatusBanner()
                        DashboardView()
                    }
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
    }

    private func checkOnboardingState() {
        if let profile = profileService.profile {
            if profile.onboarded {
                showPermissionOnboarding = false
            }
            if profile.displayName == nil || profile.displayName?.isEmpty == true {
                showNameOnboarding = true
            }
        }
    }

    private func autoConnect() async {
        await machineService.fetchMachine()

        guard machineService.isOnline else {
            print("[AutoConnect] Mac is offline, skipping connection")
            return
        }

        await connectToMachine()
    }

    /// Connect without re-fetching machine status (used when onChange already confirmed online)
    private func connectToMachine() async {
        do {
            let session = try await supabase.auth.session
            let lanHost = machineService.bestIP
            print("[AutoConnect] LAN host: \(lanHost ?? "none"), using smart connect...")

            connectionManager.smartConnect(
                lanHost: lanHost,
                port: TarsyConfig.websocketPort,
                token: session.accessToken
            )
        } catch {
            print("[AutoConnect] Failed: \(error)")
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
