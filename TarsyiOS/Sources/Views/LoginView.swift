import SwiftUI
import AuthenticationServices
import TarsyShared

struct LoginView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isSignUp = false
    @State private var showEmailForm = false
    @State private var showPassword = false
    @State private var appleSignInDelegate: AppleSignInDelegateIOS?
    @State private var legalURL: LegalPage?

    private enum LegalPage: Identifiable {
        case terms, privacy
        var id: Self { self }
        var title: String {
            switch self {
            case .terms: return "Terms of Use"
            case .privacy: return "Privacy Policy"
            }
        }
        var url: URL {
            switch self {
            case .terms: return URL(string: "https://www.tarsy.dev/terms")!
            case .privacy: return URL(string: "https://www.tarsy.dev/privacy")!
            }
        }
    }

    private var submitDisabled: Bool {
        if email.isEmpty || password.isEmpty { return true }
        if isSignUp && confirmPassword != password { return true }
        return false
    }

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo
                VStack(spacing: 12) {
                    Image("TarsyLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 22))

                    Text("TARSY")
                        .font(.system(size: 56, weight: .bold, design: .monospaced))
                        .foregroundColor(TarsyTheme.accentAmber)

                    Text("remote agent controller")
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)
                }

                Spacer()

                if showEmailForm {
                    emailFormView
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    oauthView
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                Spacer()

                // Legal
                HStack(spacing: 0) {
                    Text("by signing in, you agree to our ")
                    Button("Terms") { legalURL = .terms }
                        .foregroundColor(TarsyTheme.accentAmber)
                    Text(" and ")
                    Button("Privacy Policy") { legalURL = .privacy }
                        .foregroundColor(TarsyTheme.accentAmber)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(TarsyTheme.textSecondary)
                .padding(.bottom, 16)
            }
        }
        .sheet(item: $legalURL) { page in
            LegalWebView(title: page.title, url: page.url)
        }
    }

    // MARK: - OAuth Buttons

    private var oauthView: some View {
        VStack(spacing: 12) {
            oauthButton(icon: "apple.logo", label: "Sign in with Apple", isSystemImage: true) {
                let provider = ASAuthorizationAppleIDProvider()
                let request = provider.createRequest()
                let nonce = authManager.generateNonce()
                request.requestedScopes = [.email, .fullName]
                request.nonce = authManager.sha256(nonce)
                let delegate = AppleSignInDelegateIOS { result in
                    Task { await authManager.handleAppleSignIn(result: result) }
                }
                appleSignInDelegate = delegate
                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = delegate
                controller.performRequests()
            }

            oauthButton(icon: "GitHubIcon", label: "Sign in with GitHub", isSystemImage: false) {
                Task { await authManager.signInWithGitHub() }
            }

            oauthButton(icon: "envelope", label: "Sign in with Email", isSystemImage: true) {
                withAnimation(.easeInOut(duration: 0.2)) { showEmailForm = true }
            }
        }
        .padding(.horizontal, 24)
    }

    private func oauthButton(icon: String, label: String, isSystemImage: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSystemImage {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 20, height: 20)
                } else {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
                Text(label)
                    .font(.system(size: 17, weight: .medium))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(TarsyTheme.backgroundSecondary)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
        }
    }

    // MARK: - Email Form

    private var emailFormView: some View {
        VStack(spacing: 12) {
            // Email field
            HStack(spacing: 10) {
                Image(systemName: "envelope")
                    .font(.system(size: 14))
                    .foregroundColor(TarsyTheme.textSecondary)
                    .frame(width: 20)
                TextField("", text: $email, prompt: Text("email").foregroundColor(TarsyTheme.textSecondary))
                    .textFieldStyle(.plain)
                    .font(TarsyTheme.monoFont)
                    .foregroundColor(TarsyTheme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
            }
            .padding(16)
            .background(TarsyTheme.backgroundSecondary)
            .cornerRadius(12)

            // Password field
            HStack(spacing: 10) {
                Image(systemName: "lock")
                    .font(.system(size: 14))
                    .foregroundColor(TarsyTheme.textSecondary)
                    .frame(width: 20)

                if showPassword {
                    TextField("", text: $password, prompt: Text("password").foregroundColor(TarsyTheme.textSecondary))
                        .textFieldStyle(.plain)
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(TarsyTheme.textPrimary)
                } else {
                    SecureField("", text: $password, prompt: Text("password").foregroundColor(TarsyTheme.textSecondary))
                        .textFieldStyle(.plain)
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(TarsyTheme.textPrimary)
                }

                Button(action: { showPassword.toggle() }) {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.system(size: 14))
                        .foregroundColor(TarsyTheme.textSecondary)
                }
            }
            .padding(16)
            .background(TarsyTheme.backgroundSecondary)
            .cornerRadius(12)

            // Confirm password (signup only)
            if isSignUp {
                HStack(spacing: 10) {
                    Image(systemName: "lock")
                        .font(.system(size: 14))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .frame(width: 20)
                    SecureField("", text: $confirmPassword, prompt: Text("confirm password").foregroundColor(TarsyTheme.textSecondary))
                        .textFieldStyle(.plain)
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(TarsyTheme.textPrimary)
                }
                .padding(16)
                .background(TarsyTheme.backgroundSecondary)
                .cornerRadius(12)

                if !confirmPassword.isEmpty && confirmPassword != password {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                        Text("passwords don't match")
                            .font(TarsyTheme.monoFontSmall)
                    }
                    .foregroundColor(TarsyTheme.accentTerracotta)
                }
            }

            // Error
            if let error = authManager.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(error)
                        .font(TarsyTheme.monoFontSmall)
                }
                .foregroundColor(TarsyTheme.accentTerracotta)
                .multilineTextAlignment(.center)
            }

            // Submit
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
                            .tint(TarsyTheme.backgroundPrimary)
                            .scaleEffect(0.7)
                    }
                    Text(isSignUp ? "create account" : "sign in")
                        .font(TarsyTheme.monoFont)
                }
                .foregroundColor(TarsyTheme.backgroundPrimary)
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(submitDisabled ? TarsyTheme.backgroundTertiary : TarsyTheme.accentAmber)
                .cornerRadius(12)
            }
            .disabled(submitDisabled || authManager.isLoading)
            .padding(.top, 8)

            // Toggle sign in / sign up
            Button(action: { isSignUp.toggle() }) {
                Text(isSignUp ? "already have an account? sign in" : "don't have an account? sign up")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textSecondary)
            }

            // Back
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { showEmailForm = false }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                    Text("back")
                        .font(TarsyTheme.monoFontSmall)
                }
                .foregroundColor(TarsyTheme.textSecondary)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Apple Sign In Delegate

class AppleSignInDelegateIOS: NSObject, ASAuthorizationControllerDelegate {
    let onCompletion: (Result<ASAuthorization, Error>) -> Void

    init(onCompletion: @escaping (Result<ASAuthorization, Error>) -> Void) {
        self.onCompletion = onCompletion
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        onCompletion(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        onCompletion(.failure(error))
    }
}

#if DEBUG
#Preview {
    LoginView()
        .environmentObject(AuthManager())
}
#endif
