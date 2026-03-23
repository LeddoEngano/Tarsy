import SwiftUI
import TarsyShared
import Network

class MJPEGStreamViewModel: ObservableObject {
    @Published var currentFrame: UIImage?
    @Published var isConnected = false
    @Published var fps: Int = 0

    private var connection: NWConnection?
    private var frameCount = 0
    private var fpsTimer: Timer?
    private var buffer = Data()
    private let jpegStart = Data([0xFF, 0xD8])
    private let jpegEnd = Data([0xFF, 0xD9])
    private var lastFrameTime: CFAbsoluteTime = 0
    private let minFrameInterval: CFAbsoluteTime = 1.0 / 6.0 // Max 6 fps to keep UI responsive
    private let processingQueue = DispatchQueue(label: "mjpeg.processing", qos: .userInitiated)

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
    }

    private func receiveData() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
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
    @StateObject private var viewModel = MJPEGStreamViewModel()
    @EnvironmentObject var machineService: MachineService
    @EnvironmentObject var connectionManager: ConnectionManager

    let workspace: Workspace
    @Binding var isActive: Bool
    @State private var isFullscreen = false
    @State private var isDevServerRunning = false
    @State private var isDevServerStarting = false
    @State private var gearRotation: Double = 0
    @State private var showNoCommandAlert = false

    var body: some View {
        ZStack {
            TarsyTheme.backgroundSecondary

            if isActive, let frame = viewModel.currentFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .onTapGesture(count: 2) {
                        isFullscreen.toggle()
                    }

                // Overlay controls
                VStack {
                    HStack {
                        // Gear icon — dev server status
                        devServerGear

                        Spacer()

                        // FPS badge
                        Text("\(viewModel.fps) fps")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(TarsyTheme.backgroundPrimary.opacity(0.7))
                            .cornerRadius(4)
                    }
                    Spacer()
                    HStack(spacing: 16) {
                        // Screenshot
                        streamButton("camera.viewfinder") {
                            saveScreenshot()
                        }
                        // Fullscreen
                        streamButton(isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                            isFullscreen.toggle()
                        }
                        // Stop
                        streamButton("stop.fill") {
                            stopStream()
                        }
                    }
                }
                .padding(8)
            } else if isActive && viewModel.currentFrame == nil {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(TarsyTheme.accentAmber)
                    Text("connecting to stream...")
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)
                }
            } else {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 12) {
                        Image(systemName: "eye")
                            .font(.system(size: 40))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))

                        Text("stream offline")
                            .font(TarsyTheme.monoFont)
                            .foregroundColor(TarsyTheme.textSecondary)

                        Button(action: { startStream() }) {
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

                    // Gear icon even when stream is offline
                    devServerGear
                        .padding(8)
                }
            }
        }
        .cornerRadius(12)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .fullScreenCover(isPresented: $isFullscreen) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let frame = viewModel.currentFrame {
                    Image(uiImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { isFullscreen = false }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding()
                    }
                    Spacer()
                }
            }
            .onTapGesture(count: 2) {
                isFullscreen = false
            }
        }
        .onAppear {
            checkDevServerStatus()
        }
        .onDisappear {
            viewModel.disconnect()
        }
    }

    // MARK: - Dev Server Gear

    private var devServerGear: some View {
        Button(action: { toggleDevServer() }) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14))
                .foregroundColor(gearColor)
                .rotationEffect(.degrees(gearRotation))
                .padding(8)
                .background(TarsyTheme.backgroundPrimary.opacity(0.7))
                .cornerRadius(6)
        }
        .disabled(isDevServerStarting)
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
        .alert("dev server not configured", isPresented: $showNoCommandAlert) {
            Button("ok", role: .cancel) {}
        } message: {
            Text("set the dev server command in workspace settings (e.g. npm run dev)")
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

    private func toggleDevServer() {
        if isDevServerRunning {
            stopDevServer()
        } else {
            startDevServer()
        }
    }

    private func startDevServer() {
        guard let command = workspace.devServerCommand, !command.isEmpty else {
            showNoCommandAlert = true
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

        connectionManager.addListener("devserver") { packet in
            if packet.action == .devServerStart {
                let status = packet.payload?["status"] ?? ""
                DispatchQueue.main.async {
                    isDevServerStarting = false
                    isDevServerRunning = (status == "running" || status == "already_running")
                }
                connectionManager.removeListener("devserver")
            } else if packet.action == .error {
                DispatchQueue.main.async {
                    isDevServerStarting = false
                }
                connectionManager.removeListener("devserver")
            }
        }

        // Timeout: if no response in 20s, stop waiting
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if isDevServerStarting {
                isDevServerStarting = false
                connectionManager.removeListener("devserver")
            }
        }
    }

    private func stopDevServer() {
        connectionManager.send(WSPacket(action: .devServerStop, payload: ["path": workspace.localPath]))

        connectionManager.addListener("devserver-stop") { packet in
            if packet.action == .devServerStop {
                DispatchQueue.main.async {
                    isDevServerRunning = false
                }
                connectionManager.removeListener("devserver-stop")
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
                DispatchQueue.main.async {
                    isDevServerRunning = packet.payload?["running"] == "true"
                }
                connectionManager.removeListener("devserver-status")
            }
        }
    }

    // MARK: - Stream Actions

    private func startStream() {
        isActive = true

        // Build payload with streamUrl if available
        var payload: [String: String] = ["stack": workspace.stack.rawValue]
        if let url = workspace.streamUrl, !url.isEmpty {
            payload["streamUrl"] = url
        }

        // Send stream:start via WebSocket — Mac will start capture + MJPEG server
        connectionManager.send(WSPacket(action: .streamStart, payload: payload))

        // Listen for stream:start response which confirms server is ready
        connectionManager.addListener("stream") { [self] packet in
            if packet.action == .streamStart, let port = packet.payload?["port"] {
                if let ip = machineService.bestIP {
                    viewModel.connect(host: ip, port: UInt16(port) ?? 8643)
                }
                connectionManager.removeListener("stream")
            }
        }

        // Fallback: if no response in 3s, try connecting anyway
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !viewModel.isConnected, let ip = machineService.bestIP {
                viewModel.connect(host: ip, port: 8643)
            }
        }
    }

    private func stopStream() {
        connectionManager.send(WSPacket(action: .streamStop))
        viewModel.disconnect()
        isActive = false
    }

    private func saveScreenshot() {
        guard let image = viewModel.currentFrame else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }

    @ViewBuilder
    private func streamButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.white)
                .padding(8)
                .background(TarsyTheme.backgroundPrimary.opacity(0.7))
                .cornerRadius(6)
        }
    }
}
