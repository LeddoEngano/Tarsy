import SwiftUI
import TarsyShared
import ScreenCaptureKit
import AuthenticationServices

struct OnboardingWindow: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var daemonManager: DaemonManager
    @State private var step: OnboardingStep = .login
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false

    enum OnboardingStep {
        case login
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
                step = .permissions
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuth in
            if isAuth {
                step = .permissions
                Task { await daemonManager.start() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
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
            stepDot(label: "2. perms", active: step == .permissions, done: step == .ready)
            stepLine(done: step == .ready)
            stepDot(label: "3. ready", active: step == .ready, done: false)
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
                .frame(height: 44)
                .cornerRadius(8)

                // Sign in with GitHub
                Button(action: {
                    Task { await authManager.signInWithGitHub() }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Sign in with GitHub")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color(hex: "2a2a2a"))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Divider
                HStack {
                    Rectangle()
                        .fill(Color(hex: "6b6b6b").opacity(0.3))
                        .frame(height: 1)
                    Text("or")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(hex: "6b6b6b"))
                    Rectangle()
                        .fill(Color(hex: "6b6b6b").opacity(0.3))
                        .frame(height: 1)
                }
                .padding(.vertical, 4)

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

            // Legal links
            HStack(spacing: 0) {
                Text("by signing in, you agree to our ")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "6b6b6b"))

                Button("Terms") {
                    if let url = URL(string: "https://www.tarsy.dev/terms") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: "d4a574"))
                .buttonStyle(.plain)

                Text(" and ")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "6b6b6b"))

                Button("Privacy Policy") {
                    if let url = URL(string: "https://www.tarsy.dev/privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: "d4a574"))
                .buttonStyle(.plain)
            }
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Permissions Step

    @State private var hasScreenRecording = false
    @State private var hasAccessibility = false
    @State private var hasFilesAccess = false
    @State private var hasAutomation = false
    @State private var isCheckingPermissions = false

    private var allPermissionsGranted: Bool {
        hasScreenRecording && hasAccessibility && hasFilesAccess
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

                permissionRow(
                    name: "files and folders",
                    description: "scan your projects to find repos",
                    granted: hasFilesAccess,
                    settingsKey: "Privacy_FilesAndFolders"
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

        Task {
            do {
                let _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                hasScreenRecording = true
            } catch {
                hasScreenRecording = false
            }

            hasAccessibility = AXIsProcessTrusted()
            hasFilesAccess = preAccessDirectories()
            isCheckingPermissions = false
        }
    }

    private func preAccessDirectories() -> Bool {
        let fm = FileManager.default
        let dirs = [
            NSHomeDirectory() + "/Desktop",
            NSHomeDirectory() + "/Documents",
            NSHomeDirectory() + "/Projects",
            NSHomeDirectory() + "/Developer",
            NSHomeDirectory() + "/Code",
            NSHomeDirectory() + "/repos",
            NSHomeDirectory() + "/dev",
            NSHomeDirectory() + "/work",
            NSHomeDirectory() + "/src",
            NSHomeDirectory()
        ]

        var accessCount = 0
        for dir in dirs {
            if fm.fileExists(atPath: dir) {
                if let _ = try? fm.contentsOfDirectory(atPath: dir) {
                    accessCount += 1
                }
            }
        }

        return accessCount >= 2
    }

    private var automationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: hasAutomation ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 18))
                .foregroundColor(hasAutomation ? Color(hex: "7a8b6f") : Color(hex: "c4704b"))

            VStack(alignment: .leading, spacing: 2) {
                Text("automation")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "e8e0d4"))
                Text("control browser tabs via apple events")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "6b6b6b"))
            }

            Spacer()

            if !hasAutomation {
                Button(action: { requestAutomationPermission() }) {
                    Text("grant access")
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

    @State private var automationDenied = false

    @State private var automationUserAttempts = 0

    private func requestAutomationPermission() {
        automationUserAttempts += 1
        let attempt = automationUserAttempts

        // Bring app to foreground — LSUIElement apps may not get TCC dialogs otherwise
        NSApp.activate(ignoringOtherApps: true)

        // Run on background thread — AEDeterminePermissionToAutomateTarget blocks until user responds
        DispatchQueue.global(qos: .userInitiated).async {
            let succeeded = checkAutomationWithAEAPI(askUser: true)

            DispatchQueue.main.async {
                hasAutomation = succeeded
                if succeeded {
                    automationDenied = false
                } else if attempt >= 2 {
                    automationDenied = true
                    openSettings("Privacy_Automation")
                }
            }
        }
    }

    /// Uses AEDeterminePermissionToAutomateTarget to check/trigger automation permission.
    /// Targets Finder (always running). askUser=true shows the macOS consent dialog.
    private func checkAutomationWithAEAPI(askUser: Bool) -> Bool {
        let targetDescriptor = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let aeDesc = targetDescriptor.aeDesc else {
            print("[Automation] Failed to create AE descriptor")
            return false
        }

        let status = AEDeterminePermissionToAutomateTarget(
            aeDesc,
            typeWildCard,
            typeWildCard,
            askUser
        )

        print("[Automation] AEDeterminePermissionToAutomateTarget status: \(status)")

        switch status {
        case noErr:
            return true
        case OSStatus(errAEEventNotPermitted): // -1743: denied
            return false
        case OSStatus(procNotFound): // -600: Finder not running (unlikely)
            return false
        default:
            return false
        }
    }

    private func checkAutomationPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: checkAutomationWithAEAPI(askUser: false))
            }
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

            HStack(spacing: 12) {
                eyeIcon(size: 28)
                eyeIcon(size: 28)
            }

            Text("tarsy is ready!")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: "d4a574"))

            VStack(spacing: 8) {
                statusRow(icon: "checkmark.circle.fill", color: "7a8b6f", text: "signed in as \(authManager.currentUser?.email ?? "...")")
                statusRow(icon: "checkmark.circle.fill", color: "7a8b6f", text: "relay connected (remote access ready)")
                statusRow(icon: "lock.fill", color: "7a8b6f", text: "TLS encrypted on port \(TarsyConfig.websocketPort)")
                statusRow(icon: "checkmark.circle.fill", color: "7a8b6f", text: "H.264 streaming ready")
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
