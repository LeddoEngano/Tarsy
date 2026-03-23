import SwiftUI
import TarsyShared

struct ContentView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var machineService: MachineService

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
            if isAuth {
                Task { await autoConnect() }
            }
        }
    }

    private func autoConnect() async {
        await machineService.fetchMachine()
        guard let ip = machineService.tailscaleIP else { return }

        do {
            let session = try await supabase.auth.session
            connectionManager.connect(
                to: ip,
                port: TarsyConfig.websocketPort,
                token: session.accessToken
            )
        } catch {
            print("[AutoConnect] Failed: \(error)")
        }
    }
}
