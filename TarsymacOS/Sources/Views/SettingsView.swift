import SwiftUI
import TarsyShared
import AuthenticationServices

private enum Theme {
    static let bg = Color(hex: "131316")
    static let bgCard = Color(hex: "1c1c21")
    static let bgField = Color(hex: "18181c")
    static let border = Color(hex: "2a2a30")
    static let textPrimary = Color(hex: "e4e4e7")
    static let textSecondary = Color(hex: "71717a")
    static let textMuted = Color(hex: "52525b")
    static let amber = Color(hex: "ffffff")
    static let moss = Color(hex: "6bc77b")
    static let terracotta = Color(hex: "e5716a")
}

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var daemonManager: DaemonManager
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isSignUp = false
    @State private var showEmailForm = false
    @State private var showPassword = false
    @State private var appleSignInDelegate: AppleSignInDelegate?
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
        .frame(width: 420, height: 380)
        .onChange(of: authManager.isAuthenticated) { _, isAuth in
            if isAuth && !daemonManager.isRunning {
                Task { await daemonManager.start() }
            }
        }
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
        VStack(spacing: 0) {
            Spacer()

            // Profile card
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.border)
                        .frame(width: 52, height: 52)
                    Text(initials)
                        .font(TarsyTheme.font(size: 20, weight: .semibold))
                        .foregroundColor(Theme.amber)
                }

                Text(authManager.currentUser?.email ?? "unknown")
                    .font(TarsyTheme.font(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
            .padding(.bottom, 24)

            // Actions
            VStack(spacing: 12) {
                settingsButton(label: "Sign Out", icon: "rectangle.portrait.and.arrow.right") {
                    Task {
                        daemonManager.stop()
                        await authManager.signOut()
                    }
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
                            .font(TarsyTheme.font(size: 11))
                            .foregroundColor(Theme.terracotta.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .pointerOnHover()
                }

                if let error = deleteError {
                    Text(error)
                        .font(TarsyTheme.font(size: 10))
                        .foregroundColor(Theme.terracotta)
                        .lineLimit(2)
                }
            }
            .padding(.bottom, 20)
        }
    }

    private var signInView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 6) {
                Text("sign in")
                    .font(TarsyTheme.font(size: 16, weight: .bold))
                    .foregroundColor(Theme.textPrimary)

                Text("sign in to connect your devices")
                    .font(TarsyTheme.font(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.bottom, 16)

            if showEmailForm {
                VStack(spacing: 8) {
                    signInEmailForm

                    signInSubmitButton
                        .padding(.top, 6)

                    signInToggle

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) { showEmailForm = false }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(TarsyTheme.font(size: 9, weight: .medium))
                            Text("back")
                                .font(TarsyTheme.font(size: 11))
                        }
                        .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .pointerOnHover()
                    .padding(.top, 2)
                }
                .frame(maxWidth: 300)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 8) {
                    signInOAuthButtons

                    oauthButton(
                        icon: "envelope",
                        label: "Sign in with Email",
                        isSystemImage: true
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) { showEmailForm = true }
                    }
                }
                .frame(maxWidth: 300)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            Spacer()
        }
    }

    private var signInOAuthButtons: some View {
        VStack(spacing: 8) {
            oauthButton(
                icon: "apple.logo",
                label: "Sign in with Apple",
                isSystemImage: true
            ) {
                let provider = ASAuthorizationAppleIDProvider()
                let request = provider.createRequest()
                let nonce = authManager.generateNonce()
                request.requestedScopes = [.email, .fullName]
                request.nonce = authManager.sha256(nonce)
                let delegate = AppleSignInDelegate { result in
                    Task { await authManager.handleAppleSignIn(result: result) }
                }
                appleSignInDelegate = delegate
                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = delegate
                controller.presentationContextProvider = delegate
                controller.performRequests()
            }

            oauthButton(
                icon: "GitHubIcon",
                label: "Sign in with GitHub",
                isSystemImage: false
            ) {
                Task { await authManager.signInWithGitHub() }
            }
        }
    }

    @ViewBuilder
    private func oauthButton(icon: String, label: String, isSystemImage: Bool, action: @escaping () -> Void) -> some View {
        OAuthButtonView(icon: icon, label: label, isSystemImage: isSystemImage, action: action)
    }

    private var signInEmailForm: some View {
        VStack(spacing: 8) {
            signInStyledTextField("email", text: $email)
            signInStyledSecureField("password", text: $password)

            if isSignUp {
                signInStyledSecureField("confirm password", text: $confirmPassword)

                if !confirmPassword.isEmpty && confirmPassword != password {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(TarsyTheme.font(size: 10))
                        Text("passwords don't match")
                            .font(TarsyTheme.font(size: 11))
                    }
                    .foregroundColor(Theme.terracotta)
                    .padding(.top, 2)
                }
            }

            if let error = authManager.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(TarsyTheme.font(size: 10))
                    Text(error)
                        .font(TarsyTheme.font(size: 11))
                }
                .foregroundColor(Theme.terracotta)
                .padding(.top, 2)
            }
        }
    }

    private var signInSubmitButton: some View {
        Button(action: {
            Task {
                if isSignUp {
                    await authManager.signUp(email: email, password: password)
                } else {
                    await authManager.signIn(email: email, password: password)
                }
            }
        }) {
            HStack(spacing: 6) {
                if authManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                }
                Text(isSignUp ? "create account" : "sign in")
                    .font(TarsyTheme.font(size: 12, weight: .medium))
            }
            .foregroundColor(Theme.bg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(signInSubmitDisabled ? Theme.textMuted : Theme.amber)
            )
        }
        .buttonStyle(.plain)
        .pointerOnHover()
        .disabled(signInSubmitDisabled || authManager.isLoading)
    }

    private var signInSubmitDisabled: Bool {
        if email.isEmpty || password.isEmpty { return true }
        if isSignUp && confirmPassword != password { return true }
        return false
    }

    private var signInToggle: some View {
        Button(action: { isSignUp.toggle() }) {
            Text(isSignUp ? "already have an account? sign in" : "no account? sign up")
                .font(TarsyTheme.font(size: 11))
                .foregroundColor(Theme.textMuted)
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }

    private func signInStyledTextField(_ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope")
                .font(TarsyTheme.font(size: 12))
                .foregroundColor(Theme.textMuted)
                .frame(width: 16)
            TextField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.textMuted))
                .textFieldStyle(.plain)
                .font(TarsyTheme.font(size: 12))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.bgField)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
    }

    private func signInStyledSecureField(_ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .font(TarsyTheme.font(size: 12))
                .foregroundColor(Theme.textMuted)
                .frame(width: 16)

            if showPassword {
                TextField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.textMuted))
                    .textFieldStyle(.plain)
                    .font(TarsyTheme.font(size: 12))
                    .foregroundColor(Theme.textPrimary)
            } else {
                SecureField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.textMuted))
                    .textFieldStyle(.plain)
                    .font(TarsyTheme.font(size: 12))
                    .foregroundColor(Theme.textPrimary)
            }

            Button(action: { showPassword.toggle() }) {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .font(TarsyTheme.font(size: 11))
                    .foregroundColor(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .pointerOnHover()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.bgField)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
    }

    // MARK: - Connection

    private var connectionTab: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 12) {
                connectionRow(label: "WebSocket Port", value: "\(TarsyConfig.websocketPort)")
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
                .font(TarsyTheme.font(size: 12))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(TarsyTheme.font(size: 12, weight: .medium))
                .foregroundColor(valueColor)
        }
    }

    private func settingsButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(TarsyTheme.font(size: 11))
                Text(label)
                    .font(TarsyTheme.font(size: 12))
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
            .font(TarsyTheme.font(size: 11))
            .foregroundColor(Theme.textMuted)
            .underline(color: Theme.textMuted.opacity(0.5))
    }


    private var initials: String {
        let email = authManager.currentUser?.email ?? ""
        return String(email.prefix(2)).uppercased()
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView()
        .environmentObject(AuthManager())
        .environmentObject(DaemonManager())
}
#endif
