import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreImage
import AppKit
import os.log

private let logger = Logger(subsystem: "com.tarsy.macos", category: "ScreenCapture")

@MainActor
class ScreenCaptureService: NSObject, ObservableObject {
    @Published var isCapturing = false
    @Published var availableWindows: [SCWindow] = []
    @Published var selectedWindow: SCWindow?

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var cachedContent: SCShareableContent?
    private(set) var hasPermission = false

    /// Set to true after SCShareableContent fails with -3801 (TCC declined).
    /// Prevents retrying in the same app session which would show repeated dialogs.
    private(set) var permissionDeclined = false

    /// Direct pixel buffer callback for H.264 encoding
    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    /// Latest pixel buffer for screenshot capture (updated every frame)
    private(set) var lastPixelBuffer: CVPixelBuffer?

    // MARK: - Permission Check

    /// Reliable screen recording permission check.
    /// CGPreflightScreenCaptureAccess() directly queries the TCC database.
    /// NOTE: CGWindowListCopyWindowInfo is NOT reliable on macOS 15+ — it returns
    /// window names for system windows (Dock, menu bar) even WITHOUT permission.
    static func isScreenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    // MARK: - Permission Request

    func requestPermission() async {
        // If already declined this session, don't retry — avoids dialog spam
        guard !permissionDeclined else { return }

        // Pre-check: if CGPreflight says no, don't call SCShareableContent
        // (which would show a dialog the user can't interact with remotely)
        guard CGPreflightScreenCaptureAccess() else {
            logger.warning("Screen recording not authorized — user needs to enable in System Settings")
            hasPermission = false
            return
        }

        do {
            cachedContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            hasPermission = true
            permissionDeclined = false
            updateWindowList()
            logger.info("Permission granted, \(self.availableWindows.count) windows available")
        } catch {
            let nsError = error as NSError
            logger.error("SCShareableContent failed (code \(nsError.code)): \(nsError.localizedDescription)")
            hasPermission = false
            if nsError.code == -3801 {
                permissionDeclined = true
                logger.error("TCC declined — will not retry until app restarts")
            }
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
            logger.error("Failed to refresh windows: \(error.localizedDescription)")
            let nsError = error as NSError
            if nsError.code == -3801 {
                hasPermission = false
                permissionDeclined = true
            }
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

        logger.debug("findWindow(forStack: \(stack)) — hasPermission: \(self.hasPermission), windows: \(self.availableWindows.count)")

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
            if let window = appWindows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                logger.info("Found window '\(window.title ?? "?")' from \(appName)")
                return window
            }
        }

        logger.warning("No matching window found for stack: \(stack)")
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
            #if DEBUG
            print("[ScreenCapture] Error starting capture: \(error)")
            #endif
        }
    }

    func startCapture(window: SCWindow, fps: Int = 10, scale: CGFloat = 0.5, cropTitleBar: Bool = false) async throws {
        if isCapturing {
            try? await stream?.stopCapture()
        }

        selectedWindow = window
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let titleBarHeight: CGFloat = cropTitleBar ? 52 : 0
        let contentHeight = window.frame.height - titleBarHeight

        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(contentHeight * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.showsCursor = !cropTitleBar

        if cropTitleBar {
            config.sourceRect = CGRect(
                x: 0,
                y: titleBarHeight,
                width: window.frame.width,
                height: contentHeight
            )
        }

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

        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream?.startCapture()
        isCapturing = true
    }

    func startDisplayCapture(fps: Int = 20, scale: CGFloat = 0.75) async throws {
        if isCapturing {
            try? await stream?.stopCapture()
        }

        if cachedContent == nil {
            await refreshWindows()
        }
        guard let content = cachedContent else {
            throw NSError(domain: "ScreenCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot access screen content"])
        }

        guard let display = content.displays.first else {
            throw NSError(domain: "ScreenCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
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
        stream = nil
        streamOutput = nil
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
