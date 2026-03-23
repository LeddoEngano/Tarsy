import SwiftUI
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

                // Form
                VStack(spacing: 16) {
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
