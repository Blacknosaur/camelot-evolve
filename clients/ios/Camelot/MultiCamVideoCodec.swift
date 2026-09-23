import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - Encoder

/// Low-latency H.264 for the camera → host feed: no frame reordering, a keyframe every second,
/// parameter sets carried on every keyframe so the host can start decoding at any point.
final class MultiCamVideoEncoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private let queue = DispatchQueue(label: "com.camelot.multicam.encode", qos: .userInitiated)
    private let onPacket: @Sendable (MultiCamVideoPacket) -> Void
    private var size = CGSize.zero
    let bitRate: Int
    /// Last VideoToolbox status (session creation or encode); `noErr` while healthy.
    let lastStatus = LockedValue<OSStatus>(noErr)

    init(bitRate: Int = 3_500_000, onPacket: @escaping @Sendable (MultiCamVideoPacket) -> Void) {
        self.bitRate = bitRate
        self.onPacket = onPacket
    }

    /// `time` is on the session clock; the receiver uses it to order and align frames.
    func encode(_ pixelBuffer: CVPixelBuffer, hostTime: Double) {
        nonisolated(unsafe) let pixelBuffer = pixelBuffer
        queue.async { [self] in
            let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
            if session == nil || Int(size.width) != width || Int(size.height) != height {
                session = makeSession(width: width, height: height)
                size = CGSize(width: width, height: height)
            }
            guard let session else { return }
            let presentation = CMTime(seconds: hostTime, preferredTimescale: 90_000)
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: presentation, duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
                guard let self else { return }
                if status != noErr { self.lastStatus.value = status; return }
                guard let sampleBuffer, let packet = Self.packet(from: sampleBuffer) else { return }
                self.onPacket(packet)
            }
            if status != noErr { lastStatus.value = status }
        }
    }

    /// Forces out everything the encoder is still holding.
    func flush() {
        queue.async { [self] in if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) } }
    }

    func invalidate() {
        queue.async { [self] in
            if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(session) }
            session = nil
        }
    }

    private func makeSession(width: Int, height: Int) -> VTCompressionSession? {
        if let session { VTCompressionSessionInvalidate(session) }
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { lastStatus.value = status; return nil }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [bitRate * 5 / 4 / 8, 1] as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    static func packet(from sampleBuffer: CMSampleBuffer) -> MultiCamVideoPacket? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer), let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var sets: [Data] = []
        if isKeyframe {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var length = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &length, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointer { sets.append(Data(bytes: pointer, count: length)) }
            }
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { return nil }
        return MultiCamVideoPacket(presentationHostTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds, isKeyframe: isKeyframe,
            parameterSets: sets, payload: Data(bytes: pointer, count: length))
    }
}

// MARK: - Decoder

/// Turns packets from one camera back into pixel buffers. Frames before the first keyframe are
/// dropped; a new SPS/PPS pair rebuilds the session.
final class MultiCamVideoDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private let queue = DispatchQueue(label: "com.camelot.multicam.decode", qos: .userInitiated)
    private let onFrame: @Sendable (CVPixelBuffer, Double) -> Void

    init(onFrame: @escaping @Sendable (CVPixelBuffer, Double) -> Void) { self.onFrame = onFrame }

    func decode(_ packet: MultiCamVideoPacket) {
        queue.async { [self] in
            if packet.isKeyframe, packet.parameterSets.count >= 2, packet.parameterSets != parameterSets {
                rebuild(with: packet.parameterSets)
            }
            guard let session, let format else { return }
            var block: CMBlockBuffer?
            let payload = packet.payload
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
            payload.withUnsafeBytes { bytes in
                _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
            }
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: packet.presentationHostTime, preferredTimescale: 90_000), decodeTimeStamp: .invalid)
            var size = payload.count
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
            let time = packet.presentationHostTime
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._1xRealTimePlayback], infoFlagsOut: nil) { [weak self] status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer, let self else { return }
                self.onFrame(imageBuffer, time)
            }
        }
    }

    func invalidate() {
        queue.async { [self] in
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil; format = nil; parameterSets = []
        }
    }

    private func rebuild(with sets: [Data]) {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil
        var description: CMVideoFormatDescription?
        let status = sets.withUnsafeBufferPointerCopies { copies in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: copies.count, parameterSetPointers: copies.map { UnsafePointer($0.baseAddress!) },
                parameterSetSizes: copies.map(\.count), nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { return }
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey: true]
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session) == noErr else { return }
        self.session = session; format = description; parameterSets = sets
    }
}

private extension Array where Element == Data {
    /// Copies each Data into stable memory for the duration of `body`.
    func withUnsafeBufferPointerCopies<T>(_ body: ([UnsafeMutableBufferPointer<UInt8>]) -> T) -> T {
        let copies = map { data -> UnsafeMutableBufferPointer<UInt8> in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: data.count)
            _ = buffer.initialize(from: data)
            return buffer
        }
        defer { copies.forEach { $0.deallocate() } }
        return body(copies)
    }
}

// MARK: - Scaler

/// Aspect-fit render of a frame into a fixed-size BGRA buffer (stream downscale, program frames).
final class MultiCamFrameScaler: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: false])
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    let size: CGSize

    init(size: CGSize) { self.size = size }

    func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool = pool(for: size) else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return nil }
        let image = CIImage(cvPixelBuffer: source)
        let scale = min(size.width / image.extent.width, size.height / image.extent.height)
        let fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offset = CGPoint(x: (size.width - fitted.extent.width) / 2 - fitted.extent.minX, y: (size.height - fitted.extent.height) / 2 - fitted.extent.minY)
        let placed = fitted.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
        let canvas = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        context.render(placed.composited(over: canvas), to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    /// The stream keeps the camera's orientation: 1280×720 landscape or 720×1280 portrait.
    static func streamSize(for source: CVPixelBuffer, longSide: CGFloat = 1280) -> CGSize {
        let width = CGFloat(CVPixelBufferGetWidth(source)), height = CGFloat(CVPixelBufferGetHeight(source))
        return width >= height ? CGSize(width: longSide, height: (longSide * height / width / 2).rounded() * 2)
            : CGSize(width: (longSide * width / height / 2).rounded() * 2, height: longSide)
    }

    private func pool(for size: CGSize) -> CVPixelBufferPool? {
        if let pool, poolSize == size { return pool }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(size.width), kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attributes as CFDictionary, &pool)
        self.pool = pool; poolSize = size
        return pool
    }
}
