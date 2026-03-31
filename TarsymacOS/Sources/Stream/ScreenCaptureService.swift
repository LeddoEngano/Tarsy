import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreImage
import AppKit

@MainActor
class ScreenCaptureService: NSObject, ObservableObject {
    @Published var isCapturing = false
    @Published var availableWindows: [SCWindow] = []
    @Published var selectedWindow: SCWindow?

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var cachedContent: SCShareableContent?
    private var hasPermission = false

    /// Direct pixel buffer callback for H.264 encoding
    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    /// Latest pixel buffer for screenshot capture (updated every frame)
    private(set) var lastPixelBuffer: CVPixelBuffer?

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
            let appWindows = availableWindows.filter {
                $0.owningApplication?.applicationName == appName
            }
            // Pick the largest window — avoids grabbing small widget/preview windows
            if let window = appWindows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                return window
            }
        }

        return nil
    }

    func findWindow(appName: String, preferSmall: Bool) async -> SCWindow? {
        await refreshWindows()
        let appWindows = availableWindows.filter {
            $0.owningApplication?.applicationName == appName && $0.frame.width > 50
        }
        if preferSmall {
            return appWindows.min(by: { $0.frame.width < $1.frame.width })
        } else {
            return appWindows.max(by: { $0.frame.width < $1.frame.width })
        }
    }

    func startCapturing(window: SCWindow, fps: Int, scale: CGFloat) async {
        do {
            try await startCapture(window: window, fps: fps, scale: scale)
        } catch {
            print("[ScreenCapture] Error starting capture: \(error)")
        }
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
            streamOutput = StreamOutput { [weak self] pixelBuffer in
                self?.lastPixelBuffer = pixelBuffer
                self?.onPixelBuffer?(pixelBuffer)
            }
        }
        streamOutput?.pixelBufferHandler = { [weak self] pixelBuffer in
            self?.lastPixelBuffer = pixelBuffer
            self?.onPixelBuffer?(pixelBuffer)
        }

        // Only create new SCStream if we don't have one
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream?.startCapture()
        isCapturing = true
    }

    /// Capture the entire display (for OpenClaw full-screen mode)
    func startDisplayCapture(fps: Int = 20, scale: CGFloat = 0.75) async throws {
        if isCapturing {
            try? await stream?.stopCapture()
        }

        // Refresh content if needed
        if cachedContent == nil {
            await refreshWindows()
        }
        guard let content = cachedContent else {
            throw NSError(domain: "ScreenCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot access screen content"])
        }

        guard let display = content.displays.first else {
            throw NSError(domain: "ScreenCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let contentHeight = display.height
        let contentWidth = display.width

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(contentWidth) * scale)
        config.height = Int(CGFloat(contentHeight) * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.showsCursor = true

        if streamOutput == nil {
            streamOutput = StreamOutput { [weak self] pixelBuffer in
                self?.lastPixelBuffer = pixelBuffer
                self?.onPixelBuffer?(pixelBuffer)
            }
        }
        streamOutput?.pixelBufferHandler = { [weak self] pixelBuffer in
            self?.lastPixelBuffer = pixelBuffer
            self?.onPixelBuffer?(pixelBuffer)
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream?.startCapture()
        isCapturing = true
        selectedWindow = nil
    }

    /// Capture a JPEG screenshot from the current stream
    func captureScreenshot(quality: CGFloat = 0.7) -> Data? {
        guard let pixelBuffer = lastPixelBuffer else { return nil }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality as NSNumber])
    }

    func stopCapture() async {
        if let stream {
            try? await stream.stopCapture()
        }
        // Don't nil out stream/streamOutput — keep for reuse
        isCapturing = false
        lastPixelBuffer = nil
        selectedWindow = nil
    }
}

private class StreamOutput: NSObject, SCStreamOutput {
    var pixelBufferHandler: ((CVPixelBuffer) -> Void)?

    init(handler: @escaping (CVPixelBuffer) -> Void) {
        self.pixelBufferHandler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let imageBuffer = sampleBuffer.imageBuffer else { return }

        pixelBufferHandler?(imageBuffer)
    }
}
