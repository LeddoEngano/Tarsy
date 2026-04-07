import SwiftUI
import TarsyShared
import CoreImage.CIFilterBuiltins

private enum Theme {
    static let bg = Color(hex: "131316")
    static let bgCard = Color(hex: "1c1c21")
    static let border = Color(hex: "2a2a30")
    static let textPrimary = Color(hex: "e4e4e7")
    static let textSecondary = Color(hex: "71717a")
    static let textMuted = Color(hex: "52525b")
    static let amber = Color(hex: "ffffff")
    static let moss = Color(hex: "6bc77b")
    static let terracotta = Color(hex: "e5716a")
}

/// Shared QR code pairing component used by both OnboardingWindow and PairingQRWindow.
/// Handles token generation, QR rendering, countdown, auto-refresh, and paired state.
struct PairingQRCodeView: View {
    let machineId: UUID?
    var onPaired: (() -> Void)?
    @StateObject private var pairingService = PairingService()

    @State private var qrPayloadURL: String?
    @State private var qrConnectionCode: String?
    @State private var qrExpiresAt: Date?
    @State private var qrTimeRemaining: TimeInterval = 0
    @State private var qrImage: NSImage?
    @State private var isGeneratingQR = false
    @State private var isPaired = false
    @State private var pairedUserName: String?
    @State private var isCheckingPair = false
    @State private var pairCheckTick = 0

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            if isPaired {
                pairedView
            } else {
                qrView
            }
        }
        .task(id: machineId) {
            // Retriggers when machineId changes (e.g. nil → UUID after daemon starts)
            await generateQR()
        }
        .onReceive(timer) { _ in
            updateCountdown()
            checkIfPaired()
        }
    }

    private var pairedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(Theme.moss)

            Text("paired successfully!")
                .font(TarsyTheme.font(size: 14, weight: .medium))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            onPaired?()
        }
    }

    private var qrView: some View {
        VStack(spacing: 12) {
            Text("scan this code with Tarsy\non your iPhone")
                .font(TarsyTheme.font(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.bottom, 4)

            if let image = qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 4)
            } else {
                ProgressView()
                    .frame(width: 140, height: 140)
                    .padding(.bottom, 4)
            }

            if let code = qrConnectionCode {
                Text(PairingService.formatConnectionCode(code))
                    .font(TarsyTheme.font(size: 16, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .kerning(2)
                    .textSelection(.enabled)
                    .padding(.bottom, 2)
            }

            if qrTimeRemaining <= 0, qrPayloadURL != nil {
                Button(action: { Task { await generateQR() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(TarsyTheme.font(size: 10))
                        Text("refresh code")
                            .font(TarsyTheme.font(size: 11))
                    }
                    .foregroundColor(Theme.amber)
                }
                .buttonStyle(.plain)
                .pointerOnHover()
            }
        }
    }

    // MARK: - Logic

    private func generateQR() async {
        guard let machineId, !isGeneratingQR else { return }
        isGeneratingQR = true
        defer { isGeneratingQR = false }

        do {
            let url = try await pairingService.refreshPairingToken(machineId: machineId)
            qrPayloadURL = url
            qrConnectionCode = pairingService.currentConnectionCode
            qrExpiresAt = pairingService.expiresAt
            qrImage = makeQRImage(from: url)
            updateCountdown()
        } catch {
            #if DEBUG
            print("[PairingQRCodeView] Generation failed: \(error)")
            #endif
        }
    }

    private func updateCountdown() {
        guard let expiry = qrExpiresAt else {
            qrTimeRemaining = 0
            return
        }
        let remaining = expiry.timeIntervalSinceNow
        if remaining <= 0 {
            qrTimeRemaining = 0
        } else {
            qrTimeRemaining = remaining
        }
    }

    private func checkIfPaired() {
        // Poll every 3 seconds (not every 1s tick)
        pairCheckTick += 1
        guard pairCheckTick % 3 == 0,
              !isPaired, !isCheckingPair,
              let token = pairingService.currentToken,
              let machineId else { return }

        isCheckingPair = true
        Task {
            defer { isCheckingPair = false }
            // If the token row is gone, iOS consumed it = paired
            let result: [MachinePairingRow] = try await supabase
                .from("machine_pairings")
                .select("id")
                .eq("machine_id", value: machineId.uuidString)
                .eq("pairing_token", value: token)
                .execute()
                .value

            if result.isEmpty {
                withAnimation { isPaired = true }
            }
        }
    }

    private func formatCountdown(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d remaining", mins, secs)
    }

    private func makeQRImage(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }
        let scale = 10.0
        let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: transformed.extent.width, height: transformed.extent.height))
    }
}

private struct MachinePairingRow: Codable {
    let id: UUID
}
