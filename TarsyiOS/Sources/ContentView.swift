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
                        if !machineService.hasTailscale && machineService.localIP == nil {
                            tailscaleBanner
                        }
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
            checkTailscale()
        }
    }

    private var tailscaleBanner: some View {
        Button(action: {
            if let url = URL(string: "https://apps.apple.com/app/tailscale/id1470499037") {
                UIApplication.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text("install tailscale for remote access")
                        .font(.system(size: 11, design: .monospaced))
                    Text("tap to open app store (free)")
                        .font(.system(size: 9, design: .monospaced))
                        .opacity(0.7)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
            }
            .foregroundColor(TarsyTheme.accentAmber)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(TarsyTheme.accentAmber.opacity(0.1))
        }
    }

    private func checkTailscale() {
        if let url = URL(string: "tailscale://") {
            machineService.setTailscaleInstalled(UIApplication.shared.canOpenURL(url))
        }
    }

    private func autoConnect() async {
        checkTailscale()
        await machineService.fetchMachine()

        guard let ip = machineService.bestIP else {
            print("[AutoConnect] No IP available (tailscale: \(machineService.tailscaleIP ?? "nil"), local: \(machineService.localIP ?? "nil"))")
            return
        }

        print("[AutoConnect] Connecting to \(ip):\(TarsyConfig.websocketPort)")

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
