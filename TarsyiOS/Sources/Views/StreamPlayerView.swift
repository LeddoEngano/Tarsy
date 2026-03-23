import SwiftUI
import TarsyShared

class MJPEGStreamViewModel: ObservableObject {
    @Published var currentFrame: UIImage?
    @Published var isConnected = false
    @Published var fps: Int = 0

    private var task: Task<Void, Never>?
    private var frameCount = 0
    private var fpsTimer: Timer?

    func connect(host: String, port: UInt16) {
        disconnect()

        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.fps = self?.frameCount ?? 0
                self?.frameCount = 0
            }
        }

        task = Task { [weak self] in
            guard let url = URL(string: "http://\(host):\(port)/stream") else { return }

            var request = URLRequest(url: url)
            request.timeoutInterval = 30

            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: request)
                await MainActor.run { self?.isConnected = true }

                var buffer = Data()
                let jpegStart = Data([0xFF, 0xD8])
                let jpegEnd = Data([0xFF, 0xD9])

                for try await byte in bytes {
                    guard !Task.isCancelled else { break }
                    buffer.append(byte)

                    // Look for JPEG boundaries
                    if buffer.count >= 2 {
                        let lastTwo = buffer.suffix(2)
                        if lastTwo == jpegEnd {
                            // Find JPEG start
                            if let startRange = buffer.range(of: jpegStart) {
                                let jpegData = buffer[startRange.lowerBound...]
                                if let image = UIImage(data: Data(jpegData)) {
                                    await MainActor.run {
                                        self?.currentFrame = image
                                        self?.frameCount += 1
                                    }
                                }
                            }
                            buffer.removeAll(keepingCapacity: true)
                        }

                        // Prevent buffer from growing too large
                        if buffer.count > 5_000_000 {
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    print("[MJPEG Client] Error: \(error)")
                    await MainActor.run { self?.isConnected = false }
                }
            }
        }
    }

    func disconnect() {
        task?.cancel()
        task = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        isConnected = false
        currentFrame = nil
        frameCount = 0
        fps = 0
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
        // Send stream:start via WebSocket
        connectionManager.send(WSPacket(action: .streamStart, payload: ["stack": workspace.stack.rawValue]))

        // Connect to MJPEG stream
        if let ip = machineService.tailscaleIP {
            viewModel.connect(host: ip, port: 8643)
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
