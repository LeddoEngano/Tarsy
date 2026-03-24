import SwiftUI
import TarsyShared

struct ContentView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var machineService: MachineService

    @State private var showSudoAlert = false
    @State private var sudoPassword = ""
    @State private var sudoReason = ""
    @State private var sudoRequestId = ""

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
        .preferredColorScheme(.dark)
        .onChange(of: authManager.isAuthenticated) { _, isAuth in
            if isAuth && !connectionManager.isConnected {
                Task { await autoConnect() }
            }
        }
        .onChange(of: authManager.isLoading) { _, isLoading in
            if !isLoading && authManager.isAuthenticated && !connectionManager.isConnected {
                Task { await autoConnect() }
            }
        }
        .onAppear {
            connectionManager.onSudoRequest = { packet in
                sudoReason = packet.payload?["reason"] ?? "A command requires administrator privileges."
                sudoRequestId = packet.id
                showSudoAlert = true
            }
        }
        .alert("Administrator Password", isPresented: $showSudoAlert) {
            SecureField("Password", text: $sudoPassword)
            Button("OK") {
                connectionManager.send(WSPacket(
                    action: .sudoResponse,
                    payload: ["password": sudoPassword],
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
    }

    private func autoConnect() async {
        await machineService.fetchMachine()

        do {
            let session = try await supabase.auth.session

            // Smart connect: try LAN first (if on same subnet), fallback to relay
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
