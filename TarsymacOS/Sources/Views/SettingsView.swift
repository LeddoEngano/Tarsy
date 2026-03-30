import SwiftUI
import TarsyShared

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var daemonManager: DaemonManager
    @State private var email = ""
    @State private var password = ""
    @State private var showDeleteConfirmation = false
    @State private var deleteConfirmText = ""
    @State private var isDeleting = false
    @State private var deleteError: String?

    private let profileService = ProfileService()

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

                    Divider()

                    // Legal links
                    HStack(spacing: 16) {
                        if let termsURL = URL(string: "https://www.tarsy.dev/terms") {
                            Link("Terms of Use", destination: termsURL)
                                .font(.system(size: 11, design: .monospaced))
                        }
                        if let privacyURL = URL(string: "https://www.tarsy.dev/privacy") {
                            Link("Privacy Policy", destination: privacyURL)
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }

                    Divider()

                    // Delete account
                    if isDeleting {
                        ProgressView("Deleting account...")
                            .font(.system(size: 11, design: .monospaced))
                    } else {
                        Button("Delete Account") {
                            showDeleteConfirmation = true
                        }
                        .foregroundColor(.red)
                    }

                    if let error = deleteError {
                        Text(error)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.red)
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
            .frame(width: 350, height: 280)
            .tabItem {
                Label("Account", systemImage: "person")
            }
            .alert("Delete Account", isPresented: $showDeleteConfirmation) {
                TextField("Type DELETE to confirm", text: $deleteConfirmText)
                Button("Delete", role: .destructive) {
                    if deleteConfirmText == "DELETE" {
                        isDeleting = true
                        deleteError = nil
                        Task {
                            do {
                                try await profileService.deleteAccount()
                                await authManager.signOut()
                            } catch {
                                deleteError = error.localizedDescription
                            }
                            isDeleting = false
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    deleteConfirmText = ""
                }
            } message: {
                Text("This will permanently delete your account and all data. This cannot be undone.")
            }

            // Connection tab
            VStack(spacing: 16) {
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
