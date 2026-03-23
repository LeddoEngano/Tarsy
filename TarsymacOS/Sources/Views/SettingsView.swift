import SwiftUI
import TarsyShared

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var daemonManager: DaemonManager
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        TabView {
            // Account tab
            VStack(spacing: 16) {
                if authManager.isAuthenticated {
                    Text("Signed in as:")
                        .font(.system(size: 12, design: .monospaced))
                    Text(authManager.currentUser?.email ?? "unknown")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))

                    Button("Sign Out") {
                        Task { await authManager.signOut() }
                    }
                } else {
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    if let error = authManager.errorMessage {
                        Text(error)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.red)
                    }

                    Button("Sign In") {
                        Task {
                            await authManager.signIn(email: email, password: password)
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty)
                }
            }
            .padding(24)
            .frame(width: 350, height: 200)
            .tabItem {
                Label("Account", systemImage: "person")
            }

            // Connection tab
            VStack(spacing: 16) {
                HStack {
                    Text("Tailscale:")
                        .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text(daemonManager.tailscaleStatus)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Tailscale IP:")
                        .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text(daemonManager.tailscaleIP ?? "n/a")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("WebSocket Port:")
                        .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text("\(TarsyConfig.websocketPort)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Clients:")
                        .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text("\(daemonManager.connectedClients)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(24)
            .frame(width: 350, height: 200)
            .tabItem {
                Label("Connection", systemImage: "network")
            }
        }
    }
}
