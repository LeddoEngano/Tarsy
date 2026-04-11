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
    @State private var showPassword = false
    @State private var showEmailForm = false
    @State private var confirmPassword = ""

    enum OnboardingStep: CaseIterable {
        case login
        case permissions
        case agents
        case ready
    }

    enum PermissionSubStep: Int, CaseIterable {
        case screenRecording
        case accessibility
        case automation
        case fullDiskAccess
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
                    case .agents:
                        agentsStep
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

            stepConnector(done: stepIndex(step) > 0)

            stepPill(index: 1, label: "permissions", thisStep: .permissions)

            stepConnector(done: stepIndex(step) > 1)

            stepPill(index: 2, label: "agents", thisStep: .agents)

            stepConnector(done: stepIndex(step) > 2)

            stepPill(index: 3, label: "ready", thisStep: .ready)
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
        case .agents: return 2
        case .ready: return 3
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
                Task { await authManager.signInWithAppleOAuth() }
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
    @State private var hasFDA = false
    @State private var hasAutomation = false
    @State private var permissionSubStep: PermissionSubStep = .screenRecording
    /// Mirrors @AppStorage("permissionsVerified") — read by the hard-gate
    /// in `TarsymacOSApp.onDisappear`. Set to true once every required
    /// permission has been verified as granted in this session.
    @AppStorage("permissionsVerified") private var permissionsVerified: Bool = false

    /// Screen Recording state captured on first check in this process
    /// lifetime. If SR was false at launch and later becomes true, macOS
    /// requires an app relaunch before the SR APIs actually work — we use
    /// this flag to detect the transition and prompt for a restart.
    @State private var srStateAtLaunch: Bool? = nil
    @State private var showSRRestartAlert = false

    private var allPermissionsGranted: Bool {
        hasScreenRecording && hasAccessibility && hasFDA && hasAutomation
    }

    private var totalPermissions: Int { PermissionSubStep.allCases.count }

    private var grantedCount: Int {
        [hasScreenRecording, hasAccessibility, hasFDA, hasAutomation].filter { $0 }.count
    }

    private func permissionInfo(for subStep: PermissionSubStep) -> PermissionInfo {
        switch subStep {
        case .screenRecording:
            return PermissionInfo(icon: "rectangle.dashed.badge.record", title: "screen recording",
                    why: "tarsy streams your mac screen to your iphone so you can see and control what your ai agents are doing while you're away from your desk.",
                    isGranted: hasScreenRecording, settingsKey: "Privacy_ScreenCapture")
        case .accessibility:
            return PermissionInfo(icon: "hand.tap", title: "accessibility",
                    why: "tarsy delivers your remote taps, scrolls, and keystrokes to your mac. without this, you can't click anything from your iphone.",
                    isGranted: hasAccessibility, settingsKey: "Privacy_Accessibility")
        case .automation:
            return PermissionInfo(icon: "gearshape.2", title: "automation",
                    why: "tarsy uses apple events to drive browser tabs for dev server previews and to dismiss routine system prompts on your behalf.",
                    isGranted: hasAutomation, settingsKey: nil)
        case .fullDiskAccess:
            return PermissionInfo(icon: "externaldrive.badge.checkmark", title: "full disk access",
                    why: "ai agents touch files all over your disk — projects, caches, config. without full disk access, macos will pop a permission prompt every time an agent touches a new folder, and you won't be there to click allow. this is the single grant that keeps tarsy working remotely.",
                    isGranted: hasFDA, settingsKey: "Privacy_AllFiles")
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
            step = .agents
        }
    }

    private func grantCurrentPermission() {
        switch permissionSubStep {
        case .screenRecording:
            // CGRequestScreenCaptureAccess() registers the app in the Screen Recording
            // list AND opens System Settings. Just opening Settings doesn't add the app.
            CGRequestScreenCaptureAccess()
        case .automation:
            requestAutomationPermission()
        case .fullDiskAccess:
            // FDA cannot be programmatically requested — only a user flipping
            // the toggle in System Settings grants it. Deep-link there and
            // rely on polling to detect the grant.
            if let key = permissionInfo(for: .fullDiskAccess).settingsKey {
                openSettings(key)
            }
        case .accessibility:
            if let key = permissionInfo(for: .accessibility).settingsKey {
                openSettings(key)
            }
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
                    case .automation: hasAutomation
                    case .fullDiskAccess: hasFDA
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
        .alert("Screen Recording Enabled", isPresented: $showSRRestartAlert) {
            Button("Restart Tarsy", role: .destructive) { relaunchApp() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("macOS requires Tarsy to restart before Screen Recording actually starts working. Without a restart the stream will be blank.")
        }
        .task {
            // Initial check
            await checkPermissionsAsync()
            // Capture the SR state as it was when this process launched.
            // If this flips from false -> true during onboarding, the user
            // just granted SR in System Settings and macOS requires a
            // relaunch for the capture APIs to actually see it.
            if srStateAtLaunch == nil {
                srStateAtLaunch = hasScreenRecording
            }
            advanceToNextUngranted()

            // Poll every 2s for permission changes
            while !Task.isCancelled && !allPermissionsGranted {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                await checkPermissionsAsync()
                // SR just flipped from false -> true? Prompt for relaunch.
                if srStateAtLaunch == false && hasScreenRecording && !showSRRestartAlert {
                    showSRRestartAlert = true
                }
                if allPermissionsGranted {
                    withAnimation(.easeInOut(duration: 0.2)) { step = .agents }
                } else if permissionInfo(for: permissionSubStep).isGranted {
                    // Only auto-advance when the current step becomes granted,
                    // not on arbitrary changes — avoids jarring jumps while user is in System Preferences
                    advanceToNextUngranted()
                }
            }
        }
    }

    /// Relaunch Tarsy via `/usr/bin/open -n`. Used after Screen Recording
    /// is granted, since macOS requires a fresh process to pick up the
    /// new TCC decision for SR specifically.
    ///
    /// Sets a transient "isRelaunching" flag so the hard-gate in
    /// `TarsymacOSApp.onDisappear` knows to skip the "permissions
    /// incomplete" alert during this intentional termination.
    private func relaunchApp() {
        UserDefaults.standard.set(true, forKey: "isRelaunchingForPermissions")
        let path = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
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
        hasFDA = checkFullDiskAccess()
        hasAutomation = checkAutomationPermission()
        // Keep the hard-gate flag in sync with live state so it survives
        // a window close (including cmd-W) without needing a completion
        // ceremony. Only set true when every permission is actually green.
        permissionsVerified = allPermissionsGranted
    }

    /// Detect whether the app has Full Disk Access.
    ///
    /// FDA grants read access to `/Library/Application Support/com.apple.TCC/TCC.db`,
    /// which exists on every modern Mac and is otherwise protected by FDA.
    /// `FileHandle(forReadingFrom:)` throws `EPERM` when FDA is not granted,
    /// and succeeds (with real bytes to read) when it is. This probe does
    /// NOT trigger a TCC prompt (FDA can only be granted via System
    /// Settings, never via an API) and does NOT burn the prompt for any
    /// other permission.
    ///
    /// Fallback: if for some reason TCC.db is not readable via file handle
    /// (unusual disk layout, tccd race), try reading `~/Library/Safari` —
    /// also FDA-protected, present on any Mac with Safari (which is all
    /// of them, though the directory may not exist until Safari launches).
    private func checkFullDiskAccess() -> Bool {
        let tccDB = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        if let handle = try? FileHandle(forReadingFrom: tccDB) {
            defer { try? handle.close() }
            // A successful read of at least 1 byte is a strong positive.
            if (try? handle.read(upToCount: 1)) != nil {
                return true
            }
        }
        // Fallback probe: Safari library directory.
        let safari = NSHomeDirectory() + "/Library/Safari"
        if FileManager.default.fileExists(atPath: safari) {
            if (try? FileManager.default.contentsOfDirectory(atPath: safari)) != nil {
                // contentsOfDirectory on FDA-protected paths throws on denial
                // (unlike Desktop/Documents/Downloads which return empty).
                return true
            }
        }
        return false
    }

    /// Check accessibility permission by attempting a real AX query against
    /// a DIFFERENT process. `AXIsProcessTrusted()` caches its result per-
    /// process on macOS 15+, so once the app launches it can never notice
    /// that the user granted (or revoked) the grant without a relaunch —
    /// which means the onboarding UI would never clear the Accessibility
    /// step after the user enables it in System Settings.
    ///
    /// The workaround is to do a real AX probe, but it MUST target another
    /// process. A process can always introspect itself via AX regardless of
    /// TCC, so probing our own PID (or any process that happens to be
    /// frontmost while the onboarding is open — usually Tarsy itself) gives
    /// a false-positive `granted` and the onboarding silently skips the
    /// step. Pick the first regular running app that isn't us, fall back to
    /// `AXIsProcessTrusted()` only if nothing else is running.
    private func checkAccessibilityPermission() -> Bool {
        let ourPid = getpid()
        let probeTarget = NSWorkspace.shared.runningApplications.first { app in
            app.processIdentifier != ourPid
                && app.activationPolicy == .regular
                && app.processIdentifier > 0
        }
        guard let target = probeTarget else {
            return AXIsProcessTrusted()
        }
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
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

    private func openSettings(_ key: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(key)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Agents Step

    @State private var agentScanResults: [(type: AIEngineType, version: String?, path: String?)] = []
    @State private var isScanning = false

    private var agentsStep: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.amber.opacity(0.1))
                    .frame(width: 56, height: 56)
                Image(systemName: "terminal")
                    .font(TarsyTheme.font(size: 22))
                    .foregroundColor(Theme.amber)
            }
            .padding(.bottom, 14)

            Text("ai agents")
                .font(TarsyTheme.font(size: 18, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .padding(.bottom, 4)

            Text("coding agents detected on this mac")
                .font(TarsyTheme.font(size: 12))
                .foregroundColor(Theme.textSecondary)
                .padding(.bottom, 16)

            // Agent list or empty state
            Group {
                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 80)
                } else if agentScanResults.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(TarsyTheme.font(size: 12))
                            .foregroundColor(Theme.terracotta)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("no ai agents found")
                                .font(TarsyTheme.font(size: 11, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                            Text("install an agent like claude code, gemini cli, or codex to use ai features")
                                .font(TarsyTheme.font(size: 10))
                                .foregroundColor(Theme.textMuted)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.terracotta.opacity(0.08))
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(agentScanResults, id: \.type) { result in
                                agentRow(result.type, version: result.version, path: result.path)
                            }
                        }
                    }
                    .frame(maxHeight: 4 * 52) // ~4 rows visible
                }
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 20)

            // Buttons
            HStack(spacing: 12) {
                Button(action: { scanAgents() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(TarsyTheme.font(size: 11))
                        Text("re-scan")
                            .font(TarsyTheme.font(size: 12, weight: .medium))
                    }
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .pointerOnHover()

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) { step = .ready }
                }) {
                    HStack(spacing: 6) {
                        Text(agentScanResults.isEmpty ? "skip" : "continue")
                            .font(TarsyTheme.font(size: 13, weight: .medium))
                        Image(systemName: "arrow.right")
                            .font(TarsyTheme.font(size: 11))
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

            Spacer()
        }
        .task {
            scanAgents()
        }
    }

    private func scanAgents() {
        isScanning = true
        Task.detached {
            let agents = AgentDetector.detectInstalledAgents()
            let results = agents.map { agent in
                (type: agent, version: AgentDetector.agentVersion(for: agent), path: AgentDetector.agentPath(for: agent))
            }
            await MainActor.run {
                agentScanResults = results
                isScanning = false
            }
        }
    }

    @ViewBuilder
    private func agentRow(_ agent: AIEngineType, version: String?, path: String?) -> some View {
        let iconName = agent.iconAsset ?? "WhiteTarsyLogo"

        HStack(spacing: 10) {
            Image(iconName)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                    .font(TarsyTheme.font(size: 11, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                if let version = version {
                    Text(path != nil ? "\(version) — \(path!)" : version)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(TarsyTheme.font(size: 14))
                .foregroundColor(Theme.moss)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.bgCard)
        )
    }

    // MARK: - Ready Step

    private var readyStep: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                readyIcon
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Text("tarsy is ready!")
                    .font(TarsyTheme.font(size: 20, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.bottom, 4)

                Text("everything is set up and running")
                    .font(TarsyTheme.font(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.bottom, 20)

                PairingQRCodeView(machineId: daemonManager.machineId, onPaired: {
                    closeWindow()
                })
                    .padding(.horizontal, 48)
                    .padding(.bottom, 16)

                remoteLimitsCallout
                    .padding(.horizontal, 48)
                    .padding(.bottom, 16)

                readyDismissButton
                    .padding(.bottom, 16)
            }
        }
    }

    /// A one-paragraph honest disclosure about the hard limit of
    /// remote control on macOS: synthetic keystrokes into secure text
    /// fields (admin password, FileVault, Keychain) are blocked by
    /// WindowServer, so if one of those appears while the user is
    /// away from the Mac, Tarsy cannot dismiss it for them. This
    /// applies to TeamViewer, AnyDesk, and every other remote control
    /// tool on macOS — it's a platform security decision, not a
    /// Tarsy limitation — but users deserve to know up front.
    private var remoteLimitsCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(TarsyTheme.font(size: 10))
                Text("one limit worth knowing")
                    .font(TarsyTheme.font(size: 11, weight: .medium))
            }
            .foregroundColor(Theme.textPrimary)

            Text("if macOS asks for your admin password while you're away (e.g. to install something or change a system setting), Tarsy can see the prompt and will notify you — but it cannot type your password for you. macOS blocks remote tools from touching password fields. handle those next time you're at your mac. everything else is covered.")
                .font(TarsyTheme.font(size: 10))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
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
