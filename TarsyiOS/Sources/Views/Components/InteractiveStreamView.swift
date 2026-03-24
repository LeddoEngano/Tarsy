import SwiftUI
import TarsyShared

// MARK: - Hidden Keyboard Capture

struct HiddenKeyboardField: UIViewRepresentable {
    var onText: (String) -> Void
    var onBackspace: () -> Void
    @Binding var isActive: Bool

    func makeUIView(context: Context) -> HiddenTextField {
        let tf = HiddenTextField()
        tf.delegate = context.coordinator
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.spellCheckingType = .no
        tf.smartQuotesType = .no
        tf.smartDashesType = .no
        tf.smartInsertDeleteType = .no
        tf.keyboardType = .default
        tf.returnKeyType = .default
        tf.inputAssistantItem.leadingBarButtonGroups = []
        tf.inputAssistantItem.trailingBarButtonGroups = []
        return tf
    }

    func updateUIView(_ uiView: HiddenTextField, context: Context) {
        if isActive && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isActive && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onText: onText, onBackspace: onBackspace)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        var onText: (String) -> Void
        var onBackspace: () -> Void

        init(onText: @escaping (String) -> Void, onBackspace: @escaping () -> Void) {
            self.onText = onText
            self.onBackspace = onBackspace
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string.isEmpty {
                onBackspace()
            } else {
                onText(string)
            }
            DispatchQueue.main.async {
                textField.text = " "
            }
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onText("\n")
            return false
        }
    }
}

class HiddenTextField: UITextField {
    override var canBecomeFirstResponder: Bool { true }
    override func caretRect(for position: UITextPosition) -> CGRect { .zero }
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
}

struct InteractiveStreamView: View {
    @ObservedObject var viewModel: MJPEGStreamViewModel
    var connectionManager: ConnectionManager
    var onClose: () -> Void

    @State private var tapFeedbackPoint: CGPoint? = nil
    @State private var isCapturingScreenshot = false
    @State private var screenshotSaved = false
    @State private var screenshotProgress: CGFloat = 0
    @State private var showGalleryHint = false
    @AppStorage("tarsy_screenshot_hint_shown") private var hintAlreadyShown = false

    // Drag state
    @State private var lastDragTranslation: CGSize = .zero
    @State private var isDragActive = false
    @State private var lastScrollSendTime: CFAbsoluteTime = 0

    // Pinch state
    @State private var isPinchActive = false
    @State private var lastPinchScale: CGFloat = 1.0

    // Keyboard state
    @State private var isKeyboardActive = false

    // Measured image content size (from SwiftUI layout)
    @State private var imageContentSize: CGSize = .zero

    var body: some View {
        ZStack {
            // Black background fills entire screen including under notch
            Color.black.ignoresSafeArea()

            // Hidden text field for keyboard capture
            HiddenKeyboardField(
                onText: { text in
                    connectionManager.send(WSPacket(
                        action: .remoteKeyboard,
                        payload: ["text": text]
                    ))
                },
                onBackspace: {
                    connectionManager.send(WSPacket(
                        action: .remoteKeyboard,
                        payload: ["text": "\u{8}"]
                    ))
                },
                isActive: $isKeyboardActive
            )
            .frame(width: 0, height: 0)

            // Stream + controls — respects safe area naturally
            VStack(spacing: 0) {
                // Top bar — always visible
                HStack(spacing: 0) {
                    Text("\(viewModel.fps) fps")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 50, alignment: .leading)

                    Spacer()

                    HStack(spacing: 20) {
                        deviceButton(icon: "house.fill", action: "home")
                        screenshotButton
                    }

                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .frame(width: 50, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)

                // Stream image — takes remaining space
                GeometryReader { geo in
                    ZStack {
                        if let frame = viewModel.currentFrame {
                            Image(uiImage: frame)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .background(
                                    GeometryReader { imageGeo in
                                        Color.clear
                                            .onAppear { imageContentSize = imageGeo.size }
                                            .onChange(of: imageGeo.size) { _, s in imageContentSize = s }
                                    }
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .gesture(tapGesture(containerSize: geo.size))
                                .gesture(dragGesture(containerSize: geo.size))
                                .gesture(pinchGesture(containerSize: geo.size))
                                .gesture(longPressGesture(containerSize: geo.size))
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

                // Hint bar — at the very bottom
                HStack(spacing: 12) {
                    hintLabel(icon: "hand.tap", text: "tap")
                    hintLabel(icon: "hand.draw", text: "scroll")
                    hintLabel(icon: "hand.tap.fill", text: "hold")

                    Spacer()

                    Button {
                        isKeyboardActive.toggle()
                        Haptics.light()
                    } label: {
                        Image(systemName: isKeyboardActive ? "keyboard.fill" : "keyboard")
                            .font(.system(size: 16))
                            .foregroundColor(isKeyboardActive ? TarsyTheme.accentAmber : .white.opacity(0.7))
                            .frame(width: 36, height: 28)
                            .background(isKeyboardActive ? TarsyTheme.accentAmber.opacity(0.2) : .white.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .overlay(alignment: .top) {
            if showGalleryHint {
                Text("Saved to your gallery!")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.7))
                    .cornerRadius(8)
                    .padding(.top, 56)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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

    private func tapGesture(containerSize: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let rel = relativePosition(from: value.location, containerSize: containerSize) else { return }
                showTapFeedback(at: value.location)
                Haptics.light()
                connectionManager.send(WSPacket(
                    action: .remoteTap,
                    payload: ["x": f(rel.x), "y": f(rel.y)]
                ))
            }
    }

    // MARK: - Long Press

    private func longPressGesture(containerSize: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: SpatialTapGesture())
            .onEnded { value in
                if case .second(true, let tap) = value, let tap {
                    guard let rel = relativePosition(from: tap.location, containerSize: containerSize) else { return }
                    Haptics.medium()
                    connectionManager.send(WSPacket(
                        action: .remoteLongPress,
                        payload: ["x": f(rel.x), "y": f(rel.y)]
                    ))
                }
            }
    }

    // MARK: - Drag (Swipe/Scroll) — Stateful

    private func dragGesture(containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard let rel = relativePosition(from: value.startLocation, containerSize: containerSize) else { return }

                if !isDragActive {
                    isDragActive = true
                    lastDragTranslation = .zero
                    connectionManager.send(WSPacket(
                        action: .remoteScrollStart,
                        payload: ["x": f(rel.x), "y": f(rel.y)]
                    ))
                }

                let now = CFAbsoluteTimeGetCurrent()
                guard now - lastScrollSendTime > 0.033 else { return }
                lastScrollSendTime = now

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

    private func pinchGesture(containerSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
                guard let rel = relativePosition(from: center, containerSize: containerSize) else { return }

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

    private func relativePosition(from point: CGPoint, containerSize: CGSize) -> CGPoint? {
        guard imageContentSize.width > 0, imageContentSize.height > 0 else { return nil }

        let origin = CGPoint(
            x: (containerSize.width - imageContentSize.width) / 2,
            y: (containerSize.height - imageContentSize.height) / 2
        )

        let relX = (point.x - origin.x) / imageContentSize.width
        let relY = (point.y - origin.y) / imageContentSize.height
        guard relX >= 0, relX <= 1, relY >= 0, relY <= 1 else { return nil }
        return CGPoint(x: relX, y: relY)
    }

    // MARK: - Device Buttons

    @ViewBuilder
    private func deviceButton(icon: String, action: String) -> some View {
        Button {
            Haptics.light()
            connectionManager.send(WSPacket(
                action: .remoteButton,
                payload: ["button": action]
            ))
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.15))
                .cornerRadius(18)
        }
    }

    private var screenshotButton: some View {
        Button {
            guard !isCapturingScreenshot else { return }
            Haptics.light()
            takeNativeScreenshot()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if screenshotSaved {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.15))
                .cornerRadius(18)

                // Mini progress bar
                if isCapturingScreenshot {
                    GeometryReader { geo in
                        Capsule()
                            .fill(.white.opacity(0.2))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(TarsyTheme.accentAmber)
                                    .frame(width: geo.size.width * screenshotProgress)
                            }
                    }
                    .frame(width: 36, height: 3)
                    .transition(.opacity)
                }
            }
        }
    }

    private func takeNativeScreenshot() {
        isCapturingScreenshot = true
        screenshotSaved = false
        screenshotProgress = 0

        // Animate: 0 → 0.3 (capturing)
        withAnimation(.easeOut(duration: 0.4)) {
            screenshotProgress = 0.3
        }

        connectionManager.send(WSPacket(action: .screenshotRequest))

        // Animate: 0.3 → 0.7 slowly (waiting for transfer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.linear(duration: 3.0)) {
                screenshotProgress = 0.7
            }
        }

        // Listen for result
        connectionManager.addListener("screenshot") { [self] packet in
            if packet.action == .screenshotResult,
               let base64 = packet.payload?["data"],
               let imageData = Data(base64Encoded: base64),
               let image = UIImage(data: imageData) {

                // Save to Photos
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)

                DispatchQueue.main.async {
                    // Animate: → 1.0 (saved)
                    withAnimation(.easeOut(duration: 0.2)) {
                        screenshotProgress = 1.0
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isCapturingScreenshot = false
                        }
                        screenshotSaved = true
                        Haptics.success()

                        // Show gallery hint only on first screenshot
                        if !hintAlreadyShown {
                            withAnimation(.easeOut(duration: 0.3)) {
                                showGalleryHint = true
                            }
                            hintAlreadyShown = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                withAnimation(.easeOut(duration: 0.4)) {
                                    showGalleryHint = false
                                }
                            }
                        }

                        // Reset checkmark after 2s
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            screenshotSaved = false
                        }
                    }
                }
                connectionManager.removeListener("screenshot")
            }
        }

        // Timeout after 10s
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if isCapturingScreenshot {
                withAnimation { isCapturingScreenshot = false }
                screenshotProgress = 0
                connectionManager.removeListener("screenshot")
            }
        }
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
