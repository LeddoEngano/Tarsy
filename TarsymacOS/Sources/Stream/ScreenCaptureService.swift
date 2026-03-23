import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreImage

@MainActor
class ScreenCaptureService: NSObject, ObservableObject {
    @Published var isCapturing = false
    @Published var availableWindows: [SCWindow] = []
    @Published var selectedWindow: SCWindow?

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var cachedContent: SCShareableContent?
    private var hasPermission = false

    var onFrame: ((CGImage) -> Void)?

    // Request permission once at startup without triggering a capture
    func requestPermission() async {
        do {
            cachedContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            hasPermission = true
            updateWindowList()
        } catch {
            print("[ScreenCapture] Permission error: \(error)")
            hasPermission = false
        }
    }

    func refreshWindows() async {
        if !hasPermission {
            await requestPermission()
            return
        }

        do {
            cachedContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            updateWindowList()
        } catch {
            print("[ScreenCapture] Failed to get windows: \(error)")
        }
    }

    private func updateWindowList() {
        guard let content = cachedContent else { return }
        availableWindows = content.windows.filter { window in
            guard let title = window.title, !title.isEmpty else { return false }
            guard window.frame.width > 100, window.frame.height > 100 else { return false }
            return true
        }
    }

    func findWindow(forStack stack: String) async -> SCWindow? {
        await refreshWindows()

        let targetApps: [String]
        switch stack {
        case "web":
            targetApps = ["Google Chrome", "Safari", "Firefox", "Arc", "Microsoft Edge", "Brave Browser"]
        case "mobile":
            targetApps = ["Simulator", "Xcode Previews"]
        case "backend":
            targetApps = ["Terminal", "iTerm2", "Warp", "Alacritty", "kitty", "Ghostty", "cmux"]
        default:
            targetApps = ["Google Chrome", "Safari", "Simulator", "Terminal"]
        }

        for appName in targetApps {
            if let window = availableWindows.first(where: {
                $0.owningApplication?.applicationName == appName
            }) {
                return window
            }
        }

        return availableWindows.first
    }

    func startCapture(window: SCWindow, fps: Int = 10, scale: CGFloat = 0.5, cropTitleBar: Bool = false) async throws {
        // If already capturing, just stop the old stream first without destroying everything
        if isCapturing {
            try? await stream?.stopCapture()
        }

        selectedWindow = window
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let titleBarHeight: CGFloat = cropTitleBar ? 52 : 0  // Title bar + toolbar in Simulator
        let contentHeight = window.frame.height - titleBarHeight

        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(contentHeight * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.showsCursor = true

        // Crop out title bar by setting sourceRect
        if cropTitleBar {
            config.sourceRect = CGRect(
                x: 0,
                y: titleBarHeight,
                width: window.frame.width,
                height: contentHeight
            )
        }

        // Reuse stream output if possible
        if streamOutput == nil {
            streamOutput = StreamOutput { [weak self] image in
                self?.onFrame?(image)
            }
        }

        // Only create new SCStream if we don't have one
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream?.startCapture()
        isCapturing = true
        print("[ScreenCapture] Started capturing: \(window.title ?? "unknown")")
    }

    func stopCapture() async {
        if let stream {
            try? await stream.stopCapture()
        }
        // Don't nil out stream/streamOutput — keep for reuse
        isCapturing = false
        selectedWindow = nil
        print("[ScreenCapture] Stopped")
    }
}

private class StreamOutput: NSObject, SCStreamOutput {
    let handler: (CGImage) -> Void
    private let ciContext = CIContext() // Reuse CIContext for performance

    init(handler: @escaping (CGImage) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let imageBuffer = sampleBuffer.imageBuffer else { return }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        handler(cgImage)
    }
}
