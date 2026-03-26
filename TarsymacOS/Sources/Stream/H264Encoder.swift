import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware-accelerated H.264 encoder using VideoToolbox.
/// Encodes CVPixelBuffers from ScreenCaptureKit into H.264 NAL units
/// that can be sent over WebSocket and decoded on iOS.
class H264Encoder {
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var frameCount: Int64 = 0
    private let encodingQueue = DispatchQueue(label: "h264.encoding", qos: .userInteractive)

    /// Called with encoded H.264 data. The Data contains:
    /// - For keyframes: SPS + PPS + IDR NAL units (prefixed with 4-byte length)
    /// - For delta frames: slice NAL units (prefixed with 4-byte length)
    /// First byte is 0x01 for keyframe, 0x00 for delta frame.
    var onEncodedFrame: ((Data) -> Void)?

    private var formatDescription: CMFormatDescription?

    func configure(width: Int, height: Int, fps: Int, bitrate: Int) {
        self.width = Int32(width)
        self.height = Int32(height)

        // Tear down existing session
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: self.width,
            height: self.height,
            codecType: kCMVideoCodecType_H264,
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
            print("[H264] Failed to create compression session: \(status)")
            return
        }

        self.session = session

        // Real-time encoding for streaming
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Profile: Main for good compression with reasonable compatibility
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                           value: kVTProfileLevel_H264_Main_AutoLevel)

        // Bitrate — target for screen content
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                           value: bitrate as CFNumber)

        // Data rate limit: allow bursts up to 1.5x average over 1 second
        let dataRateLimit: [Int] = [bitrate * 3 / 2, 1]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                           value: dataRateLimit as CFArray)

        // Keyframe interval: every 2 seconds
        let keyframeInterval = fps * 2
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                           value: keyframeInterval as CFNumber)

        // Low latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                           value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                           value: 0 as CFNumber)

        // Expected frame rate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                           value: fps as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
        frameCount = 0
        print("[H264] Encoder configured: \(width)x\(height) @ \(fps)fps, \(bitrate/1000)kbps")
    }

    func encode(_ pixelBuffer: CVPixelBuffer) {
        guard let session else { return }

        let timestamp = CMTime(value: frameCount, timescale: 90000)
        let duration = CMTime.invalid
        frameCount += 90000 / 12 // ~12fps increment

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
            guard status == noErr, let sampleBuffer else {
                if status != noErr {
                    print("[H264] Encode error: \(status)")
                }
                return
            }
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
        // Reserve space: 1 byte header + SPS/PPS (if keyframe) + NAL data
        outputData.reserveCapacity(totalLength + 128)

        // First byte: frame type (0x01 = keyframe, 0x00 = delta)
        outputData.append(isKeyframe ? 0x01 : 0x00)

        // For keyframes, prepend SPS and PPS
        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // SPS
            var spsSize = 0
            var spsCount = 0
            var spsPointer: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer,
                parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
            ) == noErr, let spsPointer {
                // Write 4-byte start code + SPS
                outputData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                outputData.append(UnsafeBufferPointer(start: spsPointer, count: spsSize))
            }

            // PPS
            var ppsSize = 0
            var ppsPointer: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let ppsPointer {
                outputData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                outputData.append(UnsafeBufferPointer(start: ppsPointer, count: ppsSize))
            }
        }

        // Append NAL units (convert AVCC length-prefix to Annex B start codes)
        var offset = 0
        while offset < totalLength - 4 {
            // Read 4-byte NAL unit length (big-endian) — byte-by-byte to avoid alignment crash
            let b0 = UInt32(dataPointer.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: 1) { $0.pointee })
            let b1 = UInt32(dataPointer.advanced(by: offset + 1).withMemoryRebound(to: UInt8.self, capacity: 1) { $0.pointee })
            let b2 = UInt32(dataPointer.advanced(by: offset + 2).withMemoryRebound(to: UInt8.self, capacity: 1) { $0.pointee })
            let b3 = UInt32(dataPointer.advanced(by: offset + 3).withMemoryRebound(to: UInt8.self, capacity: 1) { $0.pointee })
            let nalLength = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            offset += 4

            guard nalLength > 0, offset + nalLength <= totalLength else { break }

            // Write Annex B start code + NAL data
            outputData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            outputData.append(Data(bytes: dataPointer.advanced(by: offset), count: nalLength))
            offset += nalLength
        }

        onEncodedFrame?(outputData)
    }

    func forceKeyframe() {
        // Next encode call will be a keyframe
        frameCount = 0
    }

    func stop() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        frameCount = 0
        print("[H264] Encoder stopped")
    }

    deinit {
        stop()
    }
}
