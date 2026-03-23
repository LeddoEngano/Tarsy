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
                self.buffer.append(data)
                self.processBuffer()
            }

            if isComplete || error != nil {
                DispatchQueue.main.async { self.isConnected = false }
                return
            }

            // Continue receiving
            self.receiveData()
        }
    }

    private func processBuffer() {
        // Look for complete JPEG frames in buffer
        while let endRange = buffer.range(of: jpegEnd) {
            let searchEnd = endRange.upperBound
            if let startRange = buffer.range(of: jpegStart) {
                if startRange.lowerBound < endRange.lowerBound {
                    let jpegData = Data(buffer[startRange.lowerBound..<searchEnd])
                    if let image = UIImage(data: jpegData) {
                        DispatchQueue.main.async {
                            self.currentFrame = image
                            self.frameCount += 1
                        }
                    }
                }
            }
            // Remove processed data
            buffer.removeSubrange(buffer.startIndex..<searchEnd)
        }

        // Prevent buffer overflow
        if buffer.count > 5_000_000 {
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
        .onDisappear {
            viewModel.disconnect()
        }
    }

    private func startStream() {
        isActive = true
        // Send stream:start via WebSocket — Mac will start capture + MJPEG server
        connectionManager.send(WSPacket(action: .streamStart, payload: ["stack": workspace.stack.rawValue]))

        // Listen for stream:start response which confirms server is ready
        let previousHandler = connectionManager.onPacketReceived
        connectionManager.onPacketReceived = { packet in
            if packet.action == .streamStart, let port = packet.payload?["port"] {
                // Server is ready, connect MJPEG client
                if let ip = self.machineService.bestIP {
                    self.viewModel.connect(host: ip, port: UInt16(port) ?? 8643)
                }
                // Restore handler
                self.connectionManager.onPacketReceived = previousHandler
            } else {
                previousHandler?(packet)
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
