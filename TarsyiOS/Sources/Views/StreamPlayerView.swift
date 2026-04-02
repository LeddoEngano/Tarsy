import SwiftUI
import TarsyShared
import AVFoundation

class StreamViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var fps: Int = 0

    private var frameCount = 0
    private var fpsTimer: Timer?
    private var totalFramesReceived = 0
    private let h264Prefix = Data("H264".utf8)

    /// H.264 hardware decoder
    let h264Decoder = H264Decoder()

    func disconnect() {
        fpsTimer?.invalidate()
        fpsTimer = nil
        isConnected = false
        frameCount = 0
        fps = 0
        h264Decoder.stop()
    }

    /// Receive a binary H.264 frame from WebSocket (LAN or relay)
    func receiveFrame(_ data: Data) {
        totalFramesReceived += 1

        if fpsTimer == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fpsTimer == nil else { return }
                self.fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.fps = self.frameCount
                        self.frameCount = 0
                    }
                }
            }
        }

        // Strip H.264 prefix and decode
        guard data.count > 4 && data.prefix(4) == h264Prefix else { return }
        let h264Data = Data(data.dropFirst(4))

        if !isConnected {
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = true
                self?.h264Decoder.start()
            }
        }

        h264Decoder.receiveFrame(h264Data)
        DispatchQueue.main.async { [weak self] in
            self?.frameCount += 1
        }
    }
}

// MARK: - Shimmer Skeleton

private struct StreamShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            TarsyTheme.backgroundTertiary
                .overlay(
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(0.04),
                            Color.white.opacity(0.08),
                            Color.white.opacity(0.04),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: phase * (geo.size.width * 0.8))
                )
                .clipped()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

struct StreamPlayerView: View {
    @ObservedObject var viewModel: StreamViewModel
    @EnvironmentObject var machineService: MachineService
    @EnvironmentObject var connectionManager: ConnectionManager

    let workspace: Workspace
    @Binding var isActive: Bool
    var onScreenshot: ((UIImage) -> Void)? = nil
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
    @Binding var isFullscreen: Bool
    @State private var isDevServerRunning = false
    @State private var isDevServerStarting = false
    @State private var isStartingStream = false
    @State private var gearRotation: Double = 0
    @State private var showMiniUrlBar = false
    @State private var miniUrlText = ""
    @FocusState private var isMiniUrlFocused: Bool
    @State private var detectedPorts: [PortInfo] = []
    @State private var selectedPort: Int?
    @State private var showPortPicker = false

    var body: some View {
        ZStack {
            TarsyTheme.backgroundSecondary

            if isActive && viewModel.isConnected {
                // Stream content — H.264 via WebSocket
                VStack(spacing: 0) {
                    if let layer = viewModel.h264Decoder.displayLayer {
                        H264PlayerView(displayLayer: layer)
                            .id("h264-\(isFullscreen)")
                            .aspectRatio(16.0/13.0, contentMode: .fit)
                            .clipped()
                            .onTapGesture(count: 2) {
                                isFullscreen.toggle()
                            }
                    }
                    Spacer(minLength: 0)
                }

                // Overlay controls
                VStack {
                    // Top row
                    HStack {
                        // Stop dev server top-left (kills server process only)
                        if isWebMode && isDevServerRunning {
                            streamButton("stop.fill", color: TarsyTheme.accentTerracotta) {
                                stopDevServer()
                            }
                            .accessibilityLabel("Stop dev server")
                        }
                        Spacer()
                        Text("\(viewModel.fps) fps")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(TarsyTheme.backgroundPrimary.opacity(0.7))
                            .cornerRadius(4)
                    }

                    Spacer()

                    // Bottom controls — matches browser layout
                    VStack(alignment: .leading, spacing: 8) {
                        streamButton("camera.viewfinder") {
                            #if DEBUG
                            print("[Screenshot] Button tapped")
                            #endif
                            saveScreenshot()
                        }
                        .accessibilityLabel("Take screenshot")

                        HStack(spacing: 8) {
                            if isWebMode {
                                // URL
                                streamButton("globe") {
                                    miniUrlText = currentBrowserUrl()
                                    withAnimation(.easeInOut(duration: 0.25)) { showMiniUrlBar = true }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isMiniUrlFocused = true }
                                }
                                .accessibilityLabel("Enter URL")

                                // Back
                                streamButton("chevron.left") {
                                    connectionManager.send(WSPacket(action: .browserBack, payload: [:]))
                                }
                                .accessibilityLabel("Go back")

                                // Forward
                                streamButton("chevron.right") {
                                    connectionManager.send(WSPacket(action: .browserForward, payload: [:]))
                                }
                                .accessibilityLabel("Go forward")

                                // Reload
                                streamButton("arrow.clockwise") {
                                    connectionManager.send(WSPacket(action: .browserRefresh, payload: [:]))
                                }
                                .accessibilityLabel("Reload page")
                            }

                            Spacer()

                            // Port badge
                            if isWebMode && detectedPorts.count > 1 {
                                Button(action: { showPortPicker = true }) {
                                    Text(":\(String(selectedPort ?? 0))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.7))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(8)
                                }
                                .accessibilityLabel("Select port \(selectedPort ?? 0)")
                            }

                            // Fullscreen
                            streamButton("arrow.up.left.and.arrow.down.right") {
                                isFullscreen.toggle()
                            }
                            .accessibilityLabel(isFullscreen ? "Exit fullscreen" : "Enter fullscreen")
                        }
                    }
                }
                .padding(8)

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
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .focused($isMiniUrlFocused)
                                .onSubmit { navigateMiniUrl() }

                            Button(action: { navigateMiniUrl() }) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: 20))
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
            } else {
                // Shimmer skeleton while stream is loading
                ZStack(alignment: .bottom) {
                    StreamShimmerView()

                    Text(isStartingStream ? "starting..." : "connecting to stream...")
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)
                        .padding(.bottom, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    if !isActive {
                        startStreamWithAutoSetup()
                    }
                }
            }
        }
        .cornerRadius(12)
        .padding(.horizontal, 12)
        .padding(.top, 0)
        .padding(.bottom, 10)
        .fullScreenCover(isPresented: $isFullscreen) {
            InteractiveStreamView(
                viewModel: viewModel,
                connectionManager: connectionManager,
                workspaceStack: workspace.stack,
                onClose: { isFullscreen = false },
                engineSessionId: $activeSessionId,
                engineType: activeEngineType,
                workspacePath: workspace.localPath,
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
        .onAppear {
            checkDevServerStatus()
            if isWebMode { detectPorts() }
            // Reconnect stream if it was already active but lost connection
            if isActive && !viewModel.isConnected {
                startStreamWithAutoSetup()
            }
        }
        .onChange(of: isActive) { _, active in
            // Auto-start with full setup when activated (e.g. tab switch)
            if active && !viewModel.isConnected {
                startStreamWithAutoSetup()
            }
        }
        .onDisappear {
            // Clean up when workspace is dismissed
            connectionManager.onStreamFrameReceived = nil
            connectionManager.removeListener("devserver")
            connectionManager.removeListener("devserver-stop")
            connectionManager.removeListener("devserver-stop-only")
            connectionManager.removeListener("devserver-status")
            connectionManager.removeListener("stream-ports-\(workspace.id)")
            viewModel.disconnect()
            isActive = false
        }
        .confirmationDialog("Select Port", isPresented: $showPortPicker, titleVisibility: .visible) {
            ForEach(detectedPorts) { port in
                Button(":\(String(port.port)) — \(port.process)") {
                    selectStreamPort(port.port)
                }
            }
        }
    }

    private var isWebMode: Bool { workspace.stack == .web || workspace.stack == .fullstack }

    // MARK: - Dev Server Gear (status indicator + restart only)

    private var devServerGear: some View {
        Button(action: { restartDevServer() }) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14))
                .foregroundColor(gearColor)
                .rotationEffect(.degrees(gearRotation))
                .frame(width: 30, height: 30)
                .background(TarsyTheme.backgroundPrimary.opacity(0.7))
                .cornerRadius(6)
        }
        .disabled(!isDevServerRunning || isDevServerStarting)
        .onChange(of: isDevServerRunning) { _, running in
            if running {
                startGearAnimation()
            } else if !isDevServerStarting {
                stopGearAnimation()
            }
        }
        .onChange(of: isDevServerStarting) { _, starting in
            if starting {
                startGearAnimation()
            } else if !isDevServerRunning {
                stopGearAnimation()
            }
        }
    }

    private var gearColor: Color {
        if isDevServerRunning { return TarsyTheme.statusRunning }
        if isDevServerStarting { return TarsyTheme.accentAmber }
        return TarsyTheme.textSecondary
    }

    private func startGearAnimation() {
        withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
            gearRotation = 360
        }
    }

    private func stopGearAnimation() {
        withAnimation(.easeOut(duration: 0.3)) {
            gearRotation = 0
        }
    }

    // MARK: - Dev Server Actions

    private func startDevServer(completion: (() -> Void)? = nil) {
        guard let command = workspace.devServerCommand, !command.isEmpty else {
            completion?()
            return
        }

        isDevServerStarting = true

        var payload: [String: String] = [
            "path": workspace.localPath,
            "command": command
        ]
        if let url = workspace.streamUrl, !url.isEmpty {
            payload["streamUrl"] = url
        }

        connectionManager.send(WSPacket(action: .devServerStart, payload: payload))

        var waitingForSudo = false
        connectionManager.addListener("devserver") { packet in
            if packet.action == .devServerStart {
                let status = packet.payload?["status"] ?? ""
                if status == "starting" { return }

                DispatchQueue.main.async {
                    isDevServerStarting = false
                    isDevServerRunning = (status == "ready" || status == "running" || status == "already_running" || status == "started_unconfirmed")

                    if let portStr = packet.payload?["port"], let port = Int(portStr) {
                        UserDefaults.standard.set(port, forKey: "devport_\(workspace.id)")
                    }
                    completion?()
                }
                connectionManager.removeListener("devserver")
            } else if packet.action == .sudoResult, packet.payload?["status"] == "cancelled" {
                DispatchQueue.main.async {
                    isDevServerStarting = false
                    completion?()
                }
                connectionManager.removeListener("devserver")
            } else if packet.action == .sudoRequest {
                waitingForSudo = true
            } else if packet.action == .error {
                DispatchQueue.main.async {
                    isDevServerStarting = false
                    completion?()
                }
                connectionManager.removeListener("devserver")
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if waitingForSudo {
                try? await Task.sleep(nanoseconds: 40_000_000_000)
            }
            if isDevServerStarting {
                isDevServerStarting = false
                connectionManager.removeListener("devserver")
                await MainActor.run { completion?() }
            }
        }
    }

    private func restartDevServer() {
        guard isDevServerRunning else { return }
        connectionManager.send(WSPacket(action: .devServerStop, payload: ["path": workspace.localPath]))

        connectionManager.addListener("devserver-stop") { packet in
            if packet.action == .devServerStop {
                DispatchQueue.main.async {
                    isDevServerRunning = false
                    startDevServer()
                }
                connectionManager.removeListener("devserver-stop")
            }
        }
    }

    private func stopDevServer() {
        guard isDevServerRunning else { return }
        connectionManager.send(WSPacket(action: .devServerStop, payload: ["path": workspace.localPath]))

        connectionManager.addListener("devserver-stop-only") { packet in
            if packet.action == .devServerStop {
                DispatchQueue.main.async {
                    isDevServerRunning = false
                }
                connectionManager.removeListener("devserver-stop-only")
            }
        }
    }

    private func checkDevServerStatus() {
        guard connectionManager.isConnected else { return }

        var payload: [String: String] = ["path": workspace.localPath]
        if let url = workspace.streamUrl, !url.isEmpty {
            payload["streamUrl"] = url
        }

        connectionManager.send(WSPacket(action: .devServerStatus, payload: payload))

        connectionManager.addListener("devserver-status") { packet in
            if packet.action == .devServerStatus {
                let running = packet.payload?["running"] == "true"
                DispatchQueue.main.async {
                    isDevServerRunning = running
                    if running, let portStr = packet.payload?["port"], let port = Int(portStr) {
                        UserDefaults.standard.set(port, forKey: "devport_\(workspace.id)")
                    }
                }
                connectionManager.removeListener("devserver-status")
            }
        }
    }

    // MARK: - Stream Actions

    /// Auto-setup: start dev server if needed, open browser on Mac, then start streaming
    private func startStreamWithAutoSetup() {
        isActive = true
        isStartingStream = true

        let needsDevServer = isWebMode && !isDevServerRunning && workspace.devServerCommand != nil && !workspace.devServerCommand!.isEmpty

        let afterDevServer = {
            // Open browser on Mac for web projects
            if self.isWebMode {
                self.openBrowserOnMac()
            }
            // Start the actual stream
            self.startStream()
            self.isStartingStream = false
        }

        if needsDevServer {
            startDevServer(completion: afterDevServer)
        } else {
            afterDevServer()
        }
    }

    private func openBrowserOnMac() {
        let url: String
        if let streamUrl = workspace.streamUrl, !streamUrl.isEmpty {
            url = streamUrl
        } else {
            let port: Int
            switch workspace.stack {
            case .web, .fullstack: port = 3000
            case .mobile: port = 8081
            case .backend: port = 8000
            }
            url = "http://localhost:\(port)"
        }
        connectionManager.send(WSPacket(action: .browserOpenUrl, payload: ["url": url]))
    }

    private func startStream() {
        var payload: [String: String] = ["stack": workspace.stack.rawValue]
        if workspace.isFullScreen {
            payload["workspaceType"] = "openclaw"
        }
        if let url = workspace.streamUrl, !url.isEmpty {
            payload["streamUrl"] = url
        }
        if let ip = machineService.bestIP {
            payload["ip"] = ip
        }

        connectionManager.send(WSPacket(action: .streamStart, payload: payload))

        // H.264 frames arrive via authenticated WebSocket (both LAN and relay)
        connectionManager.onStreamFrameReceived = { [weak viewModel] data in
            viewModel?.receiveFrame(data)
        }
    }

    private func saveScreenshot() {
        #if DEBUG
        print("[Screenshot] saveScreenshot called")
        print("[Screenshot] decoder.lastFrameImage exists: \(viewModel.h264Decoder.captureScreenshot() != nil)")
        print("[Screenshot] onScreenshot callback exists: \(onScreenshot != nil)")
        #endif
        guard let image = viewModel.h264Decoder.captureScreenshot() else {
            #if DEBUG
            print("[Screenshot] FAILED: captureScreenshot returned nil")
            #endif
            return
        }
        #if DEBUG
        print("[Screenshot] Got image: \(image.size)")
        #endif
        onScreenshot?(image)
        #if DEBUG
        print("[Screenshot] onScreenshot called")
        #endif
    }

    // MARK: - Browser Navigation (sends commands to macOS)

    private func currentBrowserUrl() -> String {
        if let streamUrl = workspace.streamUrl, !streamUrl.isEmpty {
            return streamUrl
        }
        let port = selectedPort ?? UserDefaults.standard.integer(forKey: "devport_\(workspace.id)")
        return port > 0 ? "http://localhost:\(port)" : "http://localhost:3000"
    }

    private func navigateMiniUrl() {
        var urlStr = miniUrlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlStr.contains("://") { urlStr = "http://" + urlStr }
        connectionManager.send(WSPacket(action: .browserOpenUrl, payload: ["url": urlStr]))
        withAnimation(.easeInOut(duration: 0.25)) { showMiniUrlBar = false }
        isMiniUrlFocused = false
    }

    private func detectPorts() {
        connectionManager.send(WSPacket(action: .proxyDetectPorts, payload: ["path": workspace.localPath]))

        connectionManager.addListener("stream-ports-\(workspace.id)") { packet in
            if packet.action == .proxyDetectPortsResult {
                if let json = packet.payload?["ports"],
                   let data = json.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                    DispatchQueue.main.async {
                        detectedPorts = parsed.map { PortInfo(from: $0) }
                        if selectedPort == nil, let first = detectedPorts.first {
                            selectedPort = first.port
                        }
                    }
                }
                connectionManager.removeListener("stream-ports-\(workspace.id)")
            }
        }
    }

    private func selectStreamPort(_ port: Int) {
        selectedPort = port
        UserDefaults.standard.set(port, forKey: "devport_\(workspace.id)")
        connectionManager.send(WSPacket(action: .browserOpenUrl, payload: ["url": "http://localhost:\(port)"]))
    }

    @ViewBuilder
    private func streamButton(_ icon: String, color: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial)
                .cornerRadius(7)
        }
    }
}

#if DEBUG
#Preview {
    @Previewable @State var isActive = true
    @Previewable @State var sessionId: String? = nil
    @Previewable @State var questions: [InteractiveQuestion]? = nil
    @Previewable @State var options: [InteractiveOption]? = nil
    @Previewable @State var isFullscreen = false
    StreamPlayerView(
        viewModel: StreamViewModel(),
        workspace: PreviewData.workspace,
        isActive: $isActive,
        activeSessionId: $sessionId,
        todoManager: VoiceTodoManager(),
        interactiveQuestions: $questions,
        interactiveOptions: $options,
        isFullscreen: $isFullscreen
    )
    .environmentObject(MachineService())
    .environmentObject(ConnectionManager())
    .preferredColorScheme(.dark)
}
#endif
