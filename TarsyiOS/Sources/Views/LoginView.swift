import SwiftUI
import AuthenticationServices
import TarsyShared

struct LoginView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo
                VStack(spacing: 8) {
                    Text("TARSY")
                        .font(.system(size: 56, weight: .bold, design: .monospaced))
                        .foregroundColor(TarsyTheme.accentAmber)

                    Text("remote agent controller")
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)
                }

                Spacer()

                VStack(spacing: 16) {
                    // Sign in with Apple
                    SignInWithAppleButton(.signIn) { request in
                        let nonce = authManager.generateNonce()
                        request.requestedScopes = [.email, .fullName]
                        request.nonce = authManager.sha256(nonce)
                    } onCompletion: { result in
                        Task {
                            await authManager.handleAppleSignIn(result: result)
                        }
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 50)
                    .cornerRadius(12)

                    // Sign in with GitHub
                    Button(action: {
                        Task { await authManager.signInWithGitHub() }
                    }) {
                        HStack(spacing: 8) {
                            Image("GitHubIcon")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                            Text("Sign in with GitHub")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color(white: 0.15))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                    }

                    // Divider
                    HStack {
                        Rectangle()
                            .fill(TarsyTheme.textSecondary.opacity(0.3))
                            .frame(height: 1)
                        Text("or")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.textSecondary)
                        Rectangle()
                            .fill(TarsyTheme.textSecondary.opacity(0.3))
                            .frame(height: 1)
                    }
                    .padding(.vertical, 4)

                    // Email/Password form
                    TextField("", text: $email, prompt: Text("email").foregroundColor(TarsyTheme.textSecondary))
                        .textFieldStyle(.plain)
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(TarsyTheme.textPrimary)
                        .padding(16)
                        .background(TarsyTheme.backgroundSecondary)
                        .cornerRadius(12)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()

                    SecureField("", text: $password, prompt: Text("password").foregroundColor(TarsyTheme.textSecondary))
                        .textFieldStyle(.plain)
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(TarsyTheme.textPrimary)
                        .padding(16)
                        .background(TarsyTheme.backgroundSecondary)
                        .cornerRadius(12)

                    if let error = authManager.errorMessage {
                        Text(error)
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.accentTerracotta)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: {
                        Task {
                            if isSignUp {
                                await authManager.signUp(email: email, password: password)
                            } else {
                                await authManager.signIn(email: email, password: password)
                            }
                        }
                    }) {
                        Text(isSignUp ? "create account" : "sign in")
                            .font(TarsyTheme.monoFont)
                            .foregroundColor(TarsyTheme.backgroundPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(TarsyTheme.accentAmber)
                            .cornerRadius(12)
                    }
                    .disabled(email.isEmpty || password.isEmpty || authManager.isLoading)
                    .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)

                    Button(action: { isSignUp.toggle() }) {
                        Text(isSignUp ? "already have an account? sign in" : "don't have an account? sign up")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }
}
