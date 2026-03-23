import SwiftUI
import TarsyShared

struct InteractiveStreamView: View {
    @ObservedObject var viewModel: MJPEGStreamViewModel
    var connectionManager: ConnectionManager
    var onClose: () -> Void

    @State private var imageSize: CGSize = .zero
    @State private var imageOrigin: CGPoint = .zero
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var tapFeedbackPoint: CGPoint? = nil
    @State private var lastScrollSendTime: CFAbsoluteTime = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let frame = viewModel.currentFrame {
                    Image(uiImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .background(
                            GeometryReader { imageGeo in
                                Color.clear.onAppear {
                                    calculateImageLayout(screenSize: geo.size, imageSize: frame.size)
                                }
                                .onChange(of: frame.size.width) { _, _ in
                                    calculateImageLayout(screenSize: geo.size, imageSize: frame.size)
                                }
                            }
                        )
                        .gesture(tapGesture(screenSize: geo.size))
                        .gesture(dragScrollGesture(screenSize: geo.size))
                        .gesture(pinchGesture(screenSize: geo.size))
                        .gesture(longPressGesture(screenSize: geo.size))
                }

                // Tap feedback circle
                if let point = tapFeedbackPoint {
                    Circle()
                        .fill(TarsyTheme.accentAmber.opacity(0.4))
                        .frame(width: 30, height: 30)
                        .position(point)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                }

                // Controls overlay
                if showControls {
                    VStack {
                        HStack {
                            // FPS
                            Text("\(viewModel.fps) fps")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.5))
                                .cornerRadius(4)

                            Spacer()

                            Button(action: onClose) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                        .padding()

                        Spacer()

                        // Hint
                        HStack(spacing: 12) {
                            hintLabel(icon: "hand.tap", text: "tap = click")
                            hintLabel(icon: "hand.draw", text: "drag = scroll")
                            hintLabel(icon: "hand.tap.fill", text: "hold = right-click")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.6))
                        .cornerRadius(12)
                        .padding(.bottom, 40) // safe area
                    }
                    .transition(.opacity)
                }
            }
        }
        .persistentSystemOverlays(.hidden)
        .ignoresSafeArea()
        .onAppear { autoHideControls() }
        .statusBarHidden()
    }

    // MARK: - Gestures

    private func tapGesture(screenSize: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let relative = relativePosition(from: value.location, screenSize: screenSize)
                guard let rel = relative else { return }

                // Visual feedback
                showTapFeedback(at: value.location)

                // Send tap
                connectionManager.send(WSPacket(
                    action: .remoteTap,
                    payload: ["x": String(format: "%.4f", rel.x), "y": String(format: "%.4f", rel.y)]
                ))

                // Toggle controls on tap
                showControls = true
                autoHideControls()
            }
    }

    private func longPressGesture(screenSize: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: SpatialTapGesture())
            .onEnded { value in
                switch value {
                case .second(true, let tap):
                    if let tap {
                        let relative = relativePosition(from: tap.location, screenSize: screenSize)
                        guard let rel = relative else { return }
                        connectionManager.send(WSPacket(
                            action: .remoteLongPress,
                            payload: ["x": String(format: "%.4f", rel.x), "y": String(format: "%.4f", rel.y)]
                        ))
                    }
                default:
                    break
                }
            }
    }

    private func pinchGesture(screenSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onEnded { value in
                let center = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
                let relative = relativePosition(from: center, screenSize: screenSize)
                guard let rel = relative else { return }

                connectionManager.send(WSPacket(
                    action: .remotePinch,
                    payload: [
                        "x": String(format: "%.4f", rel.x),
                        "y": String(format: "%.4f", rel.y),
                        "scale": String(format: "%.2f", value.magnification)
                    ]
                ))
            }
    }

    private func dragScrollGesture(screenSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Throttle: max ~15 events per second
                let now = CFAbsoluteTimeGetCurrent()
                guard now - lastScrollSendTime > 0.066 else { return }
                lastScrollSendTime = now

                let relative = relativePosition(from: value.location, screenSize: screenSize)
                guard let rel = relative else { return }

                let dx = value.translation.width / screenSize.width
                let dy = value.translation.height / screenSize.height

                connectionManager.send(WSPacket(
                    action: .remoteScroll,
                    payload: [
                        "x": String(format: "%.4f", rel.x),
                        "y": String(format: "%.4f", rel.y),
                        "dx": String(format: "%.4f", -dx * 3),
                        "dy": String(format: "%.4f", -dy * 3)
                    ]
                ))
            }
    }

    // MARK: - Position Calculation

    private func calculateImageLayout(screenSize: CGSize, imageSize: CGSize) {
        let imageAspect = imageSize.width / imageSize.height
        let screenAspect = screenSize.width / screenSize.height

        if imageAspect > screenAspect {
            // Image wider than screen — pillarboxed (bars top/bottom)
            let displayWidth = screenSize.width
            let displayHeight = displayWidth / imageAspect
            self.imageSize = CGSize(width: displayWidth, height: displayHeight)
            self.imageOrigin = CGPoint(x: 0, y: (screenSize.height - displayHeight) / 2)
        } else {
            // Image taller — letterboxed (bars left/right)
            let displayHeight = screenSize.height
            let displayWidth = displayHeight * imageAspect
            self.imageSize = CGSize(width: displayWidth, height: displayHeight)
            self.imageOrigin = CGPoint(x: (screenSize.width - displayWidth) / 2, y: 0)
        }
    }

    private func relativePosition(from point: CGPoint, screenSize: CGSize) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        // Calculate where the image is on screen
        let imageAspect = (viewModel.currentFrame?.size.width ?? 1) / (viewModel.currentFrame?.size.height ?? 1)
        let screenAspect = screenSize.width / screenSize.height

        let displaySize: CGSize
        let origin: CGPoint

        if imageAspect > screenAspect {
            let w = screenSize.width
            let h = w / imageAspect
            displaySize = CGSize(width: w, height: h)
            origin = CGPoint(x: 0, y: (screenSize.height - h) / 2)
        } else {
            let h = screenSize.height
            let w = h * imageAspect
            displaySize = CGSize(width: w, height: h)
            origin = CGPoint(x: (screenSize.width - w) / 2, y: 0)
        }

        // Convert tap point to relative position within image
        let relX = (point.x - origin.x) / displaySize.width
        let relY = (point.y - origin.y) / displaySize.height

        // Clamp to 0-1
        guard relX >= 0, relX <= 1, relY >= 0, relY <= 1 else { return nil }
        return CGPoint(x: relX, y: relY)
    }

    // MARK: - Feedback

    private func showTapFeedback(at point: CGPoint) {
        withAnimation(.easeOut(duration: 0.1)) {
            tapFeedbackPoint = point
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeOut(duration: 0.2)) {
                tapFeedbackPoint = nil
            }
        }
    }

    private func autoHideControls() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            withAnimation { showControls = false }
        }
    }

    @ViewBuilder
    private func hintLabel(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundColor(.white.opacity(0.7))
    }
}
