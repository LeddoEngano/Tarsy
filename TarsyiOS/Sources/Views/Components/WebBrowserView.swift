import SwiftUI
import WebKit
import TarsyShared

enum WebBrowserState {
    case idle           // No dev server running, show start button
    case starting       // Dev server starting, show progress
    case detecting      // Detecting ports after server started
    case connected      // WKWebView showing
}

struct WebBrowserView: View {
    let workspace: Workspace
    var onScreenshot: ((UIImage) -> Void)?
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var machineService: MachineService

    // Engine context for voice commands in fullscreen
    @Binding var activeSessionId: String?
    var activeEngineType: AIEngineType = .claude
    var onSessionCreated: ((String) -> Void)? = nil
    var activeTabId: String = ""
    @ObservedObject var todoManager: VoiceTodoManager
    @Binding var interactiveQuestions: [InteractiveQuestion]?
    @Binding var interactiveOptions: [InteractiveOption]?
    var onInteractiveChoice: ((InteractiveOption) -> Void)?
    var onMultiQuestionSubmit: (([String: String]) -> Void)?
    var onVoiceMessage: ((String) -> Void)?

    @State private var state: WebBrowserState = .detecting
    @State private var detectedPorts: [PortInfo] = []
    @State private var selectedPort: Int?
    @State private var showPortPicker = false
    @State private var webViewURL: URL?
    @State private var progressText = ""
    @State private var devServerOutput = ""
    @State private var isDevServerRunning = false
    @State private var userRequestedScan = false
    @Binding var isFullscreen: Bool
    @State private var isPageLoading = false
    @State private var showMiniUrlBar = false
    @State private var miniUrlText = ""
    @FocusState private var isMiniUrlFocused: Bool
    @StateObject private var webViewRef = WebViewRef()

    @Binding var isActive: Bool
    @State private var didAttemptAutoStart = false

    var body: some View {
        ZStack {
            TarsyTheme.backgroundSecondary

            switch state {
            case .idle:
                idleView
            case .starting:
                startingView
            case .detecting:
                detectingView
            case .connected:
                connectedView
            }
        }
        .cornerRadius(12)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .onAppear {
            setupListeners()
            detectPorts()
            checkDevServerStatus()
        }
        .onChange(of: state) { oldState, newState in
            if newState == .idle && !isDevServerRunning {
                autoStartDevServerIfNeeded()
            }
        }
        .onDisappear {
            connectionManager.removeListener("web-browser-\(workspace.id)")
            isActive = false
        }
        .confirmationDialog("Select Port", isPresented: $showPortPicker, titleVisibility: .visible) {
            ForEach(detectedPorts) { port in
                Button(":\(String(port.port)) — \(port.process)") {
                    selectPort(port.port)
                }
            }
        }
    }

    // MARK: - Idle State (no server)

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe")
                .font(TarsyTheme.font(size: 36))
                .foregroundColor(TarsyTheme.textSecondary)

            Text("Dev server not running")
                .font(TarsyTheme.monoFont)
                .foregroundColor(TarsyTheme.textSecondary)

            if let cmd = workspace.devServerCommand, !cmd.isEmpty {
                Text(cmd)
                    .font(TarsyTheme.font(size: 11))
                    .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
            }

            HStack(spacing: 12) {
                Button(action: { startDevServer() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(TarsyTheme.font(size: 12))
                        Text("Start Server")
                            .font(TarsyTheme.font(size: 13))
                    }
                    .foregroundColor(TarsyTheme.backgroundPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(TarsyTheme.accentAmber)
                    .cornerRadius(8)
                }

                Button(action: { forceScanPorts() }) {
                    Text("Refresh")
                        .font(TarsyTheme.font(size: 13))
                        .foregroundColor(TarsyTheme.accentAmber)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(TarsyTheme.accentAmber, lineWidth: 1)
                        )
                }

                if isDevServerRunning {
                    Button(action: { stopDevServer() }) {
                        Text("Stop Server")
                            .font(TarsyTheme.font(size: 12))
                            .foregroundColor(TarsyTheme.accentTerracotta)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Starting State (progress)

    private var startingView: some View {
        VStack(spacing: 16) {
            // Progress bar
            VStack(spacing: 8) {
                HStack {
                    Text(progressText)
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(TarsyTheme.accentAmber)
                    Spacer()
                    ProgressView()
                        .tint(TarsyTheme.accentAmber)
                        .scaleEffect(0.7)
                }

                // Animated progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(TarsyTheme.backgroundTertiary)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(TarsyTheme.accentAmber)
                            .frame(width: geo.size.width * 0.6)
                            .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: progressText)
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 32)

            // Last output line
            if !devServerOutput.isEmpty {
                Text(devServerOutput)
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(TarsyTheme.textSecondary.opacity(0.7))
                    .lineLimit(2)
                    .frame(maxWidth: 280)
            }

            Button(action: { stopDevServer() }) {
                Text("Cancel")
                    .font(TarsyTheme.font(size: 12))
                    .foregroundColor(TarsyTheme.textSecondary)
            }
        }
    }

    // MARK: - Detecting State

    private var detectingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(TarsyTheme.accentAmber)
            Text("detecting dev server...")
                .font(TarsyTheme.font(size: 12))
                .foregroundColor(TarsyTheme.textSecondary)
        }
    }

    // MARK: - Connected State (browser)

    private var connectedView: some View {
        ZStack {
            if let url = webViewURL {
                WebViewContainer(
                    url: url,
                    connectionManager: connectionManager,
                    isRelay: connectionManager.connectionMode == .relay,
                    webViewRef: webViewRef,
                    isLoading: $isPageLoading
                )
            }

            // Loading spinner
            if isPageLoading {
                VStack {
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(TarsyTheme.accentAmber)
                            .scaleEffect(0.7)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                    }
                    Spacer()
                }
                .padding(8)
            }

            // Floating controls
            VStack {
                // Stop dev server top-left
                if isDevServerRunning {
                    HStack {
                        floatingButton(icon: "stop.fill", color: TarsyTheme.accentTerracotta) { stopDevServer() }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    floatingButton(icon: "camera.viewfinder") { takeScreenshot() }

                    HStack(spacing: 8) {
                        // URL button
                        floatingButton(icon: "globe") {
                            miniUrlText = webViewRef.webView?.url?.absoluteString ?? ""
                            withAnimation(.easeInOut(duration: 0.25)) { showMiniUrlBar = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isMiniUrlFocused = true }
                        }

                        floatingButton(icon: "chevron.left") { webViewRef.webView?.goBack() }
                        floatingButton(icon: "chevron.right") { webViewRef.webView?.goForward() }
                        floatingButton(icon: "arrow.clockwise") {
                            guard let webView = webViewRef.webView else { return }
                            if webView.url != nil {
                                webView.reloadFromOrigin()
                            } else if let url = webViewURL {
                                webView.load(URLRequest(url: url))
                            }
                        }

                        Spacer()

                        // Port badge
                        if detectedPorts.count > 1 {
                            Button(action: { showPortPicker = true }) {
                                Text(":\(String(selectedPort ?? 0))")
                                    .font(TarsyTheme.font(size: 10))
                                    .foregroundColor(.white.opacity(0.7))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(8)
                            }
                        }

                        // Fullscreen
                        floatingButton(icon: "arrow.up.left.and.arrow.down.right") {
                            withAnimation(.easeInOut(duration: 0.3)) { isFullscreen = true }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            // Mini URL bar overlay
            if showMiniUrlBar {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) { showMiniUrlBar = false }
                        isMiniUrlFocused = false
                    }

                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        TextField("", text: $miniUrlText, prompt: Text("enter url...").foregroundColor(.white.opacity(0.3)))
                            .font(TarsyTheme.font(size: 13))
                            .foregroundColor(.white)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .focused($isMiniUrlFocused)
                            .onSubmit { navigateMiniUrl() }

                        Button(action: { navigateMiniUrl() }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(TarsyTheme.font(size: 20))
                                .foregroundColor(TarsyTheme.accentAmber)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .fullScreenCover(isPresented: $isFullscreen) {
            FullscreenWebBrowser(
                url: webViewRef.webView?.url ?? webViewURL ?? URL(string: "about:blank")!,
                connectionManager: connectionManager,
                isRelay: connectionManager.connectionMode == .relay,
                onScreenshot: onScreenshot,
                onClose: { isFullscreen = false },
                engineSessionId: $activeSessionId,
                engineType: activeEngineType,
                workspacePath: workspace.effectivePath,
                workspaceId: workspace.id.uuidString,
                workspaceName: workspace.name,
                tabId: activeTabId,
                aiContext: workspace.aiContext ?? "",
                onSessionCreated: onSessionCreated,
                todoManager: todoManager,
                interactiveQuestions: $interactiveQuestions,
                interactiveOptions: $interactiveOptions,
                onInteractiveChoice: onInteractiveChoice,
                onMultiQuestionSubmit: onMultiQuestionSubmit,
                onVoiceMessage: onVoiceMessage
            )
        }
    }

    @ViewBuilder
    private func floatingButton(icon: String, color: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(TarsyTheme.font(size: 11))
                .foregroundColor(color.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial)
                .cornerRadius(7)
        }
    }

    // MARK: - Actions

    private func setupListeners() {
        connectionManager.addListener("web-browser-\(workspace.id)") { [self] packet in
            Task { @MainActor in
                switch packet.action {
                case .proxyDetectPortsResult:
                    handlePortsDetected(packet)

                case .devServerStatus:
                    if packet.payload?["running"] == "true" {
                        isDevServerRunning = true
                        // Auto-connect if we have a port and aren't connected yet
                        if let portStr = packet.payload?["port"], let port = Int(portStr),
                           state == .idle || state == .detecting {
                            selectPort(port)
                        }
                    }

                case .devServerStart:
                    let status = packet.payload?["status"] ?? ""
                    if status == "starting" {
                        progressText = "Starting dev server..."
                    } else if status == "ready", let portStr = packet.payload?["port"], let port = Int(portStr) {
                        progressText = "Connecting to localhost:\(port)..."
                        selectPort(port)
                    } else if status == "running" {
                        isDevServerRunning = true
                        if let portStr = packet.payload?["port"], let port = Int(portStr) {
                            selectPort(port)
                        } else {
                            progressText = "Server running, detecting port..."
                            connectionManager.send(WSPacket(action: .proxyDetectPorts, payload: ["path": workspace.effectivePath]))
                        }
                    } else if status == "error" {
                        isDevServerRunning = false
                        state = .idle
                        progressText = packet.payload?["error"] ?? "Dev server failed"
                    }

                default:
                    break
                }
            }
        }
    }

    private func detectPorts() {
        if let saved = savedPort {
            // Show loading briefly while we verify the port is alive
            state = .detecting

            if connectionManager.connectionMode == .relay {
                // Relay: verify port via macOS daemon instead of direct HTTP (Bug #4 fix)
                // The daemon checks locally and responds with running status + port
                var payload: [String: String] = ["path": workspace.effectivePath]
                if let url = workspace.streamUrl, !url.isEmpty {
                    payload["streamUrl"] = url
                }
                connectionManager.send(WSPacket(action: .devServerStatus, payload: payload))
                // Timeout: if no response in 3s, fall back to port scan
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if state == .detecting {
                        connectionManager.send(WSPacket(action: .proxyDetectPorts, payload: ["path": workspace.effectivePath]))
                    }
                }
                return
            }

            // LAN: quick health check
            Task {
                if let ip = machineService.bestIP,
                   let url = URL(string: "http://\(ip):\(saved)/") {
                    var request = URLRequest(url: url, timeoutInterval: 2)
                    request.httpMethod = "HEAD"
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse, (200...599).contains(http.statusCode) {
                            selectPort(saved)
                            return
                        }
                    } catch {}
                }
                // Port not responding — clear saved and show idle
                UserDefaults.standard.removeObject(forKey: "devport_\(workspace.id)")
                state = .idle
            }
            return
        }

        state = .detecting
        connectionManager.send(WSPacket(action: .proxyDetectPorts, payload: ["path": workspace.effectivePath]))

        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if state == .detecting {
                state = .idle
            }
        }
    }

    private func handlePortsDetected(_ packet: WSPacket) {
        // Ignore port scan results while dev server is starting — we'll get the port from devServerStart response
        guard state != .starting else {
            return
        }

        guard let json = packet.payload?["ports"],
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            state = .idle
            return
        }

        detectedPorts = parsed.map { PortInfo(from: $0) }

        if detectedPorts.count == 1 {
            selectPort(detectedPorts[0].port)
        } else if detectedPorts.count > 1 {
            if let saved = savedPort, detectedPorts.contains(where: { $0.port == saved }) {
                selectPort(saved)
            } else if userRequestedScan {
                // Only show menu if user explicitly tapped Refresh
                state = .idle
                showPortPicker = true
            } else {
                // Auto-detect found multiple but user didn't ask — just go idle
                state = .idle
            }
        } else {
            state = .idle
        }

        userRequestedScan = false
    }

    private func autoStartDevServerIfNeeded() {
        guard !didAttemptAutoStart else {
            return
        }
        guard let cmd = workspace.devServerCommand, !cmd.isEmpty else {
            return
        }
        didAttemptAutoStart = true
        startDevServer()
    }

    private func startDevServer() {
        guard let cmd = workspace.devServerCommand, !cmd.isEmpty else {
            progressText = "No dev server command configured"
            return
        }

        state = .starting
        progressText = "Starting dev server..."
        isDevServerRunning = true

        connectionManager.send(WSPacket(action: .devServerStart, payload: [
            "path": workspace.effectivePath,
            "command": cmd
        ]))

        // Timeout after 30s — port will come from devServerStart "ready" event
        Task {
            for i in 1...30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if state != .starting { break }
                progressText = "Starting dev server... \(i)s"
            }
            if state == .starting {
                progressText = "Server took too long"
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                state = .idle
            }
        }
    }

    private func takeScreenshot() {
        guard let webView = webViewRef.webView else { return }
        Haptics.light()

        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { image, error in
            if let image {
                onScreenshot?(image)
            }
        }
    }

    private func navigateMiniUrl() {
        var input = miniUrlText.trimmingCharacters(in: .whitespaces)
        if !input.contains("://") { input = "http://\(input)" }
        if let url = URL(string: input) {
            webViewRef.webView?.load(URLRequest(url: url))
        }
        withAnimation(.easeInOut(duration: 0.25)) { showMiniUrlBar = false }
    }

    private func disconnect() {
        webViewURL = nil
        selectedPort = nil
        detectedPorts = []
        state = .idle
        isActive = false
        isFullscreen = false
    }

    private func checkDevServerStatus() {
        guard connectionManager.isConnected else { return }
        var payload: [String: String] = ["path": workspace.effectivePath]
        if let url = workspace.streamUrl, !url.isEmpty {
            payload["streamUrl"] = url
        }
        connectionManager.send(WSPacket(action: .devServerStatus, payload: payload))
    }

    private func stopDevServer() {
        connectionManager.send(WSPacket(action: .devServerStop, payload: ["path": workspace.effectivePath]))
        isDevServerRunning = false
    }

    private func selectPort(_ port: Int) {
        selectedPort = port
        isActive = true
        state = .connected

        // Remember port for this workspace
        UserDefaults.standard.set(port, forKey: "devport_\(workspace.id)")

        if connectionManager.connectionMode == .relay {
            webViewURL = URL(string: "tarsy-http://localhost:\(port)/")
        } else {
            if let ip = machineService.bestIP {
                webViewURL = URL(string: "http://\(ip):\(port)/")
            }
        }
    }

    private func forceScanPorts() {
        state = .detecting
        userRequestedScan = true
        connectionManager.send(WSPacket(action: .proxyDetectPorts, payload: ["path": workspace.effectivePath]))

        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if state == .detecting {
                state = .idle
            }
        }
    }

    private var savedPort: Int? {
        let port = UserDefaults.standard.integer(forKey: "devport_\(workspace.id)")
        return port > 0 ? port : nil
    }
}

// MARK: - Fullscreen Web Browser

struct FullscreenWebBrowser: View {
    let url: URL
    let connectionManager: ConnectionManager
    let isRelay: Bool
    var onScreenshot: ((UIImage) -> Void)?
    let onClose: () -> Void

    // Engine context for voice commands
    @Binding var engineSessionId: String?
    var engineType: AIEngineType
    var workspacePath: String
    var workspaceId: String = ""
    var workspaceName: String = ""
    var tabId: String = ""
    var aiContext: String
    var onSessionCreated: ((String) -> Void)?
    @ObservedObject var todoManager: VoiceTodoManager
    @Binding var interactiveQuestions: [InteractiveQuestion]?
    @Binding var interactiveOptions: [InteractiveOption]?
    var onInteractiveChoice: ((InteractiveOption) -> Void)?
    var onMultiQuestionSubmit: (([String: String]) -> Void)?
    var onVoiceMessage: ((String) -> Void)?

    @StateObject private var fullscreenRef = WebViewRef()
    @StateObject private var voiceRecorder = VoiceRecorderController()
    @State private var isLoading = false
    @State private var showUrlBar = false
    @State private var urlText = ""
    @State private var micButtonOffset: CGSize = .zero
    @State private var micButtonOffsetBase: CGSize = .zero
    @FocusState private var isUrlFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            WebViewContainer(
                url: url,
                connectionManager: connectionManager,
                isRelay: isRelay,
                webViewRef: fullscreenRef,
                isLoading: $isLoading
            )
            .ignoresSafeArea()

            // Tap outside URL bar to close
            if showUrlBar {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) { showUrlBar = false }
                        isUrlFocused = false
                    }
            }

            VStack {
                // Top bar
                HStack {
                    HStack(spacing: 16) {
                        navButton(icon: "chevron.left") { fullscreenRef.webView?.goBack() }
                        navButton(icon: "chevron.right") { fullscreenRef.webView?.goForward() }
                        navButton(icon: "arrow.clockwise") {
                            guard let webView = fullscreenRef.webView else { return }
                            if webView.url != nil {
                                webView.reloadFromOrigin()
                            }
                        }
                        navButton(icon: "camera.viewfinder") {
                            guard let webView = fullscreenRef.webView else { return }
                            Haptics.light()
                            webView.takeSnapshot(with: nil) { image, _ in
                                if let image { onScreenshot?(image) }
                            }
                        }

                        if isLoading {
                            ProgressView()
                                .tint(TarsyTheme.accentAmber)
                                .scaleEffect(0.6)
                        }
                    }

                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(TarsyTheme.font(size: 16))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // Bottom: URL bar
                HStack {
                    if showUrlBar {
                        HStack(spacing: 8) {
                            TextField("", text: $urlText, prompt: Text("enter url...").foregroundColor(.white.opacity(0.3)))
                                .font(TarsyTheme.font(size: 13))
                                .foregroundColor(.white)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .focused($isUrlFocused)
                                .onSubmit { navigateToUrl() }

                            Button(action: { navigateToUrl() }) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(TarsyTheme.font(size: 20))
                                    .foregroundColor(TarsyTheme.accentAmber)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    } else {
                        Button(action: {
                            urlText = fullscreenRef.webView?.url?.absoluteString ?? ""
                            withAnimation(.easeInOut(duration: 0.25)) { showUrlBar = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isUrlFocused = true }
                        }) {
                            Image(systemName: "globe")
                                .font(TarsyTheme.font(size: 13))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                        }
                        .transition(.opacity)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        // Floating mic button — bottom-centered
        .overlay(alignment: .bottom) {
            micButton
                .padding(.bottom, 56)
        }
        // Voice todo overlay
        .overlay(alignment: .bottomTrailing) {
            if !todoManager.items.isEmpty {
                VoiceTodoOverlay(todoManager: todoManager)
                    .padding(.trailing, 16)
                    .padding(.bottom, 130)
                    .allowsHitTesting(true)
            }
        }
        // Interactive questions/options overlay
        .overlay(alignment: .center) {
            VStack(spacing: 8) {
                if let questions = interactiveQuestions {
                    PaginatedQuestionCard(
                        questions: questions,
                        onSubmitAll: { answers in
                            onMultiQuestionSubmit?(answers)
                        },
                        onDismiss: {
                            withAnimation {
                                interactiveQuestions = nil
                            }
                        }
                    )
                    .padding(.horizontal, 40)
                    .frame(maxHeight: 400)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: -2)
                }

                if let options = interactiveOptions {
                    InteractiveOptionsView(options: options) { selected in
                        onInteractiveChoice?(selected)
                    }
                    .padding(.horizontal, 40)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeInOut(duration: 0.25), value: interactiveQuestions?.count)
            .animation(.easeInOut(duration: 0.25), value: interactiveOptions?.count)
        }
        .statusBarHidden()
        .onAppear { setupVoiceTodoListener() }
        .onDisappear { connectionManager.removeListener("voice-todo-browser") }
    }

    // MARK: - Voice Todo Listener

    private func setupVoiceTodoListener() {
        connectionManager.addListener("voice-todo-browser") { packet in
            if packet.action == .engineCreate,
               let sessionId = packet.payload?["sessionId"] {
                DispatchQueue.main.async {
                    for i in todoManager.items.indices where todoManager.items[i].sessionId == "pending" {
                        todoManager.items[i].sessionId = sessionId
                    }
                    engineSessionId = sessionId
                    onSessionCreated?(sessionId)
                }
            }
        }
    }

    // MARK: - Mic Button

    private var micButton: some View {
        // HUD and ring applied as overlays so they don't affect the Image's
        // layout size (avoids left-teleport when recording starts).
        Image(systemName: voiceRecorder.isCancelling ? "trash.fill" : (voiceRecorder.isRecording ? "mic.fill" : "mic"))
            .font(TarsyTheme.font(size: 26, weight: .semibold))
            .foregroundColor(
                voiceRecorder.isCancelling
                    ? .white
                    : TarsyTheme.backgroundPrimary
            )
            .frame(width: 64, height: 64)
            .background(
                Circle()
                    .fill(
                        voiceRecorder.isCancelling
                            ? TarsyTheme.accentTerracotta
                            : TarsyTheme.accentAmber
                    )
            )
            .opacity(0.7)
            .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 8)
            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
            .shadow(
                color: (voiceRecorder.isCancelling ? TarsyTheme.accentTerracotta : TarsyTheme.accentAmber)
                    .opacity(voiceRecorder.isRecording ? 0.5 : 0),
                radius: 20
            )
            .scaleEffect(voiceRecorder.isCancelling ? 1.1 : 1.0)
            .offset(x: voiceRecorder.dragOffsetX * 0.4)
            .overlay {
                if voiceRecorder.isRecording {
                    Circle()
                        .stroke(
                            (voiceRecorder.isCancelling ? TarsyTheme.accentTerracotta : TarsyTheme.accentAmber).opacity(0.4),
                            lineWidth: 3
                        )
                        .frame(width: 72, height: 72)
                        .scaleEffect(voiceRecorder.isRecording ? 1.3 : 1.0)
                        .opacity(voiceRecorder.isRecording ? 0 : 1)
                        .animation(.easeOut(duration: 1.0).repeatForever(autoreverses: false), value: voiceRecorder.isRecording)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if voiceRecorder.isRecording {
                    VoiceRecordingHUD(recorder: voiceRecorder, style: .floatingPill)
                        .fixedSize()
                        .offset(y: -70)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.8), value: voiceRecorder.dragOffsetX)
            .animation(.easeInOut(duration: 0.15), value: voiceRecorder.isCancelling)
            .draggableVoiceRecordButton(
                recorder: voiceRecorder,
                offset: $micButtonOffset,
                offsetBase: $micButtonOffsetBase
            )
            .onAppear { configureVoiceRecorder() }
    }

    // MARK: - Voice Recording

    private func configureVoiceRecorder() {
        voiceRecorder.onCommit = { [self] transcription in
            sendVoiceCommand(transcription)
        }
    }

    private func sendVoiceCommand(_ transcription: String) {
        onVoiceMessage?(transcription)

        let voiceDirective = """
        [SYSTEM: This is a voice command from a mobile device in fullscreen mode. The user CANNOT type text responses — they can only interact through structured UI buttons. Therefore:
        1. EXECUTE the request immediately. Do not ask for clarification.
        2. If you MUST ask something (destructive action, genuine ambiguity), you MUST use the AskUserQuestionTool with clear options. NEVER ask questions as plain text — the user cannot reply to plain text.
        3. Make reasonable assumptions and proceed.]
        """
        let fullMessage = voiceDirective + "\n\n<user-voice-input>\n" + transcription + "\n</user-voice-input>"

        // Start Live Activity for voice command
        if !workspaceId.isEmpty {
            LiveActivityManager.shared.startActivity(
                workspaceId: workspaceId,
                workspaceName: workspaceName,
                engineType: engineType,
                tabId: tabId.isEmpty ? nil : tabId
            )
        }

        if let sessionId = engineSessionId {
            connectionManager.send(WSPacket(
                action: .engineMessage,
                payload: [
                    "sessionId": sessionId,
                    "message": fullMessage,
                    "engineType": engineType.rawValue
                ]
            ))
            todoManager.addItem(text: transcription, sessionId: sessionId)
        } else {
            var createPayload = [
                "path": workspacePath,
                "engineType": engineType.rawValue,
                "message": fullMessage,
                "aiContext": aiContext
            ]
            if !workspaceId.isEmpty { createPayload["workspaceId"] = workspaceId }
            connectionManager.send(WSPacket(action: .engineCreate, payload: createPayload))
            todoManager.addItem(text: transcription, sessionId: "pending")
        }
    }

    private func navigateToUrl() {
        var input = urlText.trimmingCharacters(in: .whitespaces)
        if !input.contains("://") { input = "http://\(input)" }
        if let url = URL(string: input) {
            fullscreenRef.webView?.load(URLRequest(url: url))
        }
        withAnimation(.easeInOut(duration: 0.25)) { showUrlBar = false }
        isUrlFocused = false
    }

    @ViewBuilder
    private func navButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(TarsyTheme.font(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial)
                .cornerRadius(8)
        }
    }
}

// MARK: - WebView Reference

class WebViewRef: ObservableObject {
    var webView: WKWebView?
}

// MARK: - WKWebView Container

struct WebViewContainer: UIViewRepresentable {
    let url: URL
    let connectionManager: ConnectionManager
    let isRelay: Bool
    var webViewRef: WebViewRef?
    @Binding var isLoading: Bool

    // Content Security Policy rule list JSON that blocks external network requests.
    // Order matters: allow rules for localhost patterns come first, then a blanket block rule.
    private static let cspRuleListJSON = """
    [
        {
            "trigger": { "url-filter": ".*", "if-domain": ["*localhost", "*127.0.0.1", "*0.0.0.0", "*[::1]"] },
            "action": { "type": "ignore-previous-rules" }
        },
        {
            "trigger": { "url-filter": "^tarsy-http" },
            "action": { "type": "ignore-previous-rules" }
        },
        {
            "trigger": { "url-filter": "^https?://localhost" },
            "action": { "type": "ignore-previous-rules" }
        },
        {
            "trigger": { "url-filter": "^https?://127\\\\.0\\\\.0\\\\.1" },
            "action": { "type": "ignore-previous-rules" }
        },
        {
            "trigger": { "url-filter": "^https?://0\\\\.0\\\\.0\\\\.0" },
            "action": { "type": "ignore-previous-rules" }
        },
        {
            "trigger": { "url-filter": "^https?://\\\\[::1\\\\]" },
            "action": { "type": "ignore-previous-rules" }
        },
        {
            "trigger": { "url-filter": "^https?://192\\\\.168\\\\." },
            "action": { "type": "ignore-previous-rules" }
        },
        {
            "trigger": { "url-filter": "^https?://10\\\\." },
            "action": { "type": "ignore-previous-rules" }
        },
        {
            "trigger": { "url-filter": "^https?://172\\\\.(1[6-9]|2[0-9]|3[0-1])\\\\." },
            "action": { "type": "ignore-previous-rules" }
        },
        {
            "trigger": { "url-filter": ".*" },
            "action": { "type": "block" }
        }
    ]
    """

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true

        if isRelay {
            let handler = TarsyProxySchemeHandler(connectionManager: connectionManager)
            config.setURLSchemeHandler(handler, forURLScheme: "tarsy-http")
            context.coordinator.schemeHandler = handler
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(TarsyTheme.backgroundSecondary)
        webView.scrollView.backgroundColor = UIColor(TarsyTheme.backgroundSecondary)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webViewRef?.webView = webView

        // Compile and attach content security rules, then load the URL
        Self.compileContentRules { ruleList in
            if let ruleList = ruleList {
                webView.configuration.userContentController.add(ruleList)
            }
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    /// Compiles the CSP content rule list using WKContentRuleListStore.
    private static func compileContentRules(completion: @escaping (WKContentRuleList?) -> Void) {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "TarsyCSPBlockExternal",
            encodedContentRuleList: cspRuleListJSON
        ) { ruleList, error in
            if let error = error {
#if DEBUG
                print("[WebBrowser] CSP rule compilation error: \(error.localizedDescription)")
#endif
            }
            DispatchQueue.main.async {
                completion(ruleList)
            }
        }
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var webView: WKWebView?
        var schemeHandler: TarsyProxySchemeHandler?
        var isLoading: Binding<Bool>

        init(isLoading: Binding<Bool>) {
            self.isLoading = isLoading
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in isLoading.wrappedValue = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in isLoading.wrappedValue = false }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in isLoading.wrappedValue = false }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in isLoading.wrappedValue = false }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if isLocalURL(url) {
                decisionHandler(.allow)
                return
            }

            if url.scheme == "https" || url.scheme == "http" {
#if DEBUG
                print("[WebBrowser] Opening external URL: \(url.absoluteString)")
#endif
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        private func isLocalURL(_ url: URL) -> Bool {
            if url.scheme == "tarsy-http" || url.scheme == "tarsy-https" { return true }
            guard let host = url.host else { return false }
            if host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host == "::1" || host == "[::1]" { return true }
            if host.starts(with: "192.168.") || host.starts(with: "10.") || host.starts(with: "172.") { return true }
            return false
        }

        deinit {
            schemeHandler?.cleanup()
        }
    }
}

// MARK: - Port Info

struct PortInfo: Identifiable {
    let id = UUID()
    let port: Int
    let process: String
    let pid: String
    let match: String

    init(from dict: [String: String]) {
        self.port = Int(dict["port"] ?? "0") ?? 0
        self.process = dict["process"] ?? ""
        self.pid = dict["pid"] ?? ""
        self.match = dict["match"] ?? ""
    }
}
