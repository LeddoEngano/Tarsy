import SwiftUI
import TarsyShared
import AVFoundation

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
        tf.text = " "
        return tf
    }

    func updateUIView(_ uiView: HiddenTextField, context: Context) {
        if isActive && !uiView.isFirstResponder {
            uiView.text = " "
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
    @ObservedObject var viewModel: StreamViewModel
    var connectionManager: ConnectionManager
    var workspaceStack: Workspace.WorkspaceStack
    var onClose: () -> Void

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

    // System dialog safety net — shows banner when Mac has a pending
    // TCC/system prompt the user needs to dismiss (e.g. Chrome automation)
    @EnvironmentObject var systemDialogService: SystemDialogService
    @State private var showSystemDialogSheet = false

    private var isWebMode: Bool { workspaceStack == .web || workspaceStack == .fullstack }

    @State private var tapFeedbackPoint: CGPoint? = nil
    @State private var isCapturingScreenshot = false
    @State private var screenshotSaved = false
    @State private var screenshotProgress: CGFloat = 0
    @State private var showGalleryHint = false
    @State private var showUrlBar = false
    @State private var urlText = ""
    @State private var showTabMenu = false
    @State private var browserTabs: [BrowserTab] = []

    private struct BrowserTab: Identifiable {
        let id: Int // 1-based index
        let title: String
        let url: String
        let faviconUrl: String
    }

    // Analog scroll state
    @State private var analogScrollOrigin: CGPoint? = nil
    @State private var analogScrollTimer: Timer? = nil

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

    // Voice input state
    @StateObject private var voiceRecorder = VoiceRecorderController()
    @State private var showLanguagePicker = false
    @State private var micButtonOffset: CGSize = .zero
    @State private var micButtonOffsetBase: CGSize = .zero

    // Measured image content size (from SwiftUI layout)
    @State private var imageContentSize: CGSize = .zero

    var body: some View {
        ZStack {
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

            // Stream + controls
            ZStack {
                // Stream image — fills all available space
                GeometryReader { geo in
                    ZStack {
                        if let layer = viewModel.h264Decoder.displayLayer {
                            H264PlayerView(displayLayer: layer)
                                .id("h264-fullscreen")
                                .frame(width: geo.size.width, height: geo.size.height)
                                .background(
                                    GeometryReader { imageGeo in
                                        Color.clear
                                            .onAppear { imageContentSize = imageGeo.size }
                                            .onChange(of: imageGeo.size) { _, s in imageContentSize = s }
                                    }
                                )
                                .gesture(tapGesture(containerSize: geo.size))
                                .gesture(scrollGesture(containerSize: geo.size))
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

                // Floating controls
                VStack {
                    HStack(spacing: 0) {
                        if isWebMode {
                            HStack(spacing: 16) {
                                webNavButton(icon: "chevron.left", action: .browserBack)
                                webNavButton(icon: "chevron.right", action: .browserForward)
                                webNavButton(icon: "arrow.clockwise", action: .browserRefresh)
                                Button {
                                    Haptics.light()
                                    fetchTabs()
                                } label: {
                                    Image(systemName: "rectangle.stack")
                                        .font(TarsyTheme.font(size: 16, weight: .medium))
                                        .foregroundColor(.white.opacity(0.8))
                                        .frame(width: 28, height: 28)
                                }
                            }

                            Spacer()

                            HStack(spacing: 8) {
                                Text("\(viewModel.fps) fps")
                                    .font(TarsyTheme.font(size: 10))
                                    .foregroundColor(.white.opacity(0.5))
                                Button(action: closeFullscreen) {
                                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                                        .font(TarsyTheme.font(size: 18))
                                        .foregroundColor(.white.opacity(0.6))
                                }
                            }
                        } else {
                            Spacer()

                            HStack(spacing: 8) {
                                Text("\(viewModel.fps) fps")
                                    .font(TarsyTheme.font(size: 10))
                                    .foregroundColor(.white.opacity(0.5))
                                Button(action: closeFullscreen) {
                                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                                        .font(TarsyTheme.font(size: 18))
                                        .foregroundColor(.white.opacity(0.6))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                    // Left column: URL, Screenshot
                    if isWebMode {
                        HStack {
                            Button { showUrlBar = true } label: {
                                Image(systemName: "globe")
                                    .font(TarsyTheme.font(size: 16, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                                    .frame(width: 28, height: 28)
                            }
                            .padding(.leading, 12)
                            .padding(.top, 8)
                            Spacer()
                        }
                    }

                    Spacer()

                    // Left column: mobile device buttons
                    if !isWebMode {
                        HStack {
                            VStack(spacing: 10) {
                                screenshotButton
                                deviceButton(icon: "house.fill", action: "home")
                                deviceButton(icon: "square.stack.3d.up", action: "app_switcher")
                            }
                            .padding(6)
                            .background(.black.opacity(0.4))
                            .cornerRadius(22)
                            Spacer()
                        }
                        .padding(.leading, 12)
                    }

                    Spacer()

                    // Bottom-left screenshot + hint bar
                    if isWebMode {
                        HStack {
                            screenshotButton
                                .padding(.leading, 12)
                            Spacer()
                        }
                        .padding(.bottom, 4)
                    }

                    HStack(spacing: 12) {
                        hintLabel(icon: "hand.tap", text: "tap")
                        hintLabel(icon: isWebMode ? "circle.circle" : "hand.draw", text: isWebMode ? "analog scroll" : "scroll")
                        if !isWebMode {
                            hintLabel(icon: "hand.tap.fill", text: "hold")
                        }

                        Spacer()

                        Button {
                            isKeyboardActive.toggle()
                            Haptics.light()
                        } label: {
                            Image(systemName: isKeyboardActive ? "keyboard.fill" : "keyboard")
                                .font(TarsyTheme.font(size: 16))
                                .foregroundColor(isKeyboardActive ? TarsyTheme.accentAmber : .white.opacity(0.7))
                                .frame(width: 36, height: 28)
                                .background(isKeyboardActive ? TarsyTheme.accentAmber.opacity(0.2) : .white.opacity(0.1))
                                .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
                .allowsHitTesting(true)
            }
        }
        // Floating mic button — always visible, bottom-centered
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
        .overlay(alignment: isWebMode ? .center : .bottom) {
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
                    .padding(.horizontal, isWebMode ? 40 : 16)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: -2)
                }

                if let options = interactiveOptions {
                    InteractiveOptionsView(options: options) { selected in
                        onInteractiveChoice?(selected)
                    }
                    .padding(.horizontal, isWebMode ? 40 : 16)
                }
            }
            .padding(.bottom, isWebMode ? 0 : 140)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeInOut(duration: 0.25), value: interactiveQuestions?.count)
            .animation(.easeInOut(duration: 0.25), value: interactiveOptions?.count)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                // System dialog banner — shows when Mac has a pending
                // TCC prompt (e.g. Chrome automation Allow/Don't Allow)
                // so the user can tap "review" and click Allow remotely.
                SystemDialogBanner(
                    service: systemDialogService,
                    showSheet: $showSystemDialogSheet
                )

                if showGalleryHint {
                    Text("Saved to your gallery!")
                        .font(TarsyTheme.font(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.7))
                        .cornerRadius(8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.top, 56)
        }
        .sheet(isPresented: $showSystemDialogSheet) {
            if let dialog = systemDialogService.currentDialog {
                SystemDialogSheet(dialog: dialog) { label in
                    systemDialogService.click(label, on: dialog)
                    showSystemDialogSheet = false
                }
            }
        }
        .overlay {
            if showTabMenu {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { showTabMenu = false } }

                VStack(spacing: 0) {
                    HStack {
                        Text("tabs")
                            .font(TarsyTheme.font(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Button { withAnimation { showTabMenu = false } } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(TarsyTheme.font(size: 18))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    ScrollView {
                        VStack(spacing: 6) {
                            if browserTabs.isEmpty {
                                HStack {
                                    ProgressView()
                                        .tint(.white.opacity(0.5))
                                        .scaleEffect(0.8)
                                    Text("loading tabs...")
                                        .font(TarsyTheme.font(size: 11))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                                .padding(.vertical, 20)
                            }
                            ForEach(browserTabs) { tab in
                                HStack(spacing: 10) {
                                    AsyncImage(url: URL(string: tab.faviconUrl)) { image in
                                        image.resizable()
                                    } placeholder: {
                                        Image(systemName: "globe")
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                    .frame(width: 20, height: 20)
                                    .cornerRadius(4)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tab.title)
                                            .font(TarsyTheme.font(size: 12))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Text(tab.url)
                                            .font(TarsyTheme.font(size: 9))
                                            .foregroundColor(.white.opacity(0.4))
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Button {
                                        closeTab(tab)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(TarsyTheme.font(size: 10))
                                            .foregroundColor(.white.opacity(0.4))
                                            .frame(width: 24, height: 24)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.08))
                                .cornerRadius(8)
                                .contentShape(Rectangle())
                                .onTapGesture { switchToTab(tab) }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .frame(maxWidth: 350, maxHeight: 300)
                .background(.ultraThinMaterial)
                .cornerRadius(14)
                .shadow(color: .black.opacity(0.5), radius: 20)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .alert("open url", isPresented: $showUrlBar) {
            TextField("https://...", text: $urlText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("go") {
                let url = urlText.hasPrefix("http") ? urlText : "https://\(urlText)"
                connectionManager.send(WSPacket(action: .browserOpenUrl, payload: ["url": url]))
                urlText = ""
            }
            Button("cancel", role: .cancel) { urlText = "" }
        }
        .onAppear {
#if DEBUG
            print("[InteractiveStream] onAppear — fps=\(viewModel.fps) isConnected=\(viewModel.isConnected)")
#endif
            requestHighQuality()
            setupVoiceTodoListener()
            if isWebMode {
                AppDelegate.orientationLock = .landscape
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
                }
            }
        }
        .onDisappear {
#if DEBUG
            print("[InteractiveStream] onDisappear — fps=\(viewModel.fps) isConnected=\(viewModel.isConnected)")
#endif
            requestNormalQuality()
            stopAnalogScroll()
            voiceRecorder.voiceInput.stopRecording(commit: false, completion: nil)
            connectionManager.removeListener("voice-todo")
            if isWebMode {
                AppDelegate.orientationLock = .portrait
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
                }
                // Force navigation bar to recalculate layout after rotation settles
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    Self.forceNavigationBarLayout()
                }
            }
        }
        .alert("select language", isPresented: $showLanguagePicker) {
            ForEach(VoiceInputManager.supportedLanguages, id: \.code) { lang in
                Button(lang.name) {
                    voiceRecorder.voiceInput.setLanguage(lang.code)
                    showLanguagePicker = false
                }
            }
            Button("cancel", role: .cancel) {}
        }
        .onChange(of: voiceRecorder.voiceInput.needsLanguageSelection) { _, needs in
            if needs {
                showLanguagePicker = true
                voiceRecorder.voiceInput.needsLanguageSelection = false
                voiceRecorder.voiceInput.stopRecording(commit: false, completion: nil)
            }
        }
        .task {
            configureVoiceRecorder()
        }
    }

    private func requestHighQuality() {
#if DEBUG
        print("[InteractiveStream] requestHighQuality — sending stream:start quality=high stack=\(workspaceStack.rawValue)")
#endif
        connectionManager.send(WSPacket(
            action: .streamStart,
            payload: ["quality": "high", "stack": workspaceStack.rawValue]
        ))
    }

    private func requestNormalQuality() {
#if DEBUG
        print("[InteractiveStream] requestNormalQuality — sending stream:start quality=normal stack=\(workspaceStack.rawValue)")
#endif
        connectionManager.send(WSPacket(
            action: .streamStart,
            payload: ["quality": "normal", "stack": workspaceStack.rawValue]
        ))
    }

    // MARK: - Tap

    private func tapGesture(containerSize: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                // Minimize todo overlay on any stream tap
                if !todoManager.isMinimized {
                    todoManager.minimize()
                }
                if isKeyboardActive {
                    isKeyboardActive = false
                    return
                }
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
                .font(TarsyTheme.font(size: 16))
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
                            .font(TarsyTheme.font(size: 16, weight: .bold))
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "camera.viewfinder")
                            .font(TarsyTheme.font(size: 16))
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

        connectionManager.send(WSPacket(action: .screenshotRequest, payload: ["stack": workspaceStack.rawValue]))

        // Animate: 0.3 → 0.7 slowly (waiting for transfer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.linear(duration: 3.0)) {
                screenshotProgress = 0.7
            }
        }

        // Handle screenshot received (shared logic for both packet and binary paths)
        let handleScreenshotData: (Data) -> Void = { [self] imageData in
            guard let image = UIImage(data: imageData) else { return }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)

            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.2)) {
                    screenshotProgress = 1.0
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isCapturingScreenshot = false
                    }
                    screenshotSaved = true
                    Haptics.success()

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

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        screenshotSaved = false
                    }
                }
                connectionManager.removeListener("screenshot")
                connectionManager.onScreenshotReceived = nil
            }
        }

        // Listen for JSON screenshotResult packet (primary path)
        connectionManager.addListener("screenshot") { [self] packet in
            if packet.action == .screenshotResult {
                if let base64 = packet.payload?["data"],
                   let imageData = Data(base64Encoded: base64) {
                    handleScreenshotData(imageData)
                } else if packet.payload?["error"] != nil {
                    // Screenshot failed on macOS side
                    DispatchQueue.main.async {
                        withAnimation { isCapturingScreenshot = false }
                        screenshotProgress = 0
                        connectionManager.removeListener("screenshot")
                        connectionManager.onScreenshotReceived = nil
                    }
                }
            } else if packet.action == .error {
                DispatchQueue.main.async {
                    withAnimation { isCapturingScreenshot = false }
                    screenshotProgress = 0
                    connectionManager.removeListener("screenshot")
                    connectionManager.onScreenshotReceived = nil
                }
            }
        }

        // Listen for binary SCRN data (fallback for direct binary screenshots)
        connectionManager.onScreenshotReceived = { imageData in
            handleScreenshotData(imageData)
        }

        // Timeout after 10s
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if isCapturingScreenshot {
                withAnimation { isCapturingScreenshot = false }
                screenshotProgress = 0
                connectionManager.removeListener("screenshot")
                connectionManager.onScreenshotReceived = nil
            }
        }
    }

    // MARK: - Unified Scroll

    private func scrollGesture(containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: isWebMode ? 4 : 8)
            .onChanged { value in
                if isWebMode {
                    handleAnalogScrollChanged(value: value, containerSize: containerSize)
                } else {
                    handleDragChanged(value: value, containerSize: containerSize)
                }
            }
            .onEnded { value in
                if isWebMode {
                    stopAnalogScroll()
                } else {
                    handleDragEnded()
                }
            }
    }

    private func handleDragChanged(value: DragGesture.Value, containerSize: CGSize) {
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

    private func handleDragEnded() {
        if isDragActive {
            connectionManager.send(WSPacket(
                action: .remoteScrollEnd,
                payload: ["x": "0.5", "y": "0.5"]
            ))
            isDragActive = false
            lastDragTranslation = .zero
        }
    }

    private func handleAnalogScrollChanged(value: DragGesture.Value, containerSize: CGSize) {
        if analogScrollOrigin == nil {
            analogScrollOrigin = value.startLocation
            Haptics.light()
        }

        guard let origin = analogScrollOrigin,
              let rel = relativePosition(from: origin, containerSize: containerSize) else { return }

        let dy = value.location.y - origin.y
        let deadZone: CGFloat = 15
        let maxDistance: CGFloat = 150

        let scrollY: CGFloat
        if abs(dy) < deadZone {
            scrollY = 0
        } else {
            let adjusted = dy > 0 ? dy - deadZone : dy + deadZone
            scrollY = max(-1, min(1, adjusted / maxDistance))
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastScrollSendTime > 0.033 else { return }
        lastScrollSendTime = now

        if abs(scrollY) > 0.05 {
            connectionManager.send(WSPacket(
                action: .remoteScroll,
                payload: [
                    "x": f(rel.x),
                    "y": f(rel.y),
                    "dx": "0",
                    "dy": f(scrollY * 10)
                ]
            ))
        }
    }

    // MARK: - Web Controls

    @ViewBuilder
    private func webNavButton(icon: String, action: WSAction) -> some View {
        Button {
            Haptics.light()
            connectionManager.send(WSPacket(action: action))
        } label: {
            Image(systemName: icon)
                .font(TarsyTheme.font(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 28, height: 28)
        }
    }

    private func fetchTabs() {
        // Show menu immediately with loading state
        withAnimation { showTabMenu = true }
        browserTabs = []

        connectionManager.addListener("browser-tabs") { packet in
            if packet.action == .browserTabListResult, let tabsData = packet.payload?["tabs"] {
                let parsed = tabsData.components(separatedBy: "\n").compactMap { line -> BrowserTab? in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    let parts = trimmed.components(separatedBy: "||")
                    guard parts.count >= 3, let index = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
                    return BrowserTab(id: index, title: parts[1], url: parts[2], faviconUrl: parts.count >= 4 ? parts[3] : "")
                }
                DispatchQueue.main.async {
                    browserTabs = parsed
                }
                connectionManager.removeListener("browser-tabs")
            }
        }
        connectionManager.send(WSPacket(action: .browserTabList))

        // Safety timeout — close the spinner if no response after 10s.
        // This can happen if Chrome isn't running on the Mac, the macOS
        // app isn't connected, or the relay drops the response.
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await MainActor.run {
                if browserTabs.isEmpty && showTabMenu {
                    connectionManager.removeListener("browser-tabs")
                    withAnimation { showTabMenu = false }
                }
            }
        }
    }

    private func switchToTab(_ tab: BrowserTab) {
        connectionManager.send(WSPacket(action: .browserTabSwitch, payload: ["index": "\(tab.id)"]))
        withAnimation { showTabMenu = false }
    }

    private func closeTab(_ tab: BrowserTab) {
        connectionManager.send(WSPacket(action: .browserTabClose, payload: ["index": "\(tab.id)"]))
        withAnimation { browserTabs.removeAll { $0.id == tab.id } }
    }

    private func closeFullscreen() {
        if isWebMode {
            AppDelegate.orientationLock = .portrait
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
        onClose()
        // Force navigation bar layout after dismiss + rotation animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.forceNavigationBarLayout()
        }
    }

    /// Walks the window's view hierarchy to find any UINavigationBar and forces layout recalculation.
    private static func forceNavigationBarLayout() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else { return }

        func findNavBars(in view: UIView) {
            if let navBar = view as? UINavigationBar {
                navBar.setNeedsLayout()
                navBar.layoutIfNeeded()
                // Also force the parent navigation controller's view
                navBar.superview?.setNeedsLayout()
                navBar.superview?.layoutIfNeeded()
            }
            for subview in view.subviews {
                findNavBars(in: subview)
            }
        }
        findNavBars(in: window)
    }

    private func stopAnalogScroll() {
        analogScrollOrigin = nil
        analogScrollTimer?.invalidate()
        analogScrollTimer = nil
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
            Image(systemName: icon).font(TarsyTheme.font(size: 10))
            Text(text).font(TarsyTheme.font(size: 10))
        }
        .foregroundColor(.white.opacity(0.7))
    }

    // MARK: - Floating Mic Button

    private var micButton: some View {
        // NOTE: HUD and pulsing ring are applied as overlays (not ZStack
        // siblings) so they cannot affect the Image's layout size. Siblings
        // would make the ZStack expand to the HUD's width when recording
        // starts, and since the button is pinned to `bottomTrailing`, the
        // Image would visibly teleport left as the ZStack grew.
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
            // Real drop shadow (dark) for elevation — the button sits on top
            // of an unpredictable live stream, so it needs to pop.
            .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 8)
            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
            // Glow overlay when recording
            .shadow(
                color: (voiceRecorder.isCancelling ? TarsyTheme.accentTerracotta : TarsyTheme.accentAmber)
                    .opacity(voiceRecorder.isRecording ? 0.5 : 0),
                radius: 20
            )
            .scaleEffect(voiceRecorder.isCancelling ? 1.1 : 1.0)
            .offset(x: voiceRecorder.dragOffsetX * 0.4)
            // Pulsing ring — centered on the mic, doesn't affect layout
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
            // Recording HUD — floats above the mic, doesn't affect layout
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
    }

    // MARK: - Voice Recording

    private func configureVoiceRecorder() {
        voiceRecorder.onCommit = { [self] transcription in
            sendVoiceCommand(transcription)
        }
    }

    private func sendVoiceCommand(_ transcription: String) {
        // Persist voice message to chat history
        onVoiceMessage?(transcription)

        // Prepend voice directive so system instructions come before user input (prevents prompt injection)
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
            // No session yet — create one with the message
            var createPayload = [
                "path": workspacePath,
                "engineType": engineType.rawValue,
                "aiContext": aiContext,
                "message": fullMessage
            ]
            if !workspaceId.isEmpty { createPayload["workspaceId"] = workspaceId }
            connectionManager.send(WSPacket(action: .engineCreate, payload: createPayload))
            todoManager.addItem(text: transcription, sessionId: "pending")
        }
    }

    // MARK: - Voice Todo Listener

    private func setupVoiceTodoListener() {
        connectionManager.addListener("voice-todo") { [self] packet in
            // Capture sessionId from engineCreate response (for voice-initiated sessions)
            if packet.action == .engineCreate,
               let sessionId = packet.payload?["sessionId"] {
                DispatchQueue.main.async {
                    // Update pending todo items with real sessionId
                    for i in todoManager.items.indices where todoManager.items[i].sessionId == "pending" {
                        todoManager.items[i].sessionId = sessionId
                    }
                    // Propagate sessionId back to parent
                    engineSessionId = sessionId
                    onSessionCreated?(sessionId)
                }
            }
        }
    }
}

// Uses Haptics from Theme/Haptics.swift
