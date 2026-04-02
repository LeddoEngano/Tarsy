import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware-accelerated HEVC (H.265) encoder using VideoToolbox.
/// Falls back to H.264 if HEVC hardware encoding is unavailable.
/// Includes adaptive bitrate that adjusts quality based on network conditions.
class H264Encoder {
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var frameCount: Int64 = 0
    private var currentFps: Int = 15
    private var isHEVC = false

    /// Called with encoded video data. The Data contains:
    /// - First byte: 0x01 for keyframe, 0x00 for delta
    /// - Annex B NAL units with 0x00000001 start codes
    var onEncodedFrame: ((Data) -> Void)?

    // MARK: - Adaptive Bitrate

    private var targetBitrate: Int = 1_500_000
    private var currentBitrate: Int = 1_500_000
    private var minBitrate: Int = 300_000
    private var maxBitrate: Int = 6_000_000
    private var consecutiveDrops: Int = 0
    private var consecutiveSuccess: Int = 0
    private var lastAdjustTime: CFAbsoluteTime = 0
    private let adjustInterval: CFAbsoluteTime = 2.0 // Adjust every 2 seconds max

    /// Call when a frame was successfully delivered to the client
    func reportFrameDelivered() {
        consecutiveDrops = 0
        consecutiveSuccess += 1

        // Ramp up bitrate if consistently delivering
        let now = CFAbsoluteTimeGetCurrent()
        if consecutiveSuccess >= 10 && now - lastAdjustTime >= adjustInterval {
            if currentBitrate < maxBitrate {
                let newBitrate = min(currentBitrate * 5 / 4, maxBitrate) // +25%
                updateBitrate(newBitrate)
                lastAdjustTime = now
                consecutiveSuccess = 0
            }
        }
    }

    /// Call when a frame was dropped (backpressure, network slow)
    func reportFrameDropped() {
        consecutiveSuccess = 0
        consecutiveDrops += 1

        let now = CFAbsoluteTimeGetCurrent()
        if consecutiveDrops >= 2 && now - lastAdjustTime >= adjustInterval {
            if currentBitrate > minBitrate {
                let newBitrate = max(currentBitrate * 3 / 4, minBitrate) // -25%
                updateBitrate(newBitrate)
                lastAdjustTime = now
                consecutiveDrops = 0
            }
        }
    }

    private func updateBitrate(_ newBitrate: Int) {
        guard let session, newBitrate != currentBitrate else { return }
        currentBitrate = newBitrate

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                           value: newBitrate as CFNumber)
        let dataRateLimit: [Int] = [newBitrate * 2, 1]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                           value: dataRateLimit as CFArray)

        #if DEBUG
        print("[Encoder] Adaptive bitrate: \(newBitrate / 1000)kbps")
        #endif
    }

    func configure(width: Int, height: Int, fps: Int, bitrate: Int) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.currentFps = fps
        self.targetBitrate = bitrate
        self.currentBitrate = bitrate
        self.minBitrate = bitrate / 5
        self.maxBitrate = bitrate * 3

        // Tear down existing session
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }

        // H.264 — fastest hardware encoding, lowest latency
        var session: VTCompressionSession?
        let codecType = kCMVideoCodecType_H264
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: self.width,
            height: self.height,
            codecType: codecType,
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: self.width,
                kCVPixelBufferHeightKey: self.height,
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            #if DEBUG
            print("[Encoder] Failed to create compression session: \(status)")
            #endif
            return
        }

        self.session = session
        self.isHEVC = false

        // Real-time encoding for streaming
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Profile: Main for good compression
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                           value: kVTProfileLevel_H264_Main_AutoLevel)

        // Bitrate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                           value: bitrate as CFNumber)
        let dataRateLimit: [Int] = [bitrate * 2, 1]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                           value: dataRateLimit as CFArray)

        // Keyframe interval: every 3 seconds
        let keyframeInterval = fps * 3
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                           value: keyframeInterval as CFNumber)

        // Low latency — no frame reordering, no delay
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                           value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                           value: 0 as CFNumber)

        // Expected frame rate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                           value: fps as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
        frameCount = 0
        consecutiveDrops = 0
        consecutiveSuccess = 0

        #if DEBUG
        let codecName = isHEVC ? "HEVC" : "H.264"
        print("[Encoder] \(codecName) configured: \(width)x\(height) @ \(fps)fps, \(bitrate/1000)kbps")
        #endif
    }

    func encode(_ pixelBuffer: CVPixelBuffer) {
        guard let session else { return }

        let timestamp = CMTime(value: frameCount, timescale: 90000)
        let duration = CMTime.invalid
        frameCount += 90000 / Int64(currentFps)

        // Force keyframe on first frame
        var properties: CFDictionary? = nil
        if frameCount <= 1 {
            properties = [
                kVTEncodeFrameOptionKey_ForceKeyFrame: true
            ] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp,
            duration: duration,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, flags, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.processSampleBuffer(sampleBuffer)
        }
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = sampleBuffer.dataBuffer else { return }

        let isKeyframe: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            isKeyframe = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        } else {
            isKeyframe = true
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                     totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard let dataPointer, totalLength > 0 else { return }

        var outputData = Data()
        outputData.reserveCapacity(totalLength + 128)

        // First byte: frame type (0x01 = keyframe, 0x00 = delta)
        outputData.append(isKeyframe ? 0x01 : 0x00)

        // For keyframes, prepend parameter sets (SPS/PPS for H.264, VPS/SPS/PPS for HEVC)
        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            if isHEVC {
                appendHEVCParameterSets(formatDesc, to: &outputData)
            } else {
                appendH264ParameterSets(formatDesc, to: &outputData)
            }
        }

        // Append NAL units (convert AVCC/HVCC length-prefix to Annex B start codes)
        var offset = 0
        while offset < totalLength - 4 {
            let b0 = UInt32(dataPointer.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: 1) { $0.pointee })
            let b1 = UInt32(dataPointer.advanced(by: offset + 1).withMemoryRebound(to: UInt8.self, capacity: 1) { $0.pointee })
            let b2 = UInt32(dataPointer.advanced(by: offset + 2).withMemoryRebound(to: UInt8.self, capacity: 1) { $0.pointee })
            let b3 = UInt32(dataPointer.advanced(by: offset + 3).withMemoryRebound(to: UInt8.self, capacity: 1) { $0.pointee })
            let nalLength = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            offset += 4

            guard nalLength > 0, offset + nalLength <= totalLength else { break }

            outputData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            outputData.append(Data(bytes: dataPointer.advanced(by: offset), count: nalLength))
            offset += nalLength
        }

        onEncodedFrame?(outputData)
    }

    private func appendH264ParameterSets(_ formatDesc: CMFormatDescription, to data: inout Data) {
        // SPS
        var size = 0
        var count = 0
        var ptr: UnsafePointer<UInt8>?
        if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &ptr,
            parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        ) == noErr, let ptr {
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            data.append(UnsafeBufferPointer(start: ptr, count: size))
        }
        // PPS
        if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ptr,
            parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        ) == noErr, let ptr {
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            data.append(UnsafeBufferPointer(start: ptr, count: size))
        }
    }

    private func appendHEVCParameterSets(_ formatDesc: CMFormatDescription, to data: inout Data) {
        // HEVC has VPS (index 0), SPS (index 1), PPS (index 2)
        for i in 0..<3 {
            var size = 0
            var ptr: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDesc, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let ptr {
                data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                data.append(UnsafeBufferPointer(start: ptr, count: size))
            }
        }
    }

    func forceKeyframe() {
        frameCount = 0
    }

    func stop() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        frameCount = 0
    }

    deinit {
        stop()
    }
}
