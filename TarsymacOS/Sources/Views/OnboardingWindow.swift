import SwiftUI
import TarsyShared
import ScreenCaptureKit
import AuthenticationServices

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

struct OnboardingWindow: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var daemonManager: DaemonManager
    @State private var step: OnboardingStep = .login
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false

    enum OnboardingStep: CaseIterable {
        case login
        case permissions
        case ready
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                header

                // Steps
                stepsIndicator
                    .padding(.top, 24)
                    .padding(.bottom, 20)

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
            }
        }
        .frame(width: 500, height: 560)
        .task {
            if authManager.isAuthenticated {
                checkPermissions()
                // Small delay to let permission checks complete
                try? await Task.sleep(nanoseconds: 300_000_000)
                step = allPermissionsGranted ? .ready : .permissions
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuth in
            if isAuth {
                checkPermissions()
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    step = allPermissionsGranted ? .ready : .permissions
                    await daemonManager.start()
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    eyeIcon(size: 12)
                    eyeIcon(size: 12)
                }

                Text("tarsy")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)

                Spacer()

                Text("setup")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Theme.border)
                    )
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)

            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
        }
    }

    // MARK: - Steps Indicator

    private var stepsIndicator: some View {
        HStack(spacing: 0) {
            stepPill(index: 0, label: "login", thisStep: .login)

            stepConnector(done: step != .login)

            stepPill(index: 1, label: "permissions", thisStep: .permissions)

            stepConnector(done: step == .ready)

            stepPill(index: 2, label: "ready", thisStep: .ready)
        }
        .padding(.horizontal, 40)
    }

    private func stepPill(index: Int, label: String, thisStep: OnboardingStep) -> some View {
        let active = step == thisStep
        let done = stepIndex(step) > index

        return HStack(spacing: 6) {
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Theme.moss)
            } else {
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(active ? Theme.amber : Theme.textMuted)
            }

            Text(label)
                .font(.system(size: 10, weight: active ? .semibold : .regular, design: .monospaced))
                .foregroundColor(done ? Theme.moss : active ? Theme.amber : Theme.textMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(active ? Theme.amber.opacity(0.1) : done ? Theme.moss.opacity(0.08) : Color.clear)
                .overlay(
                    Capsule()
                        .stroke(active ? Theme.amber.opacity(0.3) : done ? Theme.moss.opacity(0.2) : Theme.border, lineWidth: 1)
                )
        )
    }

    private func stepConnector(done: Bool) -> some View {
        Rectangle()
            .fill(done ? Theme.moss.opacity(0.4) : Theme.border)
            .frame(height: 1)
            .frame(maxWidth: 24)
    }

    private func stepIndex(_ s: OnboardingStep) -> Int {
        switch s {
        case .login: return 0
        case .permissions: return 1
        case .ready: return 2
        }
    }

    // MARK: - Login Step

    private var loginStep: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 6) {
                Text("welcome to tarsy")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)

                Text("sign in to connect your devices")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.bottom, 24)

            VStack(spacing: 10) {
                // Sign in with Apple
                SignInWithAppleButton(.signIn) { request in
                    let nonce = authManager.generateNonce()
                    request.requestedScopes = [.email, .fullName]
                    request.nonce = authManager.sha256(nonce)
                } onCompletion: { result in
                    Task { await authManager.handleAppleSignIn(result: result) }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 44)
                .cornerRadius(8)

                // Sign in with GitHub
                Button(action: {
                    Task { await authManager.signInWithGitHub() }
                }) {
                    HStack(spacing: 8) {
                        Image("GitHubIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                        Text("Sign in with GitHub")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.bgCard)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .pointerOnHover()

                // Divider
                HStack(spacing: 12) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                    Text("or")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
                .padding(.vertical, 6)

                // Email / Password
                VStack(spacing: 8) {
                    styledTextField("email", text: $email)
                    styledSecureField("password", text: $password)
                }

                if let error = authManager.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(error)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundColor(Theme.terracotta)
                    .padding(.top, 2)
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
                    HStack(spacing: 6) {
                        if authManager.isLoading {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 14, height: 14)
                        }
                        Text(isSignUp ? "create account" : "sign in")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(email.isEmpty || password.isEmpty ? Theme.textMuted : Theme.amber)
                    )
                }
                .buttonStyle(.plain)
                .pointerOnHover()
                .disabled(email.isEmpty || password.isEmpty || authManager.isLoading)

                Button(action: { isSignUp.toggle() }) {
                    Text(isSignUp ? "already have an account? sign in" : "no account? sign up")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .pointerOnHover()
            }
            .frame(maxWidth: 320)

            Spacer()

            // Legal
            HStack(spacing: 0) {
                Text("by signing in, you agree to our ")
                    .foregroundColor(Theme.textMuted)
                Button("Terms") {
                    if let url = URL(string: "https://www.tarsy.dev/terms") { NSWorkspace.shared.open(url) }
                }
                .foregroundColor(Theme.textSecondary)
                .buttonStyle(.plain)
                .pointerOnHover()
                Text(" and ")
                    .foregroundColor(Theme.textMuted)
                Button("Privacy Policy") {
                    if let url = URL(string: "https://www.tarsy.dev/privacy") { NSWorkspace.shared.open(url) }
                }
                .foregroundColor(Theme.textSecondary)
                .buttonStyle(.plain)
                .pointerOnHover()
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.bottom, 20)
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

    private var grantedCount: Int {
        [hasScreenRecording, hasAccessibility, hasFilesAccess].filter { $0 }.count
    }

    private var permissionsStep: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 32))
                    .foregroundColor(Theme.amber)
                    .padding(.bottom, 4)

                Text("permissions")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)

                Text("tarsy needs a few permissions to work")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.bottom, 20)

            // Progress
            VStack(spacing: 6) {
                HStack {
                    Text("\(grantedCount) of 3 granted")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(allPermissionsGranted ? Theme.moss : Theme.textSecondary)
                    Spacer()
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.border)
                            .frame(height: 3)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(allPermissionsGranted ? Theme.moss : Theme.amber)
                            .frame(width: geo.size.width * CGFloat(grantedCount) / 3.0, height: 3)
                            .animation(.easeInOut(duration: 0.3), value: grantedCount)
                    }
                }
                .frame(height: 3)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 16)

            // Permission rows
            VStack(spacing: 8) {
                permissionRow(
                    icon: "rectangle.dashed.badge.record",
                    name: "screen recording",
                    description: "stream your screen to iPhone",
                    granted: hasScreenRecording,
                    settingsKey: "Privacy_ScreenCapture"
                )

                permissionRow(
                    icon: "hand.tap",
                    name: "accessibility",
                    description: "control windows and input remotely",
                    granted: hasAccessibility,
                    settingsKey: "Privacy_Accessibility"
                )

                permissionRow(
                    icon: "folder",
                    name: "files and folders",
                    description: "scan projects and read your repos",
                    granted: hasFilesAccess,
                    settingsKey: "Privacy_FilesAndFolders"
                )
            }
            .padding(.horizontal, 40)

            // Actions
            HStack(spacing: 10) {
                Button(action: { checkPermissions() }) {
                    HStack(spacing: 6) {
                        if isCheckingPermissions {
                            ProgressView()
                                .scaleEffect(0.4)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        Text("refresh")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.bgCard)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .pointerOnHover()

                if allPermissionsGranted {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) { step = .ready }
                    }) {
                        HStack(spacing: 6) {
                            Text("continue")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(Theme.bg)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(Theme.amber)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerOnHover()
                }
            }
            .padding(.top, 20)

            if !allPermissionsGranted {
                Text("grant permissions above, then click refresh")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                    .padding(.top, 10)
            }

            Spacer()
        }
        .task {
            checkPermissions()
        }
    }

    @ViewBuilder
    private func permissionRow(icon: String, name: String, description: String, granted: Bool, settingsKey: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(granted ? Theme.moss.opacity(0.12) : Theme.terracotta.opacity(0.1))
                    .frame(width: 32, height: 32)

                Image(systemName: granted ? "checkmark" : icon)
                    .font(.system(size: granted ? 12 : 13, weight: granted ? .bold : .regular))
                    .foregroundColor(granted ? Theme.moss : Theme.terracotta)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                Text(description)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }

            Spacer()

            if !granted {
                Button(action: { openSettings(settingsKey) }) {
                    Text("grant")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.amber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Theme.amber.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Theme.amber.opacity(0.3), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .pointerOnHover()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(granted ? Theme.moss.opacity(0.2) : Theme.border, lineWidth: 1)
                )
        )
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

    @State private var automationDenied = false
    @State private var automationUserAttempts = 0

    private func requestAutomationPermission() {
        automationUserAttempts += 1
        let attempt = automationUserAttempts

        NSApp.activate(ignoringOtherApps: true)

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

    private func checkAutomationWithAEAPI(askUser: Bool) -> Bool {
        let targetDescriptor = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let aeDesc = targetDescriptor.aeDesc else { return false }

        let status = AEDeterminePermissionToAutomateTarget(
            aeDesc,
            typeWildCard,
            typeWildCard,
            askUser
        )

        switch status {
        case noErr:
            return true
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
        VStack(spacing: 0) {
            Spacer()

            // Success icon
            ZStack {
                Circle()
                    .fill(Theme.moss.opacity(0.1))
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(Theme.moss.opacity(0.15))
                    .frame(width: 56, height: 56)
                HStack(spacing: 4) {
                    eyeIcon(size: 18)
                    eyeIcon(size: 18)
                }
            }
            .padding(.bottom, 16)

            Text("tarsy is ready")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .padding(.bottom, 4)

            Text("everything is set up and running")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .padding(.bottom, 24)

            // Status cards
            VStack(spacing: 6) {
                readyRow(icon: "person.fill.checkmark", text: "signed in as \(authManager.currentUser?.email ?? "...")")
                readyRow(icon: "antenna.radiowaves.left.and.right", text: "relay connected — remote access ready")
                readyRow(icon: "lock.fill", text: "encrypted on port \(TarsyConfig.websocketPort)")
                readyRow(icon: "video.fill", text: "H.264 streaming ready")
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 28)

            Text("tarsy runs in your menu bar.\nopen the app on your iPhone to start.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.bottom, 24)

            Button(action: { closeWindow() }) {
                HStack(spacing: 8) {
                    Image(systemName: "menubar.arrow.up.rectangle")
                        .font(.system(size: 12))
                    Text("minimize to menu bar")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }
                .foregroundColor(Theme.bg)
                .frame(maxWidth: 260)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Theme.amber)
                )
            }
            .buttonStyle(.plain)
            .pointerOnHover()

            Spacer()
        }
    }

    @ViewBuilder
    private func readyRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(Theme.moss)
                .frame(width: 16, alignment: .center)

            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textSecondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.moss.opacity(0.05))
        )
    }

    // MARK: - Components

    @ViewBuilder
    private func eyeIcon(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Theme.amber)
                .frame(width: size, height: size)
            Circle()
                .fill(Theme.bg)
                .frame(width: size * 0.45, height: size * 0.45)
                .offset(x: size * 0.05, y: -size * 0.05)
            Circle()
                .fill(.white.opacity(0.5))
                .frame(width: size * 0.15, height: size * 0.15)
                .offset(x: size * 0.1, y: -size * 0.1)
        }
    }

    private func styledTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.textMuted))
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(Theme.textPrimary)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.bgField)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )
    }

    private func styledSecureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.textMuted))
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(Theme.textPrimary)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.bgField)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )
    }

    private func closeWindow() {
        NSApplication.shared.keyWindow?.close()
    }
}

// Pointer cursor on hover
extension View {
    func pointerOnHover() -> some View {
        self.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
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
