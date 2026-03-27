import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreImage
import VideoToolbox

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
    /// Direct pixel buffer callback for H.264 encoding (avoids CGImage conversion)
    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

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
            streamOutput = StreamOutput { [weak self] image in
                self?.onFrame?(image)
            }
        }
        // Wire pixel buffer handler for H.264 path
        streamOutput?.pixelBufferHandler = onPixelBuffer != nil ? { [weak self] pixelBuffer in
            self?.onPixelBuffer?(pixelBuffer)
        } : nil

        // Only create new SCStream if we don't have one
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream?.startCapture()
        isCapturing = true
        print("[ScreenCapture] Started capturing: \(window.title ?? "unknown")")
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
            streamOutput = StreamOutput { [weak self] image in
                self?.onFrame?(image)
            }
        }
        streamOutput?.pixelBufferHandler = onPixelBuffer != nil ? { [weak self] pixelBuffer in
            self?.onPixelBuffer?(pixelBuffer)
        } : nil

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream?.startCapture()
        isCapturing = true
        selectedWindow = nil
        print("[ScreenCapture] Started full-display capture (\(config.width)x\(config.height))")
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
    var pixelBufferHandler: ((CVPixelBuffer) -> Void)?

    init(handler: @escaping (CGImage) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let imageBuffer = sampleBuffer.imageBuffer else { return }

        // If H.264 encoder is connected, send pixel buffer directly (no conversion needed)
        if let pixelBufferHandler {
            pixelBufferHandler(imageBuffer)
            return
        }

        // Fallback: convert to CGImage for MJPEG path
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &cgImage)
        guard let cgImage else { return }

        handler(cgImage)
    }
}
