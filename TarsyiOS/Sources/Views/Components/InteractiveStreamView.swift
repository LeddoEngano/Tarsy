import SwiftUI
import TarsyShared

struct InteractiveStreamView: View {
    @ObservedObject var viewModel: MJPEGStreamViewModel
    var connectionManager: ConnectionManager
    var onClose: () -> Void

    @State private var tapFeedbackPoint: CGPoint? = nil

    // Drag state
    @State private var lastDragTranslation: CGSize = .zero
    @State private var isDragActive = false
    @State private var lastScrollSendTime: CFAbsoluteTime = 0

    // Pinch state
    @State private var isPinchActive = false
    @State private var lastPinchScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Black background fills entire screen including under notch
            Color.black.ignoresSafeArea()

            // Stream + controls — respects safe area naturally
            VStack(spacing: 0) {
                // Top bar — always visible
                HStack {
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
                .padding(.horizontal)
                .padding(.top, 4)

                // Stream image — takes remaining space
                GeometryReader { geo in
                    ZStack {
                        if let frame = viewModel.currentFrame {
                            Image(uiImage: frame)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .gesture(tapGesture(screenSize: geo.size))
                                .gesture(dragGesture(screenSize: geo.size))
                                .gesture(pinchGesture(screenSize: geo.size))
                                .gesture(longPressGesture(screenSize: geo.size))
                        }

                        if let point = tapFeedbackPoint {
                            Circle()
                                .fill(TarsyTheme.accentAmber.opacity(0.4))
                                .frame(width: 30, height: 30)
                                .position(point)
                                .allowsHitTesting(false)
                        }
                    }
                }

                // Hint bar — always visible
                HStack(spacing: 12) {
                    hintLabel(icon: "hand.tap", text: "tap = click")
                    hintLabel(icon: "hand.draw", text: "drag = scroll")
                    hintLabel(icon: "hand.tap.fill", text: "hold = right-click")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6))
                .cornerRadius(12)
                .padding(.bottom, 4)
            }
        }
        .statusBarHidden()
        .onAppear {
            requestHighQuality()
        }
        .onDisappear {
            requestNormalQuality()
        }
    }

    private func requestHighQuality() {
        connectionManager.send(WSPacket(
            action: .streamStart,
            payload: ["quality": "high"]
        ))
    }

    private func requestNormalQuality() {
        connectionManager.send(WSPacket(
            action: .streamStart,
            payload: ["quality": "normal"]
        ))
    }

    // MARK: - Tap

    private func tapGesture(screenSize: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let rel = relativePosition(from: value.location, screenSize: screenSize) else { return }
                showTapFeedback(at: value.location)
                Haptics.light()
                connectionManager.send(WSPacket(
                    action: .remoteTap,
                    payload: ["x": f(rel.x), "y": f(rel.y)]
                ))
            }
    }

    // MARK: - Long Press

    private func longPressGesture(screenSize: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: SpatialTapGesture())
            .onEnded { value in
                if case .second(true, let tap) = value, let tap {
                    guard let rel = relativePosition(from: tap.location, screenSize: screenSize) else { return }
                    Haptics.medium()
                    connectionManager.send(WSPacket(
                        action: .remoteLongPress,
                        payload: ["x": f(rel.x), "y": f(rel.y)]
                    ))
                }
            }
    }

    // MARK: - Drag (Swipe/Scroll) — Stateful

    private func dragGesture(screenSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard let rel = relativePosition(from: value.startLocation, screenSize: screenSize) else { return }

                if !isDragActive {
                    // First drag event — send start
                    isDragActive = true
                    lastDragTranslation = .zero
                    connectionManager.send(WSPacket(
                        action: .remoteScrollStart,
                        payload: ["x": f(rel.x), "y": f(rel.y)]
                    ))
                }

                // Throttle to 30Hz
                let now = CFAbsoluteTimeGetCurrent()
                guard now - lastScrollSendTime > 0.033 else { return }
                lastScrollSendTime = now

                // Incremental delta (not cumulative)
                let dx = value.translation.width - lastDragTranslation.width
                let dy = value.translation.height - lastDragTranslation.height
                lastDragTranslation = value.translation

                connectionManager.send(WSPacket(
                    action: .remoteScroll,
                    payload: [
                        "x": f(rel.x),
                        "y": f(rel.y),
                        "dx": f(dx),
                        "dy": f(dy)
                    ]
                ))
            }
            .onEnded { _ in
                if isDragActive {
                    connectionManager.send(WSPacket(action: .remoteScrollEnd))
                    isDragActive = false
                    lastDragTranslation = .zero
                }
            }
    }

    // MARK: - Pinch — Stateful

    private func pinchGesture(screenSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let center = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
                guard let rel = relativePosition(from: center, screenSize: screenSize) else { return }

                if !isPinchActive {
                    isPinchActive = true
                    lastPinchScale = 1.0
                    connectionManager.send(WSPacket(
                        action: .remotePinchStart,
                        payload: ["x": f(rel.x), "y": f(rel.y)]
                    ))
                }

                let scale = value.magnification
                connectionManager.send(WSPacket(
                    action: .remotePinch,
                    payload: ["x": f(rel.x), "y": f(rel.y), "scale": f(scale)]
                ))
                lastPinchScale = scale
            }
            .onEnded { _ in
                if isPinchActive {
                    connectionManager.send(WSPacket(action: .remotePinchEnd))
                    isPinchActive = false
                    lastPinchScale = 1.0
                }
            }
    }

    // MARK: - Position Mapping

    private func relativePosition(from point: CGPoint, screenSize: CGSize) -> CGPoint? {
        guard let frame = viewModel.currentFrame else { return nil }
        let imageAspect = frame.size.width / frame.size.height
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

        let relX = (point.x - origin.x) / displaySize.width
        let relY = (point.y - origin.y) / displaySize.height
        guard relX >= 0, relX <= 1, relY >= 0, relY <= 1 else { return nil }
        return CGPoint(x: relX, y: relY)
    }

    // MARK: - Helpers

    private func f(_ v: CGFloat) -> String {
        String(format: "%.4f", v)
    }

    private func showTapFeedback(at point: CGPoint) {
        withAnimation(.easeOut(duration: 0.1)) { tapFeedbackPoint = point }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeOut(duration: 0.15)) { tapFeedbackPoint = nil }
        }
    }

    @ViewBuilder
    private func hintLabel(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 10, design: .monospaced))
        }
        .foregroundColor(.white.opacity(0.7))
    }
}

// Uses Haptics from Theme/Haptics.swift
