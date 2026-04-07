import SwiftUI
import AVFoundation
import TarsyShared

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var machineService: MachineService
    @EnvironmentObject var connectionManager: ConnectionManager
    @StateObject private var pairingService = PairingService()
    @State private var scannedCode: String?
    @State private var showHelp = false
    @State private var showManualEntry = false
    @State private var manualCode = ""
    @State private var errorMessage: String?
    @State private var isProcessing = false
    @State private var isPaired = false
    @State private var cameraPermissionDenied = false

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(TarsyTheme.font(size: 16, weight: .medium))
                            .foregroundColor(TarsyTheme.textPrimary)
                            .frame(width: 36, height: 36)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                if isPaired {
                    pairedConfirmation
                } else if isProcessing {
                    processingView
                } else {
                    if cameraPermissionDenied {
                        // Camera access denied
                        VStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 36))
                                .foregroundColor(TarsyTheme.textSecondary)
                            Text("camera access required")
                                .font(TarsyTheme.font(size: 15, weight: .medium))
                                .foregroundColor(TarsyTheme.textPrimary)
                            Text("enable camera access in Settings\nto scan the QR code")
                                .font(TarsyTheme.font(size: 12))
                                .foregroundColor(TarsyTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                            Button(action: {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }) {
                                Text("Open Settings")
                                    .font(TarsyTheme.font(size: 13, weight: .medium))
                                    .foregroundColor(TarsyTheme.backgroundPrimary)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(TarsyTheme.textAccent))
                            }
                        }
                        .frame(width: 260, height: 260)
                        .padding(.bottom, 20)
                    } else {
                        // Camera viewfinder
                        QRCameraView(
                            onScan: handleScan,
                            onPermissionDenied: { cameraPermissionDenied = true }
                        )
                            .frame(width: 260, height: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(TarsyTheme.backgroundTertiary, lineWidth: 2)
                            )
                            .padding(.bottom, 20)
                    }

                    Text(cameraPermissionDenied
                        ? "or use the manual code entry below"
                        : "point your camera at the QR\ncode on your mac")
                        .font(TarsyTheme.font(size: 13))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.bottom, 8)

                    if let error = errorMessage {
                        Text(error)
                            .font(TarsyTheme.font(size: 12))
                            .foregroundColor(TarsyTheme.accentTerracotta)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.bottom, 8)
                    }
                }

                Spacer()

                if !isPaired && !isProcessing {
                    // Action buttons
                    VStack(spacing: 12) {
                        Button(action: { showHelp = true }) {
                            Text("Learn how to connect")
                                .font(TarsyTheme.font(size: 13, weight: .medium))
                                .foregroundColor(TarsyTheme.textAccent)
                        }

                        Button(action: { showManualEntry = true }) {
                            Text("Enter connection code")
                                .font(TarsyTheme.font(size: 13, weight: .medium))
                                .foregroundColor(TarsyTheme.textSecondary)
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .sheet(isPresented: $showHelp) {
            HowToConnectSheet()
        }
        .sheet(isPresented: $showManualEntry) {
            ManualCodeEntrySheet(
                pairingService: pairingService,
                onPaired: handlePairSuccess
            )
        }
    }

    private var processingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(TarsyTheme.textPrimary)
            Text("connecting...")
                .font(TarsyTheme.font(size: 13))
                .foregroundColor(TarsyTheme.textSecondary)
        }
    }

    private var pairedConfirmation: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(TarsyTheme.accentMoss)

            Text("mac connected")
                .font(TarsyTheme.font(size: 18, weight: .bold))
                .foregroundColor(TarsyTheme.textPrimary)

            Text("your mac is now linked to your account")
                .font(TarsyTheme.font(size: 13))
                .foregroundColor(TarsyTheme.textSecondary)
        }
    }

    private func handleScan(_ code: String) {
        guard !isProcessing, scannedCode == nil else {
            print("[QRScanner] Ignoring scan — already processing or scanned")
            return
        }
        print("[QRScanner] Scanned raw value: \(code)")
        scannedCode = code

        guard let url = URL(string: code),
              let params = PairingService.parsePairingURL(url) else {
            print("[QRScanner] Failed to parse QR URL: \(code)")
            errorMessage = "invalid QR code — make sure you're scanning the Tarsy pairing code"
            scannedCode = nil
            return
        }

        print("[QRScanner] Parsed machineId=\(params.machineId), token=\(params.token.prefix(8))...")

        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()

        Task {
            await claimMachine(machineId: params.machineId, token: params.token)
        }
    }

    private func claimMachine(machineId: String, token: String) async {
        isProcessing = true
        errorMessage = nil
        print("[QRScanner] Claiming machine \(machineId)...")

        do {
            _ = try await pairingService.claimMachine(machineId: machineId, pairingToken: token)
            print("[QRScanner] Claim succeeded!")
            await handlePairSuccess()
        } catch {
            print("[QRScanner] Claim failed: \(error)")
            errorMessage = "expired or invalid code — generate a new one on your mac"
            isProcessing = false
            scannedCode = nil
        }
    }

    private func handlePairSuccess() async {
        isPaired = true

        let notification = UINotificationFeedbackGenerator()
        notification.notificationOccurred(.success)

        // Refresh machines and auto-connect
        await machineService.fetchMachine()

        if machineService.isOnline {
            do {
                let session = try await supabase.auth.session
                connectionManager.smartConnect(
                    lanHost: machineService.bestIP,
                    port: TarsyConfig.websocketPort,
                    token: session.accessToken
                )
            } catch {}
        }

        // Dismiss after a brief moment
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        dismiss()
    }
}

// MARK: - QR Camera View (UIKit bridge)

struct QRCameraView: UIViewRepresentable {
    let onScan: (String) -> Void
    var onPermissionDenied: (() -> Void)?

    func makeUIView(context: Context) -> QRCameraUIView {
        let view = QRCameraUIView()
        view.onScan = onScan
        view.onPermissionDenied = onPermissionDenied
        return view
    }

    func updateUIView(_ uiView: QRCameraUIView, context: Context) {}
}

class QRCameraUIView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onPermissionDenied: (() -> Void)?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false
    private var hasSetup = false

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
        if !hasSetup {
            hasSetup = true
            checkPermissionAndSetup()
        }
    }

    private func checkPermissionAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.configureSession()
                    } else {
                        self.onPermissionDenied?()
                    }
                }
            }
        default:
            onPermissionDenied?()
        }
    }

    private func configureSession() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = bounds
        layer.addSublayer(preview)

        captureSession = session
        previewLayer = preview

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }

        // Only process tarsy:// URLs
        guard value.hasPrefix("tarsy://pair") else { return }

        hasScanned = true
        onScan?(value)
    }

    deinit {
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            session?.stopRunning()
        }
    }
}

// MARK: - How to Connect Sheet

struct HowToConnectSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("how to connect your mac")
                    .font(TarsyTheme.font(size: 18, weight: .bold))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .padding(.bottom, 28)

                stepRow(number: 1, text: "download tarsy for mac\nfrom tarsy.dev")
                stepRow(number: 2, text: "install and open the app")
                stepRow(number: 3, text: "sign in and grant\npermissions")
                stepRow(number: 4, text: "a QR code will appear —\nscan it with this camera")

                Spacer()

                Button(action: {
                    if let url = URL(string: "https://tarsy.dev") {
                        UIApplication.shared.open(url)
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .font(TarsyTheme.font(size: 13))
                        Text("Download for Mac")
                            .font(TarsyTheme.font(size: 14, weight: .medium))
                    }
                    .foregroundColor(TarsyTheme.backgroundPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(TarsyTheme.textAccent)
                    )
                }
                .padding(.bottom, 12)

                Button(action: { dismiss() }) {
                    Text("Done")
                        .font(TarsyTheme.font(size: 14, weight: .medium))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .padding(24)
        }
        .presentationDetents([.medium])
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(TarsyTheme.font(size: 12, weight: .bold))
                .foregroundColor(TarsyTheme.backgroundPrimary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(TarsyTheme.textAccent))

            Text(text)
                .font(TarsyTheme.font(size: 14))
                .foregroundColor(TarsyTheme.textPrimary)
                .lineSpacing(4)
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Manual Code Entry Sheet

struct ManualCodeEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var pairingService: PairingService
    let onPaired: () async -> Void
    @State private var code = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("enter connection code")
                    .font(TarsyTheme.font(size: 18, weight: .bold))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .padding(.bottom, 8)

                Text("open tarsy on your mac and find the\nconnection code below the QR code")
                    .font(TarsyTheme.font(size: 13))
                    .foregroundColor(TarsyTheme.textSecondary)
                    .lineSpacing(4)
                    .padding(.bottom, 28)

                TextField("XXXX-XXXX-XXXX", text: $code)
                    .font(TarsyTheme.font(size: 20, weight: .bold))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(TarsyTheme.backgroundSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(TarsyTheme.backgroundTertiary, lineWidth: 1)
                            )
                    )
                    .focused($isFocused)
                    .onChange(of: code) { _, newValue in
                        code = formatCodeInput(newValue)
                    }
                    .padding(.bottom, 12)

                if let error = errorMessage {
                    Text(error)
                        .font(TarsyTheme.font(size: 12))
                        .foregroundColor(TarsyTheme.accentTerracotta)
                        .padding(.bottom, 12)
                }

                Spacer()

                Button(action: submitCode) {
                    Group {
                        if isSubmitting {
                            ProgressView()
                                .tint(TarsyTheme.backgroundPrimary)
                        } else {
                            Text("Connect")
                                .font(TarsyTheme.font(size: 14, weight: .medium))
                        }
                    }
                    .foregroundColor(TarsyTheme.backgroundPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(cleanCode.count == 12 ? TarsyTheme.textAccent : TarsyTheme.backgroundTertiary)
                    )
                }
                .disabled(cleanCode.count != 12 || isSubmitting)
                .padding(.bottom, 12)

                Button(action: { dismiss() }) {
                    Text("Cancel")
                        .font(TarsyTheme.font(size: 14, weight: .medium))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .padding(24)
        }
        .presentationDetents([.medium])
        .onAppear { isFocused = true }
    }

    private var cleanCode: String {
        code.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
    }

    private func formatCodeInput(_ input: String) -> String {
        let clean = input.uppercased().filter { $0.isHexDigit }
        let limited = String(clean.prefix(12))

        if limited.count <= 4 { return limited }
        if limited.count <= 8 {
            let idx = limited.index(limited.startIndex, offsetBy: 4)
            return "\(limited[limited.startIndex..<idx])-\(limited[idx...])"
        }
        let idx1 = limited.index(limited.startIndex, offsetBy: 4)
        let idx2 = limited.index(limited.startIndex, offsetBy: 8)
        return "\(limited[limited.startIndex..<idx1])-\(limited[idx1..<idx2])-\(limited[idx2...])"
    }

    private func submitCode() {
        isSubmitting = true
        errorMessage = nil

        Task {
            do {
                _ = try await pairingService.claimMachineWithCode(cleanCode)
                await onPaired()
                dismiss()
            } catch {
                errorMessage = "invalid or expired code — generate a new one on your mac"
                isSubmitting = false
            }
        }
    }
}

private extension Character {
    var isHexDigit: Bool {
        "0123456789ABCDEFabcdef".contains(self)
    }
}
