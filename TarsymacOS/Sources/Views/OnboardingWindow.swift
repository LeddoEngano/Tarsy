import SwiftUI
import TarsyShared
import ScreenCaptureKit

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
        case permissions
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
                    case .permissions:
                        permissionsStep
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
        HStack(spacing: 10) {
            stepDot(label: "1. login", active: step == .login, done: step != .login)
            stepLine(done: step != .login)
            stepDot(label: "2. tailscale", active: step == .tailscale, done: step == .permissions || step == .ready)
            stepLine(done: step == .permissions || step == .ready)
            stepDot(label: "3. permissions", active: step == .permissions, done: step == .ready)
            stepLine(done: step == .ready)
            stepDot(label: "4. ready", active: step == .ready, done: false)
        }
        .padding(.horizontal, 24)
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
        VStack(spacing: 16) {
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

            // Install progress
            if daemonManager.tailscale.isInstalling {
                VStack(spacing: 10) {
                    // Progress bar
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("installing tailscale...")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(hex: "d4a574"))
                            Spacer()
                            Text("\(Int(daemonManager.tailscale.installProgress * 100))%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(hex: "a89e91"))
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(hex: "2a2a2a"))
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(hex: "d4a574"))
                                    .frame(width: geo.size.width * daemonManager.tailscale.installProgress, height: 6)
                                    .animation(.easeInOut(duration: 0.3), value: daemonManager.tailscale.installProgress)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.horizontal, 40)

                    // Live log output
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(daemonManager.tailscale.installLog)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color(hex: "7a8b6f"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .id("logBottom")
                        }
                        .frame(maxWidth: 380, maxHeight: 120)
                        .background(Color(hex: "1a1a1a"))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(hex: "2a2a2a"), lineWidth: 1)
                        )
                        .onChange(of: daemonManager.tailscale.installLog) { _, _ in
                            proxy.scrollTo("logBottom", anchor: .bottom)
                        }
                    }
                }
            } else {
                // Status display
                HStack(spacing: 8) {
                    statusIcon
                    Text(daemonManager.tailscaleStatus)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(hex: "a89e91"))
                        .lineLimit(2)
                }
                .padding(12)
                .frame(maxWidth: 380)
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
            }

            // Action buttons
            if daemonManager.tailscaleIP != nil {
                Button(action: { step = .permissions }) {
                    Text("continue")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(Color(hex: "1a1a1a"))
                        .frame(maxWidth: 200)
                        .padding(12)
                        .background(Color(hex: "d4a574"))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            } else if !daemonManager.tailscale.isInstalling {
                VStack(spacing: 8) {
                    if daemonManager.tailscaleStatus.contains("not installed") {
                        Button(action: {
                            Task { await daemonManager.installTailscale() }
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
                    } else if daemonManager.tailscaleStatus.contains("installed") || daemonManager.tailscaleStatus.contains("open") {
                        Text("open the Tailscale app and sign in,\nthen click refresh below")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(hex: "6b6b6b"))
                            .multilineTextAlignment(.center)

                        Button(action: {
                            Task { await daemonManager.refreshTailscale() }
                        }) {
                            Text("refresh status")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(Color(hex: "d4a574"))
                                .frame(maxWidth: 200)
                                .padding(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color(hex: "d4a574"), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()
        }
        .task {
            await daemonManager.setupTailscale()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if daemonManager.tailscaleIP != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(Color(hex: "7a8b6f"))
        } else if daemonManager.tailscaleStatus.contains("installed") {
            Image(systemName: "app.badge")
                .foregroundColor(Color(hex: "d4a574"))
        } else if daemonManager.tailscaleStatus.contains("not installed") {
            Image(systemName: "arrow.down.circle")
                .foregroundColor(Color(hex: "d4a574"))
        } else {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(Color(hex: "c4704b"))
        }
    }

    // MARK: - Permissions Step

    @State private var hasScreenRecording = false
    @State private var hasAccessibility = false
    @State private var isCheckingPermissions = false

    private var allPermissionsGranted: Bool {
        hasScreenRecording && hasAccessibility
    }

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundColor(Color(hex: "d4a574"))

            Text("permissions")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: "e8e0d4"))

            Text("tarsy needs these permissions\nto capture your screen and control windows")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(hex: "a89e91"))
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                permissionRow(
                    name: "screen recording",
                    description: "stream your browser/simulator to iphone",
                    granted: hasScreenRecording,
                    settingsKey: "Privacy_ScreenCapture"
                )

                permissionRow(
                    name: "accessibility",
                    description: "control windows and detect running apps",
                    granted: hasAccessibility,
                    settingsKey: "Privacy_Accessibility"
                )
            }
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button(action: { checkPermissions() }) {
                    HStack(spacing: 6) {
                        if isCheckingPermissions {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("refresh")
                            .font(.system(size: 13, design: .monospaced))
                    }
                    .foregroundColor(Color(hex: "d4a574"))
                    .frame(maxWidth: 120)
                    .padding(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "d4a574"), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                if allPermissionsGranted {
                    Button(action: { step = .ready }) {
                        Text("continue")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(Color(hex: "1a1a1a"))
                            .frame(maxWidth: 120)
                            .padding(10)
                            .background(Color(hex: "d4a574"))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !allPermissionsGranted {
                Text("grant permissions above, then click refresh")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "6b6b6b"))
            }

            Spacer()
        }
        .task {
            checkPermissions()
        }
    }

    @ViewBuilder
    private func permissionRow(name: String, description: String, granted: Bool, settingsKey: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 18))
                .foregroundColor(granted ? Color(hex: "7a8b6f") : Color(hex: "c4704b"))

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "e8e0d4"))
                Text(description)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "6b6b6b"))
            }

            Spacer()

            if !granted {
                Button(action: { openSettings(settingsKey) }) {
                    Text("open settings")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "d4a574"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(hex: "d4a574"), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(hex: "2a2a2a"))
        .cornerRadius(8)
    }

    private func checkPermissions() {
        isCheckingPermissions = true

        // Check Screen Recording - try to get shareable content
        Task {
            do {
                let _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                hasScreenRecording = true
            } catch {
                hasScreenRecording = false
            }

            // Check Accessibility
            hasAccessibility = AXIsProcessTrusted()

            isCheckingPermissions = false
        }
    }

    private func openSettings(_ key: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(key)") {
            NSWorkspace.shared.open(url)
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
        .task {
            // Ensure machine is registered and all services running
            await daemonManager.refreshTailscale()
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
