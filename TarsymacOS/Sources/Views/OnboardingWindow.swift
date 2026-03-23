import SwiftUI
import TarsyShared

struct OnboardingWindow: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var daemonManager: DaemonManager
    @State private var step: OnboardingStep = .login
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false

    enum OnboardingStep {
        case login
        case tailscale
        case ready
    }

    var body: some View {
        ZStack {
            Color(hex: "1a1a1a")
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                header

                Divider().background(Color(hex: "3a3a3a"))

                // Steps indicator
                stepsIndicator
                    .padding(.top, 20)

                // Content
                Group {
                    switch step {
                    case .login:
                        loginStep
                    case .tailscale:
                        tailscaleStep
                    case .ready:
                        readyStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Spacer()
            }
        }
        .frame(width: 480, height: 520)
        .onAppear {
            if authManager.isAuthenticated {
                step = .tailscale
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuth in
            if isAuth {
                step = .tailscale
                Task { await daemonManager.start() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Tarsier eyes
            HStack(spacing: 4) {
                eyeIcon(size: 14)
                eyeIcon(size: 14)
            }

            Text("TARSY")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: "d4a574"))

            Spacer()

            Text("setup")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(hex: "a89e91"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(hex: "2a2a2a"))
    }

    // MARK: - Steps Indicator

    private var stepsIndicator: some View {
        HStack(spacing: 16) {
            stepDot(label: "1. login", active: step == .login, done: step != .login)
            stepLine(done: step != .login)
            stepDot(label: "2. tailscale", active: step == .tailscale, done: step == .ready)
            stepLine(done: step == .ready)
            stepDot(label: "3. ready", active: step == .ready, done: false)
        }
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private func stepDot(label: String, active: Bool, done: Bool) -> some View {
        VStack(spacing: 4) {
            Circle()
                .fill(done ? Color(hex: "7a8b6f") : active ? Color(hex: "d4a574") : Color(hex: "3a3a3a"))
                .frame(width: 10, height: 10)
                .overlay(
                    done ? Image(systemName: "checkmark")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(.white) : nil
                )
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(active ? Color(hex: "d4a574") : Color(hex: "6b6b6b"))
        }
    }

    @ViewBuilder
    private func stepLine(done: Bool) -> some View {
        Rectangle()
            .fill(done ? Color(hex: "7a8b6f") : Color(hex: "3a3a3a"))
            .frame(height: 1)
            .frame(maxWidth: 40)
            .offset(y: -8)
    }

    // MARK: - Login Step

    private var loginStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("sign in to your tarsy account")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(Color(hex: "a89e91"))

            VStack(spacing: 12) {
                TextField("", text: $email, prompt: Text("email").foregroundColor(Color(hex: "6b6b6b")))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(Color(hex: "e8e0d4"))
                    .padding(12)
                    .background(Color(hex: "2a2a2a"))
                    .cornerRadius(8)

                SecureField("", text: $password, prompt: Text("password").foregroundColor(Color(hex: "6b6b6b")))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(Color(hex: "e8e0d4"))
                    .padding(12)
                    .background(Color(hex: "2a2a2a"))
                    .cornerRadius(8)

                if let error = authManager.errorMessage {
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(hex: "c4704b"))
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
                    Text(authManager.isLoading ? "..." : (isSignUp ? "create account" : "sign in"))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(Color(hex: "1a1a1a"))
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(Color(hex: "d4a574"))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(email.isEmpty || password.isEmpty || authManager.isLoading)

                Button(action: { isSignUp.toggle() }) {
                    Text(isSignUp ? "already have an account? sign in" : "no account? sign up")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(hex: "6b6b6b"))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 300)

            Spacer()
        }
    }

    // MARK: - Tailscale Step

    private var tailscaleStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "network")
                .font(.system(size: 36))
                .foregroundColor(Color(hex: "d4a574"))

            Text("tailscale setup")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: "e8e0d4"))

            Text("tarsy uses tailscale to securely connect\nyour iphone to this mac from anywhere")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(hex: "a89e91"))
                .multilineTextAlignment(.center)

            // Status
            HStack(spacing: 8) {
                statusIcon
                Text(daemonManager.tailscaleStatus)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(hex: "a89e91"))
            }
            .padding(12)
            .background(Color(hex: "2a2a2a"))
            .cornerRadius(8)

            if let ip = daemonManager.tailscaleIP {
                HStack(spacing: 8) {
                    Text("your tailscale ip:")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(hex: "6b6b6b"))
                    Text(ip)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "7a8b6f"))
                        .textSelection(.enabled)
                }
            }

            if daemonManager.tailscaleIP != nil {
                Button(action: { step = .ready }) {
                    Text("continue")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(Color(hex: "1a1a1a"))
                        .frame(maxWidth: 200)
                        .padding(12)
                        .background(Color(hex: "d4a574"))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            } else if daemonManager.tailscaleStatus.contains("not") || daemonManager.tailscaleStatus.contains("install") {
                Button(action: {
                    Task { await daemonManager.start() }
                }) {
                    Text("install tailscale")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(Color(hex: "1a1a1a"))
                        .frame(maxWidth: 200)
                        .padding(12)
                        .background(Color(hex: "d4a574"))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if daemonManager.tailscaleIP != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(Color(hex: "7a8b6f"))
        } else if daemonManager.tailscaleStatus.contains("install") {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(Color(hex: "d4a574"))
        }
    }

    // MARK: - Ready Step

    private var readyStep: some View {
        VStack(spacing: 20) {
            Spacer()

            // Big eyes
            HStack(spacing: 12) {
                eyeIcon(size: 28)
                eyeIcon(size: 28)
            }

            Text("tarsy is ready!")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: "d4a574"))

            VStack(spacing: 8) {
                statusRow(icon: "checkmark.circle.fill", color: "7a8b6f", text: "signed in as \(authManager.currentUser?.email ?? "...")")
                statusRow(icon: "checkmark.circle.fill", color: "7a8b6f", text: "tailscale connected (\(daemonManager.tailscaleIP ?? "..."))")
                statusRow(icon: "checkmark.circle.fill", color: "7a8b6f", text: "websocket server on port \(TarsyConfig.websocketPort)")
                statusRow(icon: "checkmark.circle.fill", color: "7a8b6f", text: "stream server on port 8643")
            }

            Text("tarsy will now run in your menu bar.\nopen the tarsy app on your iphone to start.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(hex: "a89e91"))
                .multilineTextAlignment(.center)

            Button(action: { closeWindow() }) {
                Text("minimize to menu bar")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(Color(hex: "1a1a1a"))
                    .frame(maxWidth: 240)
                    .padding(12)
                    .background(Color(hex: "d4a574"))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    @ViewBuilder
    private func statusRow(icon: String, color: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: color))
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(hex: "a89e91"))
            Spacer()
        }
        .frame(maxWidth: 340)
    }

    @ViewBuilder
    private func eyeIcon(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color(hex: "d4a574"))
                .frame(width: size, height: size)
            Circle()
                .fill(Color(hex: "1a1a1a"))
                .frame(width: size * 0.45, height: size * 0.45)
                .offset(x: size * 0.05, y: -size * 0.05)
            Circle()
                .fill(.white.opacity(0.5))
                .frame(width: size * 0.15, height: size * 0.15)
                .offset(x: size * 0.1, y: -size * 0.1)
        }
    }

    private func closeWindow() {
        NSApplication.shared.keyWindow?.close()
    }
}

// Color extension for macOS
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
