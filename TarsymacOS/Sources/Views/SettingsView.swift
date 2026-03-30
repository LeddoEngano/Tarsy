import SwiftUI
import TarsyShared

private enum Theme {
    static let bg = Color(hex: "1a1a1a")
    static let bgCard = Color(hex: "2a2a2a")
    static let bgField = Color(hex: "252525")
    static let border = Color(hex: "3a3a3a")
    static let textPrimary = Color(hex: "e8e0d4")
    static let textSecondary = Color(hex: "a89e91")
    static let textMuted = Color(hex: "6b6b6b")
    static let amber = Color(hex: "d4a574")
    static let moss = Color(hex: "7a8b6f")
    static let terracotta = Color(hex: "c4704b")
}

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
            accountTab
                .tabItem { Label("Account", systemImage: "person") }

            connectionTab
                .tabItem { Label("Connection", systemImage: "network") }
        }
        .frame(width: 420, height: 340)
    }

    // MARK: - Account

    private var accountTab: some View {
        VStack(spacing: 0) {
            if authManager.isAuthenticated {
                authenticatedView
            } else {
                signInView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
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
    }

    private var authenticatedView: some View {
        VStack(spacing: 16) {
            // Profile card
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Theme.border)
                        .frame(width: 48, height: 48)
                    Text(initials)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.amber)
                }

                Text(authManager.currentUser?.email ?? "unknown")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
            }
            .padding(.top, 24)

            // Actions
            VStack(spacing: 8) {
                settingsButton(label: "Sign Out", icon: "rectangle.portrait.and.arrow.right") {
                    Task { await authManager.signOut() }
                }

                HStack(spacing: 12) {
                    if let url = URL(string: "https://www.tarsy.dev/terms") {
                        Link(destination: url) {
                            linkLabel("Terms of Use")
                        }
                    }

                    Text("·")
                        .foregroundColor(Theme.textMuted)

                    if let url = URL(string: "https://www.tarsy.dev/privacy") {
                        Link(destination: url) {
                            linkLabel("Privacy Policy")
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)

            Spacer()

            // Danger zone
            VStack(spacing: 8) {
                if isDeleting {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Theme.terracotta)
                } else {
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Text("Delete Account")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.terracotta.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .pointerOnHover()
                }

                if let error = deleteError {
                    Text(error)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.terracotta)
                        .lineLimit(2)
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var signInView: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("sign in")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)

            VStack(spacing: 10) {
                styledTextField("email", text: $email)
                styledSecureField("password", text: $password)
            }
            .padding(.horizontal, 40)

            if let error = authManager.errorMessage {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.terracotta)
                    .padding(.horizontal, 40)
            }

            Button {
                Task { await authManager.signIn(email: email, password: password) }
            } label: {
                Text("Sign In")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(email.isEmpty || password.isEmpty ? Theme.textMuted : Theme.amber)
                    )
            }
            .buttonStyle(.plain)
            .pointerOnHover()
            .disabled(email.isEmpty || password.isEmpty)
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Connection

    private var connectionTab: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 12) {
                connectionRow(label: "WebSocket Port", value: "\(TarsyConfig.websocketPort)")
                connectionRow(label: "Connected Clients", value: "\(daemonManager.connectedClients)")
                connectionRow(
                    label: "Status",
                    value: daemonManager.isRunning ? "running" : "stopped",
                    valueColor: daemonManager.isRunning ? Theme.moss : Theme.terracotta
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.bgCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    // MARK: - Components

    private func connectionRow(label: String, value: String, valueColor: Color = Theme.textPrimary) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(valueColor)
        }
    }

    private func settingsButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12, design: .monospaced))
            }
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.bgCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }

    private func linkLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Theme.textMuted)
            .underline(color: Theme.textMuted.opacity(0.5))
    }

    private func styledTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.textMuted))
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(Theme.textPrimary)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.bgField)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )
    }

    private func styledSecureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.textMuted))
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(Theme.textPrimary)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.bgField)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )
    }

    private var initials: String {
        let email = authManager.currentUser?.email ?? ""
        return String(email.prefix(2)).uppercased()
    }
}
