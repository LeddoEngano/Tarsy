import Foundation
import AVFoundation
import VideoToolbox
import UIKit
import CoreMedia

/// Hardware-accelerated H.264 decoder using AVSampleBufferDisplayLayer.
/// Receives Annex B NAL units from the relay and displays them with minimal latency.
class H264Decoder: ObservableObject {
    @Published var displayLayer: AVSampleBufferDisplayLayer?
    @Published var fps: Int = 0

    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var frameCount = 0
    private var fpsTimer: Timer?
    private let startCode = Data([0x00, 0x00, 0x00, 0x01])
    private let processingQueue = DispatchQueue(label: "h264.decoding", qos: .userInteractive)

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
        sps = nil
        pps = nil
        fps = 0
        frameCount = 0
    }

    /// Receive encoded H.264 data from relay.
    /// Format: [1 byte type] [Annex B NAL units with 0x00000001 start codes]
    func receiveFrame(_ data: Data) {
        processingQueue.async { [weak self] in
            self?.decodeFrame(data)
        }
    }

    private var totalFramesReceived = 0
    private var totalFramesDecoded = 0

    private func decodeFrame(_ data: Data) {
        guard data.count > 1 else { return }
        totalFramesReceived += 1

        let isKeyframe = data[0] == 0x01
        let nalData = data.dropFirst()

        // Parse NAL units from Annex B format
        let nalUnits = parseNALUnits(nalData)

        if totalFramesReceived <= 3 || totalFramesReceived % 60 == 0 {
            print("[H264Dec] Frame #\(totalFramesReceived) size=\(data.count) keyframe=\(isKeyframe) nalUnits=\(nalUnits.count) types=\(nalUnits.map { $0.isEmpty ? 0 : Int($0[0] & 0x1F) }) hasSPS=\(sps != nil) hasPPS=\(pps != nil) hasFmt=\(formatDescription != nil) decoded=\(totalFramesDecoded)")
        }

        for nal in nalUnits {
            guard !nal.isEmpty else { continue }
            let nalType = nal[0] & 0x1F

            switch nalType {
            case 7: // SPS
                if sps != nal {
                    sps = nal
                    formatDescription = nil
                    print("[H264Dec] Got SPS (\(nal.count) bytes)")
                }
            case 8: // PPS
                if pps != nal {
                    pps = nal
                    formatDescription = nil
                    print("[H264Dec] Got PPS (\(nal.count) bytes)")
                }
            case 5: // IDR (keyframe)
                ensureFormatDescription()
                if let sampleBuffer = createSampleBuffer(from: nal, isKeyframe: true) {
                    enqueue(sampleBuffer)
                    totalFramesDecoded += 1
                } else {
                    print("[H264Dec] Failed to create IDR sample buffer (fmt=\(formatDescription != nil))")
                }
            case 1: // Non-IDR (delta frame)
                if formatDescription != nil {
                    if let sampleBuffer = createSampleBuffer(from: nal, isKeyframe: false) {
                        enqueue(sampleBuffer)
                        totalFramesDecoded += 1
                    }
                }
            default:
                break
            }
        }
    }

    private func parseNALUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        var searchStart = data.startIndex

        // Find all start codes and extract NAL units between them
        while searchStart < data.endIndex {
            guard let startRange = data.range(of: startCode, in: searchStart..<data.endIndex) else {
                break
            }

            let nalStart = startRange.upperBound

            // Find next start code or end of data
            let nextStart: Data.Index
            if let nextRange = data.range(of: startCode, in: nalStart..<data.endIndex) {
                nextStart = nextRange.lowerBound
            } else {
                nextStart = data.endIndex
            }

            if nalStart < nextStart {
                units.append(Data(data[nalStart..<nextStart]))
            }
            searchStart = nalStart
            if searchStart == nextStart { break } // prevent infinite loop
            searchStart = nextStart
        }

        return units
    }

    private func ensureFormatDescription() {
        guard formatDescription == nil, let sps, let pps else { return }

        // Must nest withUnsafeBytes to keep pointers alive
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
            print("[H264Dec] Format description created successfully")
        } else {
            print("[H264Dec] Failed to create format description: \(status)")
        }
    }

    private func createSampleBuffer(from nalUnit: Data, isKeyframe: Bool) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }

        // Convert to AVCC format: 4-byte length prefix instead of start code
        let nalLength = UInt32(nalUnit.count).bigEndian
        var avccData = Data()
        avccData.reserveCapacity(4 + nalUnit.count)
        withUnsafeBytes(of: nalLength) { avccData.append(contentsOf: $0) }
        avccData.append(nalUnit)

        // Create CMBlockBuffer
        var blockBuffer: CMBlockBuffer?
        let dataLength = avccData.count

        var status = avccData.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCreateWithMemoryBlock(
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
        }

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

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataLength
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 12),
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

        // Mark as display-immediately
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

        // Check if layer needs flush (error state)
        if layer.status == .failed {
            layer.flush()
            formatDescription = nil
            sps = nil
            pps = nil
            return
        }

        layer.enqueue(sampleBuffer)
        DispatchQueue.main.async { [weak self] in
            self?.frameCount += 1
        }
    }

    deinit {
        stop()
    }
}
