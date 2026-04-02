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
    static let moss = Color(hex: "ffffff")
    static let terracotta = Color(hex: "e5716a")
}

struct OnboardingWindow: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var daemonManager: DaemonManager
    @State private var step: OnboardingStep = .login
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var appleSignInDelegate: AppleSignInDelegate?
    @State private var showPassword = false
    @State private var showEmailForm = false
    @State private var confirmPassword = ""

    enum OnboardingStep: CaseIterable {
        case login
        case permissions
        case ready
    }

    enum PermissionSubStep: Int, CaseIterable {
        case screenRecording
        case accessibility
        case filesAndFolders
        case automation
    }

    struct PermissionInfo {
        let icon: String
        let title: String
        let why: String
        let isGranted: Bool
        let settingsKey: String?
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
        .frame(width: 500, height: 580)
        .task {
            if authManager.isAuthenticated {
                step = .permissions
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuth in
            if isAuth {
                step = .permissions
            } else {
                step = .login
            }
        }
        .onChange(of: step) { _, newStep in
            if newStep == .ready && !daemonManager.isRunning {
                Task { await daemonManager.start() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image("WhiteTarsyLogo")
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                Text("tarsy")
                    .font(TarsyTheme.font(size: 16, weight: .bold))
                    .foregroundColor(Theme.textPrimary)

                Spacer()

                Text("setup")
                    .font(TarsyTheme.font(size: 11))
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
                    .font(TarsyTheme.font(size: 8, weight: .bold))
                    .foregroundColor(Theme.moss)
            } else {
                Text("\(index + 1)")
                    .font(TarsyTheme.font(size: 9, weight: .bold))
                    .foregroundColor(active ? Theme.amber : Theme.textMuted)
            }

            Text(label)
                .font(TarsyTheme.font(size: 10, weight: active ? .semibold : .regular))
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

            loginHeader
                .padding(.bottom, 20)

            if showEmailForm {
                VStack(spacing: 10) {
                    loginEmailForm

                    loginSubmitButton
                        .padding(.top, 10)

                    loginToggle

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
                    .padding(.top, 4)
                }
                .frame(maxWidth: 320)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 10) {
                    loginOAuthButtons

                    oauthButton(
                        icon: "envelope",
                        label: "Sign in with Email",
                        isSystemImage: true
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) { showEmailForm = true }
                    }
                }
                .frame(maxWidth: 320)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            Spacer()

            loginLegal
        }
    }

    private var loginHeader: some View {
        VStack(spacing: 6) {
            Text("welcome to tarsy")
                .font(TarsyTheme.font(size: 18, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            Text("sign in to connect your devices")
                .font(TarsyTheme.font(size: 12))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var loginOAuthButtons: some View {
        VStack(spacing: 10) {
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

    private var loginEmailForm: some View {
        VStack(spacing: 8) {
            styledTextField("email", text: $email)
            styledSecureField("password", text: $password)

            if isSignUp {
                styledSecureField("confirm password", text: $confirmPassword)

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

    private var loginSubmitButton: some View {
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
                    .font(TarsyTheme.font(size: 13, weight: .medium))
            }
            .foregroundColor(Theme.bg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(submitDisabled ? Theme.textMuted : Theme.amber)
            )
        }
        .buttonStyle(.plain)
        .pointerOnHover()
        .disabled(submitDisabled || authManager.isLoading)
    }

    private var submitDisabled: Bool {
        if email.isEmpty || password.isEmpty { return true }
        if isSignUp && confirmPassword != password { return true }
        return false
    }

    private var loginToggle: some View {
        Button(action: { isSignUp.toggle() }) {
            Text(isSignUp ? "already have an account? sign in" : "no account? sign up")
                .font(TarsyTheme.font(size: 11))
                .foregroundColor(Theme.textMuted)
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }

    private var loginLegal: some View {
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
        .font(TarsyTheme.font(size: 10))
        .padding(.bottom, 20)
    }

    // MARK: - Permissions Step

    @State private var hasScreenRecording = false
    @State private var hasAccessibility = false
    @State private var hasFilesAccess = false
    @State private var hasAutomation = false
    @State private var permissionSubStep: PermissionSubStep = .screenRecording

    private var allPermissionsGranted: Bool {
        hasScreenRecording && hasAccessibility && hasFilesAccess && hasAutomation
    }

    private var totalPermissions: Int { PermissionSubStep.allCases.count }

    private var grantedCount: Int {
        [hasScreenRecording, hasAccessibility, hasFilesAccess, hasAutomation].filter { $0 }.count
    }

    private func permissionInfo(for subStep: PermissionSubStep) -> PermissionInfo {
        switch subStep {
        case .screenRecording:
            return PermissionInfo(icon: "rectangle.dashed.badge.record", title: "screen recording",
                    why: "tarsy streams your mac screen to your iphone so you can see and control it remotely.",
                    isGranted: hasScreenRecording, settingsKey: "Privacy_ScreenCapture")
        case .accessibility:
            return PermissionInfo(icon: "hand.tap", title: "accessibility",
                    why: "tarsy needs accessibility access to move windows, type, and handle remote input from your iphone.",
                    isGranted: hasAccessibility, settingsKey: "Privacy_Accessibility")
        case .filesAndFolders:
            return PermissionInfo(icon: "folder", title: "files and folders",
                    why: "tarsy scans your project directories to list repos and provide file context to AI agents.",
                    isGranted: hasFilesAccess, settingsKey: "Privacy_FilesAndFolders")
        case .automation:
            return PermissionInfo(icon: "gearshape.2", title: "automation",
                    why: "tarsy uses apple events to control browser tabs so it can manage dev server previews remotely.",
                    isGranted: hasAutomation, settingsKey: nil)
        }
    }

    private func advanceToNextUngranted() {
        for subStep in PermissionSubStep.allCases {
            if !permissionInfo(for: subStep).isGranted {
                withAnimation(.easeInOut(duration: 0.25)) {
                    permissionSubStep = subStep
                }
                return
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            step = .ready
        }
    }

    private func grantCurrentPermission() {
        if permissionSubStep == .screenRecording {
            // CGRequestScreenCaptureAccess() registers the app in the Screen Recording
            // list AND opens System Settings. Just opening Settings doesn't add the app.
            CGRequestScreenCaptureAccess()
        } else if permissionSubStep == .automation {
            requestAutomationPermission()
        } else if permissionSubStep == .filesAndFolders {
            requestFilesAndFoldersPermission()
        } else if let key = permissionInfo(for: permissionSubStep).settingsKey {
            openSettings(key)
        }
    }

    private var permissionsStep: some View {
        let info = permissionInfo(for: permissionSubStep)

        return VStack(spacing: 0) {
            Spacer()

            // Permission content with crossfade between sub-steps
            VStack(spacing: 0) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(info.isGranted ? Theme.moss.opacity(0.1) : Theme.amber.opacity(0.1))
                        .frame(width: 64, height: 64)
                    Image(systemName: info.isGranted ? "checkmark" : info.icon)
                        .font(TarsyTheme.font(size: info.isGranted ? 22 : 26, weight: info.isGranted ? .bold : .regular))
                        .foregroundColor(info.isGranted ? Theme.moss : Theme.amber)
                }
                .padding(.bottom, 16)

                // Title
                Text(info.title)
                    .font(TarsyTheme.font(size: 18, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.bottom, 4)

                // Step indicator
                Text("step \(permissionSubStep.rawValue + 1) of \(totalPermissions)")
                    .font(TarsyTheme.font(size: 10, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .padding(.bottom, 14)

                // Why explanation
                Text(info.why)
                    .font(TarsyTheme.font(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 340)
                    .padding(.bottom, 20)

                // Progress bar
                permissionsProgressBar
                    .padding(.horizontal, 60)
                    .padding(.bottom, 24)

                // Grant button or granted indicator
                if info.isGranted {
                    VStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(TarsyTheme.font(size: 14))
                            Text("granted")
                                .font(TarsyTheme.font(size: 13, weight: .medium))
                        }
                        .foregroundColor(Theme.moss)

                        Button(action: { advanceToNextUngranted() }) {
                            HStack(spacing: 5) {
                                Text(allPermissionsGranted ? "continue" : "next")
                                    .font(TarsyTheme.font(size: 12, weight: .medium))
                                Image(systemName: "arrow.right")
                                    .font(TarsyTheme.font(size: 10, weight: .medium))
                            }
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointerOnHover()
                    }
                } else {
                    Button(action: { grantCurrentPermission() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.open")
                                .font(TarsyTheme.font(size: 11))
                            Text("grant permission")
                                .font(TarsyTheme.font(size: 13, weight: .medium))
                        }
                        .foregroundColor(Theme.bg)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(Theme.amber)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerOnHover()
                }
            }
            .id(permissionSubStep)
            .transition(.opacity)

            // Dot indicators
            HStack(spacing: 8) {
                ForEach(PermissionSubStep.allCases, id: \.self) { subStep in
                    let granted: Bool = switch subStep {
                    case .screenRecording: hasScreenRecording
                    case .accessibility: hasAccessibility
                    case .filesAndFolders: hasFilesAccess
                    case .automation: hasAutomation
                    }
                    Circle()
                        .fill(subStep == permissionSubStep ? Theme.amber :
                              granted ? Theme.moss : Theme.border)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 16)

            Spacer()
        }
        .task {
            // Initial check
            await checkPermissionsAsync()
            advanceToNextUngranted()

            // Poll every 2s for permission changes
            while !Task.isCancelled && !allPermissionsGranted {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                await checkPermissionsAsync()
                if allPermissionsGranted {
                    withAnimation(.easeInOut(duration: 0.2)) { step = .ready }
                } else if permissionInfo(for: permissionSubStep).isGranted {
                    // Only auto-advance when the current step becomes granted,
                    // not on arbitrary changes — avoids jarring jumps while user is in System Preferences
                    advanceToNextUngranted()
                }
            }
        }
    }

    private var permissionsProgressBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(grantedCount) of \(totalPermissions) granted")
                    .font(TarsyTheme.font(size: 10, weight: .medium))
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
                        .frame(width: geo.size.width * CGFloat(grantedCount) / CGFloat(totalPermissions), height: 3)
                        .animation(.easeInOut(duration: 0.3), value: grantedCount)
                }
            }
            .frame(height: 3)
        }
    }

    private func requestAutomationPermission() {
        NSApp.activate(ignoringOtherApps: true)

        // Execute an AppleScript targeting System Events to trigger the macOS automation consent dialog.
        // This must run on the main thread so the permission dialog can attach to our app.
        var error: NSDictionary?
        let script = NSAppleScript(source: """
            tell application "System Events"
                return name of first process whose frontmost is true
            end tell
        """)
        let result = script?.executeAndReturnError(&error)
        hasAutomation = result != nil && error == nil
    }

    private func checkAutomationPermission() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        guard let aeDesc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(aeDesc, typeWildCard, typeWildCard, false)
        return status == noErr
    }

    private func checkPermissionsAsync() async {
        hasScreenRecording = checkScreenRecordingPermission()
        hasAccessibility = checkAccessibilityPermission()
        hasFilesAccess = preAccessDirectories()
        hasAutomation = checkAutomationPermission()
    }

    /// Check accessibility permission by attempting a real AX query.
    /// AXIsProcessTrusted() caches its result per-process on macOS 15+,
    /// so we test by querying the frontmost app's AX element instead.
    private func checkAccessibilityPermission() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return AXIsProcessTrusted()
        }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXRoleAttribute as CFString, &value)
        // .apiDisabled means accessibility is not enabled for this process.
        // Any other result (success, noValue, etc.) means accessibility is granted.
        return result != .apiDisabled
    }

    /// Check screen recording permission using CGPreflightScreenCaptureAccess().
    /// NOTE: CGWindowListCopyWindowInfo is NOT reliable on macOS 15+ — it returns
    /// window names for system windows even WITHOUT screen recording permission.
    private func checkScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Check that we have access to TCC-protected directories (Desktop and Documents).
    /// Non-protected directories (Developer, Code, etc.) don't require TCC consent,
    /// so we must specifically verify the protected ones.
    private func preAccessDirectories() -> Bool {
        let fm = FileManager.default
        let tccProtectedDirs = [
            NSHomeDirectory() + "/Desktop",
            NSHomeDirectory() + "/Documents",
        ]

        for dir in tccProtectedDirs {
            if fm.fileExists(atPath: dir) {
                if (try? fm.contentsOfDirectory(atPath: dir)) == nil {
                    return false
                }
            }
        }

        return true
    }

    /// Force access to TCC-protected directories to trigger the macOS consent dialog.
    /// Simply opening System Settings does NOT grant permission — the app must actually
    /// attempt file access so macOS shows its native "would like to access" dialog.
    private func requestFilesAndFoldersPermission() {
        let fm = FileManager.default
        let tccProtectedDirs = [
            NSHomeDirectory() + "/Desktop",
            NSHomeDirectory() + "/Documents",
        ]

        for dir in tccProtectedDirs {
            if fm.fileExists(atPath: dir) {
                // This triggers the TCC consent dialog for each protected directory
                _ = try? fm.contentsOfDirectory(atPath: dir)
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

            readyIcon
                .padding(.bottom, 16)

            Text("tarsy is ready")
                .font(TarsyTheme.font(size: 20, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .padding(.bottom, 4)

            Text("everything is set up and running")
                .font(TarsyTheme.font(size: 12))
                .foregroundColor(Theme.textSecondary)
                .padding(.bottom, 24)

            readyStatusCards
                .padding(.horizontal, 48)
                .padding(.bottom, 28)

            Text("tarsy runs in your menu bar.\nopen the app on your iPhone to start.")
                .font(TarsyTheme.font(size: 11))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.bottom, 24)

            readyDismissButton

            Spacer()
        }
    }

    @State private var readyLogoVisible = false

    private var readyIcon: some View {
        Image("WhiteTarsyLogo")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .scaleEffect(readyLogoVisible ? 1.0 : 0.3)
            .opacity(readyLogoVisible ? 1.0 : 0.0)
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                    readyLogoVisible = true
                }
            }
    }

    private var readyStatusCards: some View {
        VStack(spacing: 6) {
            readyRow(icon: "person.fill.checkmark", text: "signed in as \(authManager.currentUser?.email ?? "...")")
            readyRow(icon: "antenna.radiowaves.left.and.right", text: "relay connected — remote access ready")
            readyRow(icon: "lock.fill", text: "encrypted on port \(TarsyConfig.websocketPort)")
            readyRow(icon: "video.fill", text: "H.264 streaming ready")
        }
    }

    private var readyDismissButton: some View {
        Button(action: { closeWindow() }) {
            HStack(spacing: 8) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .font(TarsyTheme.font(size: 12))
                Text("minimize to menu bar")
                    .font(TarsyTheme.font(size: 13, weight: .medium))
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
    }

    @ViewBuilder
    private func readyRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(TarsyTheme.font(size: 10))
                .foregroundColor(Theme.moss)
                .frame(width: 16, alignment: .center)

            Text(text)
                .font(TarsyTheme.font(size: 11))
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

    private func styledTextField(_ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope")
                .font(TarsyTheme.font(size: 12))
                .foregroundColor(Theme.textMuted)
                .frame(width: 16)
            TextField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.textMuted))
                .textFieldStyle(.plain)
                .font(TarsyTheme.font(size: 13))
                .foregroundColor(Theme.textPrimary)
        }
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
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .font(TarsyTheme.font(size: 12))
                .foregroundColor(Theme.textMuted)
                .frame(width: 16)

            if showPassword {
                TextField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.textMuted))
                    .textFieldStyle(.plain)
                    .font(TarsyTheme.font(size: 13))
                    .foregroundColor(Theme.textPrimary)
            } else {
                SecureField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.textMuted))
                    .textFieldStyle(.plain)
                    .font(TarsyTheme.font(size: 13))
                    .foregroundColor(Theme.textPrimary)
            }

            Button(action: { showPassword.toggle() }) {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .font(TarsyTheme.font(size: 12))
                    .foregroundColor(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .pointerOnHover()
        }
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

// MARK: - OAuth Button

struct OAuthButtonView: View {
    let icon: String
    let label: String
    let isSystemImage: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSystemImage {
                    Image(systemName: icon)
                        .font(TarsyTheme.font(size: 18, weight: .medium))
                        .frame(width: 18, height: 18)
                } else {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
                Text(label)
                    .font(TarsyTheme.font(size: 14, weight: .medium))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(isHovered ? Theme.border : Theme.bgCard)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovered ? Theme.amber.opacity(0.5) : Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: isHovered ? Theme.amber.opacity(0.2) : .clear, radius: 6, y: 0)
        }
        .buttonStyle(.plain)
        .pointerOnHover()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Apple Sign In Delegate

class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    let onCompletion: (Result<ASAuthorization, Error>) -> Void

    init(onCompletion: @escaping (Result<ASAuthorization, Error>) -> Void) {
        self.onCompletion = onCompletion
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        onCompletion(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        onCompletion(.failure(error))
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


#if DEBUG
#Preview("Onboarding") {
    OnboardingWindow()
        .environmentObject(AuthManager())
        .environmentObject(DaemonManager())
}
#endif
