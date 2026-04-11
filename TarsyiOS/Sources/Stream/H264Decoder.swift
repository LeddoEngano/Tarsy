import Foundation
import AVFoundation
import VideoToolbox
import UIKit
import CoreMedia
import CoreImage

/// Hardware-accelerated video decoder supporting both HEVC (H.265) and H.264.
/// Receives Annex B NAL units from the relay and displays them via AVSampleBufferDisplayLayer.
/// Auto-detects codec from the NAL unit types in the first keyframe.
class H264Decoder: ObservableObject {
    @Published var displayLayer: AVSampleBufferDisplayLayer?
    @Published var fps: Int = 0

    private var formatDescription: CMVideoFormatDescription?
    private var vps: Data? // HEVC only
    private var sps: Data?
    private var pps: Data?
    private var isHEVC = false
    private var codecDetected = true // Default to H.264, switch to HEVC if VPS detected
    private var frameCount = 0
    private var fpsTimer: Timer?
    private let ciContext = CIContext()
    private let startCode = Data([0x00, 0x00, 0x00, 0x01])
    private let processingQueue = DispatchQueue(label: "video.decoding", qos: .userInteractive)
    private var totalFramesReceived = 0
    private var totalFramesDecoded = 0

    /// Screenshot support: parallel VTDecompressionSession to capture decoded pixel buffers
    private var screenshotSession: VTDecompressionSession?
    private var screenshotFormatDesc: CMVideoFormatDescription?
    private var lastDecodedPixelBuffer: CVPixelBuffer?
    private let lastFrameLock = NSLock()

    init() {
        setupDisplayLayer()
    }

    private func setupDisplayLayer() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.preventsDisplaySleepDuringVideoPlayback = false
        self.displayLayer = layer
    }

    func start() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.fps = self?.frameCount ?? 0
                self?.frameCount = 0
            }
        }
    }

    func stop() {
        fpsTimer?.invalidate()
        fpsTimer = nil
        displayLayer?.flushAndRemoveImage()
        formatDescription = nil
        lastFrameLock.lock()
        lastDecodedPixelBuffer = nil
        lastFrameLock.unlock()
        if let s = screenshotSession { VTDecompressionSessionInvalidate(s) }
        screenshotSession = nil
        screenshotFormatDesc = nil
        vps = nil
        sps = nil
        pps = nil
        fps = 0
        frameCount = 0
        isHEVC = false
        codecDetected = false
        totalFramesReceived = 0
        totalFramesDecoded = 0
    }

    /// Stops decoding and provisions a fresh AVSampleBufferDisplayLayer.
    ///
    /// After the app is backgrounded the display layer can land in `.failed`
    /// state and subsequent enqueue() calls silently drop frames — flushing
    /// alone is not enough to recover, per Apple's docs the layer must be
    /// recreated. Call this instead of `stop()` when you plan to restart the
    /// stream (e.g. after a WebSocket reconnect).
    func reset() {
        stop()
        // Swap in a brand new layer so any subsequent frame flow starts
        // against a clean, non-failed layer. @Published pushes this to SwiftUI
        // and H264ContainerView.ensureLayerAttached re-parents it on the next
        // update pass.
        setupDisplayLayer()
    }

    func receiveFrame(_ data: Data) {
        processingQueue.async { [weak self] in
            self?.decodeFrame(data)
        }
    }

    private func decodeFrame(_ data: Data) {
        guard data.count > 1 else { return }
        totalFramesReceived += 1

        let isKeyframe = data[0] == 0x01
        let nalData = data.dropFirst()
        let nalUnits = parseNALUnits(nalData)

        #if DEBUG
        if totalFramesReceived <= 3 || totalFramesReceived % 120 == 0 {
            let codec = codecDetected ? (isHEVC ? "HEVC" : "H264") : "detecting"
            print("[Decoder] Frame #\(totalFramesReceived) \(codec) size=\(data.count) key=\(isKeyframe) nals=\(nalUnits.count) decoded=\(totalFramesDecoded)")
        }
        #endif

        for nal in nalUnits {
            guard !nal.isEmpty else { continue }

            // Auto-detect codec from first NAL unit type
            if !codecDetected {
                detectCodec(from: nal)
            }

            if isHEVC {
                handleHEVCNal(nal)
            } else {
                handleH264Nal(nal)
            }
        }
    }

    // MARK: - Codec Detection

    private func detectCodec(from nal: Data) {
        // Check if this is a HEVC VPS (type 32) — only HEVC has VPS
        let hevcType = (nal[0] >> 1) & 0x3F
        if hevcType == 32 {
            isHEVC = true
        }
    }

    // MARK: - H.264

    private func handleH264Nal(_ nal: Data) {
        let nalType = nal[0] & 0x1F

        switch nalType {
        case 7: // SPS
            if sps != nal {
                sps = nal
                formatDescription = nil
            }
        case 8: // PPS
            if pps != nal {
                pps = nal
                formatDescription = nil
            }
        case 5: // IDR
            ensureH264FormatDescription()
            if let sb = createSampleBuffer(from: nal, isKeyframe: true) {
                enqueue(sb)
                totalFramesDecoded += 1
            }
        case 1: // Non-IDR
            if formatDescription != nil {
                if let sb = createSampleBuffer(from: nal, isKeyframe: false) {
                    enqueue(sb)
                    totalFramesDecoded += 1
                }
            }
        default:
            break
        }
    }

    private func ensureH264FormatDescription() {
        guard formatDescription == nil, let sps, let pps else { return }

        var desc: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBuffer -> OSStatus in
            pps.withUnsafeBytes { ppsBuffer -> OSStatus in
                let spsPtr = spsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let ppsPtr = ppsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                var pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                var sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
            }
        }

        if status == noErr, let desc {
            formatDescription = desc
        }
    }

    // MARK: - HEVC

    private func handleHEVCNal(_ nal: Data) {
        let nalType = (nal[0] >> 1) & 0x3F

        switch nalType {
        case 32: // VPS
            if vps != nal {
                vps = nal
                formatDescription = nil
            }
        case 33: // SPS
            if sps != nal {
                sps = nal
                formatDescription = nil
            }
        case 34: // PPS
            if pps != nal {
                pps = nal
                formatDescription = nil
            }
        case 19, 20: // IDR_W_RADL, IDR_N_LP
            ensureHEVCFormatDescription()
            if let sb = createSampleBuffer(from: nal, isKeyframe: true) {
                enqueue(sb)
                totalFramesDecoded += 1
            }
        case 0, 1, 2, 3, 4, 5, 6, 7, 8, 9: // Trail (non-IDR)
            if formatDescription != nil {
                if let sb = createSampleBuffer(from: nal, isKeyframe: false) {
                    enqueue(sb)
                    totalFramesDecoded += 1
                }
            }
        default:
            break // SEI and other NAL types — skip
        }
    }

    private func ensureHEVCFormatDescription() {
        guard formatDescription == nil, let vps, let sps, let pps else { return }

        var desc: CMFormatDescription?
        let status = vps.withUnsafeBytes { vpsBuffer -> OSStatus in
            sps.withUnsafeBytes { spsBuffer -> OSStatus in
                pps.withUnsafeBytes { ppsBuffer -> OSStatus in
                    let vpsPtr = vpsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let spsPtr = spsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let ppsPtr = ppsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    var pointers: [UnsafePointer<UInt8>] = [vpsPtr, spsPtr, ppsPtr]
                    var sizes: [Int] = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &desc
                    )
                }
            }
        }

        if status == noErr, let desc {
            formatDescription = desc
        }
    }

    // MARK: - Common

    private func parseNALUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = buffer.count
            var i = 0

            // Find first start code
            while i < count - 3 {
                if base[i] == 0 && base[i+1] == 0 && base[i+2] == 0 && base[i+3] == 1 {
                    break
                }
                i += 1
            }

            while i < count - 3 {
                // Skip past current start code
                let nalStart = i + 4
                guard nalStart < count else { break }

                // Scan for next start code
                var j = nalStart
                while j < count - 3 {
                    if base[j] == 0 && base[j+1] == 0 && base[j+2] == 0 && base[j+3] == 1 {
                        break
                    }
                    j += 1
                }
                let nalEnd = (j < count - 3) ? j : count

                if nalStart < nalEnd {
                    units.append(Data(bytes: base + nalStart, count: nalEnd - nalStart))
                }
                i = nalEnd
            }
        }
        return units
    }

    private func createSampleBuffer(from nalUnit: Data, isKeyframe: Bool) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }

        // Convert to AVCC/HVCC format: 4-byte length prefix
        let nalLength = UInt32(nalUnit.count).bigEndian
        var avccData = Data()
        avccData.reserveCapacity(4 + nalUnit.count)
        withUnsafeBytes(of: nalLength) { avccData.append(contentsOf: $0) }
        avccData.append(nalUnit)

        var blockBuffer: CMBlockBuffer?
        let dataLength = avccData.count

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let blockBuffer else { return nil }

        status = avccData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
        }

        guard status == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataLength
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 20),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
           let dict = attachments.first {
            dict[kCMSampleAttachmentKey_DisplayImmediately] = true
            if !isKeyframe {
                dict[kCMSampleAttachmentKey_DependsOnOthers] = true
            }
        }

        return sampleBuffer
    }

    private func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let layer = displayLayer else { return }

        if layer.status == .failed {
            layer.flush()
            formatDescription = nil
            vps = nil
            sps = nil
            pps = nil
            return
        }

        // Decode in parallel via VTDecompressionSession for screenshot capture
        decodeForScreenshot(sampleBuffer)
        layer.enqueue(sampleBuffer)
        DispatchQueue.main.async { [weak self] in
            self?.frameCount += 1
        }
    }

    /// Decode each frame via a persistent VTDecompressionSession to retain the pixel buffer
    private func decodeForScreenshot(_ sampleBuffer: CMSampleBuffer) {
        guard let fmt = formatDescription else { return }

        // Recreate session if format changed
        if screenshotFormatDesc !== fmt {
            if let s = screenshotSession { VTDecompressionSessionInvalidate(s) }
            screenshotSession = nil
            screenshotFormatDesc = nil

            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: fmt,
                decoderSpecification: nil,
                imageBufferAttributes: attrs as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &session
            )
            guard status == noErr, let session else { return }
            screenshotSession = session
            screenshotFormatDesc = fmt
        }

        guard let session = screenshotSession else { return }

        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [._1xRealTimePlayback], infoFlagsOut: nil) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            self?.lastFrameLock.lock()
            self?.lastDecodedPixelBuffer = imageBuffer
            self?.lastFrameLock.unlock()
        }
    }

    /// Capture a screenshot from the last decoded pixel buffer
    func captureScreenshot() -> UIImage? {
        lastFrameLock.lock()
        let pb = lastDecodedPixelBuffer
        lastFrameLock.unlock()

        guard let pb else {
#if DEBUG
            print("[Screenshot] no decoded pixel buffer")
#endif
            return nil
        }

        let ci = CIImage(cvPixelBuffer: pb)
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        guard let cg = ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)) else {
#if DEBUG
            print("[Screenshot] CIContext.createCGImage failed")
#endif
            return nil
        }
#if DEBUG
        print("[Screenshot] captured \(w)x\(h)")
#endif
        return UIImage(cgImage: cg)
    }

    deinit {
        stop()
    }
}
