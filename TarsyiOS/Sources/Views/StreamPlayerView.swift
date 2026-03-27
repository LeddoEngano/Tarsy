import SwiftUI
import TarsyShared
import Network
import AVFoundation

class MJPEGStreamViewModel: ObservableObject {
    @Published var currentFrame: UIImage?
    @Published var isConnected = false
    @Published var fps: Int = 0
    /// True when using H.264 codec (relay), false for MJPEG (LAN)
    @Published var isH264Mode = false

    private var connection: NWConnection?
    private var frameCount = 0
    private var fpsTimer: Timer?
    private var buffer = Data()
    private let jpegStart = Data([0xFF, 0xD8])
    private let jpegEnd = Data([0xFF, 0xD9])
    private var lastFrameTime: CFAbsoluteTime = 0
    private let minFrameInterval: CFAbsoluteTime = 1.0 / 30.0 // Allow up to 30 fps display
    private let processingQueue = DispatchQueue(label: "mjpeg.processing", qos: .userInteractive)
    private var totalFramesReceived = 0
    private var framesDroppedThrottle = 0
    private var framesFailedDecode = 0
    private let h264Prefix = Data("H264".utf8)

    /// H.264 decoder for relay mode
    let h264Decoder = H264Decoder()

    func connect(host: String, port: UInt16) {
        disconnect()

        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.fps = self?.frameCount ?? 0
                self?.frameCount = 0
            }
        }

        // Use raw TCP via Network.framework (bypasses ATS)
        let parameters = NWParameters.tcp
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let conn = NWConnection(to: endpoint, using: parameters)

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[MJPEG] Connected to \(host):\(port)")
                // Send HTTP request for MJPEG stream
                let request = "GET /stream HTTP/1.1\r\nHost: \(host):\(port)\r\nAccept: multipart/x-mixed-replace\r\n\r\n"
                if let data = request.data(using: .ascii) {
                    conn.send(content: data, completion: .contentProcessed { _ in })
                }
                DispatchQueue.main.async { self?.isConnected = true }
                self?.receiveData()
            case .failed(let error):
                print("[MJPEG] Failed: \(error)")
                DispatchQueue.main.async { self?.isConnected = false }
            default:
                break
            }
        }

        conn.start(queue: .global(qos: .userInteractive))
        self.connection = conn
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        isConnected = false
        currentFrame = nil
        buffer.removeAll()
        frameCount = 0
        fps = 0
        isH264Mode = false
        h264Decoder.stop()
    }

    /// Receive a binary frame from relay — auto-detects H.264 vs MJPEG
    func receiveRelayFrame(_ data: Data) {
        totalFramesReceived += 1

        if fpsTimer == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fpsTimer == nil else { return }
                self.fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.fps = self.frameCount
                        self.frameCount = 0
                        if self.fps == 0 {
                            print("[Stream] FPS=0 | received=\(self.totalFramesReceived) mode=\(self.isH264Mode ? "H264" : "MJPEG")")
                        }
                    }
                }
            }
        }

        // Check for H.264 prefix
        if data.count > 4 && data.prefix(4) == h264Prefix {
            // H.264 frame — send to hardware decoder (strips "H264" prefix)
            let h264Data = Data(data.dropFirst(4))
            if !isH264Mode {
                print("[Stream] Switching to H.264 mode, first frame size=\(h264Data.count)")
                DispatchQueue.main.async { [weak self] in
                    self?.isH264Mode = true
                    self?.isConnected = true
                    self?.h264Decoder.start()
                }
            }
            h264Decoder.receiveFrame(h264Data)
            // Count H264 frames for FPS directly in view model
            DispatchQueue.main.async { [weak self] in
                self?.frameCount += 1
            }
            return
        }

        // MJPEG fallback
        processingQueue.async { [weak self] in
            guard let self else { return }

            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - self.lastFrameTime
            guard elapsed >= self.minFrameInterval else {
                self.framesDroppedThrottle += 1
                return
            }
            self.lastFrameTime = now

            if let image = UIImage(data: data) {
                DispatchQueue.main.async {
                    self.currentFrame = image
                    self.isConnected = true
                    self.frameCount += 1
                }
            } else {
                self.framesFailedDecode += 1
            }
        }
    }

    private func receiveData() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data {
                self.processingQueue.async {
                    self.buffer.append(data)
                    self.processBuffer()
                }
            }

            if isComplete || error != nil {
                DispatchQueue.main.async { self.isConnected = false }
                return
            }

            self.receiveData()
        }
    }

    private func processBuffer() {
        // Look for complete JPEG frames in buffer
        var latestImage: UIImage?

        while let endRange = buffer.range(of: jpegEnd) {
            let searchEnd = endRange.upperBound
            if let startRange = buffer.range(of: jpegStart),
               startRange.lowerBound < endRange.lowerBound {
                let jpegData = Data(buffer[startRange.lowerBound..<searchEnd])
                // Only decode if enough time has passed (throttle)
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastFrameTime >= minFrameInterval {
                    if let image = UIImage(data: jpegData) {
                        latestImage = image
                        lastFrameTime = now
                    }
                }
            }
            buffer.removeSubrange(buffer.startIndex..<searchEnd)
        }

        // Only update UI with the latest frame (skip intermediate ones)
        if let image = latestImage {
            DispatchQueue.main.async {
                self.currentFrame = image
                self.frameCount += 1
            }
        }

        // Prevent buffer overflow
        if buffer.count > 2_000_000 {
            buffer.removeAll(keepingCapacity: true)
        }
    }
}

struct StreamPlayerView: View {
    @ObservedObject var viewModel: MJPEGStreamViewModel
    @EnvironmentObject var machineService: MachineService
    @EnvironmentObject var connectionManager: ConnectionManager

    let workspace: Workspace
    @Binding var isActive: Bool
    var onScreenshot: ((UIImage) -> Void)? = nil
    @Binding var activeSessionId: String?
    var activeEngineType: AIEngineType = .claude
    var onSessionCreated: ((String) -> Void)? = nil
    @ObservedObject var todoManager: VoiceTodoManager
    @Binding var interactiveQuestions: [InteractiveQuestion]?
    @Binding var interactiveOptions: [InteractiveOption]?
    var onInteractiveChoice: ((InteractiveOption) -> Void)?
    var onMultiQuestionSubmit: (([String: String]) -> Void)?
    var onVoiceMessage: ((String) -> Void)?
    @State private var isFullscreen = false
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

            if isActive && (viewModel.isH264Mode || viewModel.currentFrame != nil) {
                // Stream content — H.264 or MJPEG
                VStack(spacing: 0) {
                    if viewModel.isH264Mode, let layer = viewModel.h264Decoder.displayLayer {
                        H264PlayerView(displayLayer: layer)
                            .id("h264-\(isFullscreen)")
                            .aspectRatio(16.0/13.0, contentMode: .fit)
                            .clipped()
                            .onTapGesture(count: 2) {
                                isFullscreen.toggle()
                            }
                    } else if let frame = viewModel.currentFrame {
                        Image(uiImage: frame)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .onTapGesture(count: 2) {
                                isFullscreen.toggle()
                            }
                    }
                    Spacer(minLength: 0)
                }

                // Overlay controls (shared for both H.264 and MJPEG)
                VStack {
                    // Top row
                    HStack {
                        // Stop dev server top-left (kills server process only)
                        if isWebMode && isDevServerRunning {
                            streamButton("stop.fill", color: TarsyTheme.accentTerracotta) {
                                stopDevServer()
                            }
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
                            saveScreenshot()
                        }

                        HStack(spacing: 8) {
                            if isWebMode {
                                // URL
                                streamButton("globe") {
                                    miniUrlText = currentBrowserUrl()
                                    withAnimation(.easeInOut(duration: 0.25)) { showMiniUrlBar = true }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isMiniUrlFocused = true }
                                }

                                // Back
                                streamButton("chevron.left") {
                                    connectionManager.send(WSPacket(action: .browserBack, payload: [:]))
                                }

                                // Forward
                                streamButton("chevron.right") {
                                    connectionManager.send(WSPacket(action: .browserForward, payload: [:]))
                                }

                                // Reload
                                streamButton("arrow.clockwise") {
                                    connectionManager.send(WSPacket(action: .browserRefresh, payload: [:]))
                                }
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
                            }

                            // Fullscreen
                            streamButton("arrow.up.left.and.arrow.down.right") {
                                isFullscreen.toggle()
                            }
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
            } else if isActive && viewModel.currentFrame == nil && !viewModel.isH264Mode {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(TarsyTheme.accentAmber)
                    Text(isStartingStream ? "starting..." : "connecting to stream...")
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "eye")
                        .font(.system(size: 40))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))

                    Text("stream offline")
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(TarsyTheme.textSecondary)

                    Button(action: { startStreamWithAutoSetup() }) {
                        Text("start stream")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.accentAmber)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(TarsyTheme.accentAmber, lineWidth: 1)
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        if let url = workspace.streamUrl, !url.isEmpty {
            payload["streamUrl"] = url
        }
        if let ip = machineService.bestIP {
            payload["ip"] = ip
        }

        connectionManager.send(WSPacket(action: .streamStart, payload: payload))

        // H.264 frames arrive via WebSocket (both LAN and relay)
        connectionManager.onStreamFrameReceived = { [weak viewModel] data in
            viewModel?.receiveRelayFrame(data)
        }
    }

    private func saveScreenshot() {
        guard let image = viewModel.currentFrame else { return }
        onScreenshot?(image)
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
