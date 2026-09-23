@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import simd
import Vision

// MARK: - Layout

/// Where each camera lands on the wide canvas. Pure geometry so it can be tested without video:
/// the homography maps second-camera pixels into the main camera's pixel space (origin bottom-left,
/// as Vision and Core Image use).
struct MultiCamStitchLayout: Equatable {
    static let maximumWidth: CGFloat = 4096
    static let maximumHeight: CGFloat = 2304

    /// Output size, even dimensions.
    let canvasSize: CGSize
    /// Applied to both sources so the union fits the size caps.
    let scale: CGFloat
    /// The main camera's frame on the canvas.
    let primaryFrame: CGRect
    /// Second camera corners on the canvas: bottom-left, bottom-right, top-right, top-left.
    let cameraCorners: [CGPoint]
    /// Blend band across the main frame's edge that faces the second camera; nil when side by side.
    let feather: CGRect?
    /// Whether the second camera sits to the right of the main one.
    let cameraOnRight: Bool

    /// Registration result, or side by side (second camera next to the main one) when there is none.
    static func compute(primarySize: CGSize, cameraSize: CGSize, homography: simd_float3x3?) -> MultiCamStitchLayout {
        let primary = CGRect(origin: .zero, size: primarySize)
        var corners = [CGPoint(x: 0, y: 0), CGPoint(x: cameraSize.width, y: 0), CGPoint(x: cameraSize.width, y: cameraSize.height), CGPoint(x: 0, y: cameraSize.height)]
        var registered = false
        if let homography, let warped = Self.warp(corners, by: homography), Self.isPlausible(warped, cameraSize: cameraSize, primarySize: primarySize) {
            corners = warped; registered = true
        } else {
            // Side by side: match heights, put the second camera on the right.
            let height = primarySize.height, width = cameraSize.width * height / cameraSize.height
            corners = [CGPoint(x: primarySize.width, y: 0), CGPoint(x: primarySize.width + width, y: 0),
                       CGPoint(x: primarySize.width + width, y: height), CGPoint(x: primarySize.width, y: height)]
        }
        let union = corners.reduce(primary) { $0.union(CGRect(origin: $1, size: .zero)) }
        let scale = min(1, maximumWidth / union.width, maximumHeight / union.height)
        let offset = CGPoint(x: -union.minX, y: -union.minY)
        func place(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x + offset.x) * scale, y: (point.y + offset.y) * scale) }
        let placedCorners = corners.map(place)
        let primaryFrame = CGRect(origin: place(.zero), size: CGSize(width: primarySize.width * scale, height: primarySize.height * scale))
        let canvas = CGSize(width: (union.width * scale / 2).rounded(.down) * 2, height: (union.height * scale / 2).rounded(.down) * 2)
        let cameraCenterX = placedCorners.map(\.x).reduce(0, +) / 4
        let onRight = cameraCenterX >= primaryFrame.midX
        var feather: CGRect?
        if registered {
            let cameraMinX = placedCorners.map(\.x).min() ?? 0, cameraMaxX = placedCorners.map(\.x).max() ?? 0
            let overlap = onRight ? (primaryFrame.maxX - cameraMinX) : (cameraMaxX - primaryFrame.minX)
            let band = max(24, min(overlap * 0.6, primaryFrame.width * 0.2))
            feather = onRight
                ? CGRect(x: primaryFrame.maxX - band, y: primaryFrame.minY, width: band, height: primaryFrame.height)
                : CGRect(x: primaryFrame.minX, y: primaryFrame.minY, width: band, height: primaryFrame.height)
        }
        return MultiCamStitchLayout(canvasSize: canvas, scale: scale, primaryFrame: primaryFrame, cameraCorners: placedCorners, feather: feather, cameraOnRight: onRight)
    }

    var isRegistered: Bool { feather != nil }

    static func warp(_ points: [CGPoint], by matrix: simd_float3x3) -> [CGPoint]? {
        var result: [CGPoint] = []
        for point in points {
            let vector = matrix * simd_float3(Float(point.x), Float(point.y), 1)
            guard abs(vector.z) > 1e-6, vector.x.isFinite, vector.y.isFinite else { return nil }
            result.append(CGPoint(x: CGFloat(vector.x / vector.z), y: CGFloat(vector.y / vector.z)))
        }
        return result
    }

    /// A believable registration keeps the second camera roughly the same size, convex, and
    /// overlapping or adjacent to the main frame rather than flying off or collapsing.
    static func isPlausible(_ quad: [CGPoint], cameraSize: CGSize, primarySize: CGSize) -> Bool {
        guard quad.count == 4 else { return false }
        var area: CGFloat = 0
        for index in 0..<4 {
            let a = quad[index], b = quad[(index + 1) % 4]
            area += a.x * b.y - b.x * a.y
        }
        area /= 2
        let expected = cameraSize.width * cameraSize.height
        guard area > expected * 0.35, area < expected * 3 else { return false }
        // Convex with a consistent winding: every cross product has the sign of the area.
        for index in 0..<4 {
            let a = quad[index], b = quad[(index + 1) % 4], c = quad[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if cross * area < 0 { return false }
        }
        let bounds = quad.reduce(CGRect(origin: quad[0], size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        let primary = CGRect(origin: .zero, size: primarySize)
        let gap = max(bounds.minX - primary.maxX, primary.minX - bounds.maxX)
        return gap < primarySize.width * 0.1 && abs(bounds.midY - primary.midY) < primarySize.height * 0.75
    }
}

// MARK: - Stitcher

/// Builds the wide view: registers the second camera against the main one on a few shared
/// frames, then renders every main frame with the warped second frame behind it.
final class MultiCamStitcher: @unchecked Sendable {
    struct Result: Sendable { let url: URL; let duration: Double; let registered: Bool }
    enum Failure: LocalizedError {
        case noVideoTrack, noOverlap, cancelled, writer(String)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "One of the videos has no video track."
            case .noOverlap: "The two videos do not overlap in time."
            case .cancelled: "Stitching was cancelled."
            case let .writer(message): message
            }
        }
    }

    let primaryURL: URL
    let cameraURL: URL
    /// Seconds the second camera started after the main one.
    let cameraOffset: Double
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(primaryURL: URL, cameraURL: URL, cameraOffset: Double) {
        self.primaryURL = primaryURL; self.cameraURL = cameraURL; self.cameraOffset = cameraOffset
    }

    /// `progress` is 0…1 on the render; the registration pass reports 0.
    func run(to outputURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let primary = AVURLAsset(url: primaryURL), camera = AVURLAsset(url: cameraURL)
        guard let primaryTrack = try await primary.loadTracks(withMediaType: .video).first,
              let cameraTrack = try await camera.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack }
        let primaryDuration = try await primary.load(.duration).seconds, cameraDuration = try await camera.load(.duration).seconds
        let timedShared = MultiCamAlignment.sharedRange(hostDuration: primaryDuration, cameraDuration: cameraDuration, cameraOffset: cameraOffset)
        // A bad/missing clock offset must not make the user's footage unusable. If the reported
        // timelines do not overlap, align both clips at their starts and still produce a
        // side-by-side best-effort result when visual registration cannot find a match.
        let renderOffset = timedShared == nil ? 0 : cameraOffset
        let shared = timedShared ?? 0...min(primaryDuration, cameraDuration)
        let primarySize = try await Self.displaySize(of: primaryTrack), cameraSize = try await Self.displaySize(of: cameraTrack)
        let frameRate = try await primaryTrack.load(.nominalFrameRate)

        let homography = try await register(primary: primary, camera: camera, shared: shared, cameraOffset: renderOffset, primarySize: primarySize, cameraSize: cameraSize)
        try Task.checkCancellation()
        let layout = MultiCamStitchLayout.compute(primarySize: primarySize, cameraSize: cameraSize, homography: homography)

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: layout.canvasSize.width > 1920 ? AVVideoCodecType.hevc : .h264,
            AVVideoWidthKey: Int(layout.canvasSize.width), AVVideoHeightKey: Int(layout.canvasSize.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(layout.canvasSize.width * layout.canvasSize.height * 6)],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(layout.canvasSize.width), kCVPixelBufferHeightKey as String: Int(layout.canvasSize.height),
        ])
        guard writer.canAdd(videoInput) else { throw Failure.writer("Could not create the output video.") }
        writer.add(videoInput)
        let audioTrack = try await primary.loadTracks(withMediaType: .audio).first
        var audioInput: AVAssetWriterInput?
        if audioTrack != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }

        let primaryReader = try AVAssetReader(asset: primary), cameraReader = try AVAssetReader(asset: camera)
        let pixelSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let primaryOutput = AVAssetReaderTrackOutput(track: primaryTrack, outputSettings: pixelSettings)
        let cameraOutput = AVAssetReaderTrackOutput(track: cameraTrack, outputSettings: pixelSettings)
        primaryOutput.alwaysCopiesSampleData = false; cameraOutput.alwaysCopiesSampleData = false
        primaryReader.add(primaryOutput); cameraReader.add(cameraOutput)
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            primaryReader.add(output); audioOutput = output
        }
        guard primaryReader.startReading(), cameraReader.startReading(), writer.startWriting() else {
            throw Failure.writer(writer.error?.localizedDescription ?? primaryReader.error?.localizedDescription ?? "Could not read the videos.")
        }
        writer.startSession(atSourceTime: .zero)

        let cameraTransform = Self.cameraTransform(layout: layout, cameraSize: cameraSize)
        let featherMask = layout.feather.map { Self.featherMask(feather: $0, canvas: layout.canvasSize, cameraOnRight: layout.cameraOnRight) }
        var pendingCamera: CMSampleBuffer? = cameraOutput.copyNextSampleBuffer()
        var pendingAudio: CMSampleBuffer? = audioOutput?.copyNextSampleBuffer()
        var currentCamera: CIImage?
        var lastProgress = -1.0
        let frameStep = frameRate > 0 ? 1.0 / Double(frameRate) : 1.0 / 30
        while let sample = primaryOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let cameraTime = time.seconds - renderOffset
            // Advance the second camera to the latest frame at or before this main frame.
            while let candidate = pendingCamera, CMSampleBufferGetPresentationTimeStamp(candidate).seconds <= cameraTime + frameStep / 2 {
                if let buffer = CMSampleBufferGetImageBuffer(candidate) { currentCamera = CIImage(cvPixelBuffer: buffer) }
                pendingCamera = cameraOutput.copyNextSampleBuffer()
            }
            if cameraTime < -frameStep || cameraTime > cameraDuration + frameStep { currentCamera = nil }
            let frame = compose(primary: CIImage(cvPixelBuffer: pixelBuffer), camera: currentCamera, layout: layout, cameraTransform: cameraTransform, featherMask: featherMask)
            try await waitUntilReady(videoInput, writer: writer)
            guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("The output buffer pool is unavailable.") }
            var output: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
            guard let output else { continue }
            context.render(frame, to: output, bounds: CGRect(origin: .zero, size: layout.canvasSize), colorSpace: CGColorSpaceCreateDeviceRGB())
            guard adaptor.append(output, withPresentationTime: time) else {
                throw Failure.writer(writer.error?.localizedDescription ?? "Could not write the stitched video frame.")
            }
            // Keep audio and video interleaved. Deferring all audio until the video pass is
            // complete can fill AVAssetWriter's video queue and leave it permanently not-ready.
            if let audioInput {
                while let sample = pendingAudio,
                      CMSampleBufferGetPresentationTimeStamp(sample) <= time {
                    try await waitUntilReady(audioInput, writer: writer)
                    guard audioInput.append(sample) else {
                        throw Failure.writer(writer.error?.localizedDescription ?? "Could not write the stitched audio.")
                    }
                    pendingAudio = audioOutput?.copyNextSampleBuffer()
                }
            }
            let fraction = min(1, time.seconds / max(primaryDuration, 0.001))
            if fraction - lastProgress >= 0.005 { lastProgress = fraction; progress(fraction) }
        }
        videoInput.markAsFinished()
        if let audioInput, let audioOutput {
            while let sample = pendingAudio {
                try await waitUntilReady(audioInput, writer: writer)
                guard audioInput.append(sample) else {
                    throw Failure.writer(writer.error?.localizedDescription ?? "Could not write the stitched audio.")
                }
                pendingAudio = audioOutput.copyNextSampleBuffer()
            }
            audioInput.markAsFinished()
        }
        cameraReader.cancelReading()
        await writer.finishWriting()
        if let error = writer.error { throw Failure.writer(error.localizedDescription) }
        return Result(url: outputURL, duration: primaryDuration, registered: layout.isRegistered)
    }

    private func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw Failure.writer(writer.error?.localizedDescription ?? "The video writer stopped unexpectedly.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Registration

    /// Registers frames spread across the shared range and keeps the first plausible result;
    /// returns nil when the views do not overlap enough.
    private func register(primary: AVAsset, camera: AVAsset, shared: ClosedRange<Double>, cameraOffset: Double, primarySize: CGSize, cameraSize: CGSize) async throws -> simd_float3x3? {
        let primaryGenerator = AVAssetImageGenerator(asset: primary), cameraGenerator = AVAssetImageGenerator(asset: camera)
        for generator in [primaryGenerator, cameraGenerator] {
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 1920, height: 1920)
        }
        let span = shared.upperBound - shared.lowerBound
        let samples = (0..<5).map { shared.lowerBound + span * (Double($0) + 0.5) / 5 }
        var candidates: [simd_float3x3] = []
        for time in samples {
            try Task.checkCancellation()
            guard let reference = try? await primaryGenerator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image,
                  let floating = try? await cameraGenerator.image(at: CMTime(seconds: time - cameraOffset, preferredTimescale: 600)).image else { continue }
            guard let matrix = MultiCamRegistration.homography(reference: reference, floating: floating) else { continue }
            candidates.append(Self.rescale(matrix, floatingScale: cameraSize.width / CGFloat(floating.width), referenceScale: primarySize.width / CGFloat(reference.width)))
        }
        let corners = [CGPoint.zero, CGPoint(x: cameraSize.width, y: 0), CGPoint(x: cameraSize.width, y: cameraSize.height), CGPoint(x: 0, y: cameraSize.height)]
        return candidates.first { matrix in
            guard let quad = MultiCamStitchLayout.warp(corners, by: matrix) else { return false }
            return MultiCamStitchLayout.isPlausible(quad, cameraSize: cameraSize, primarySize: primarySize)
        }
    }

    /// Vision saw downscaled frames; the same homography between full-size frames scales its input
    /// space down by the floating factor and its output space up by the reference factor.
    static func rescale(_ matrix: simd_float3x3, floatingScale: CGFloat, referenceScale: CGFloat) -> simd_float3x3 {
        let toSmall = simd_float3x3(diagonal: simd_float3(1 / Float(floatingScale), 1 / Float(floatingScale), 1))
        let toFull = simd_float3x3(diagonal: simd_float3(Float(referenceScale), Float(referenceScale), 1))
        return toFull * matrix * toSmall
    }

    private static func displaySize(of track: AVAssetTrack) async throws -> CGSize {
        let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    // MARK: Compose

    private static func cameraTransform(layout: MultiCamStitchLayout, cameraSize: CGSize) -> CIFilter & CIPerspectiveTransform {
        let filter = CIFilter.perspectiveTransform()
        filter.bottomLeft = layout.cameraCorners[0]; filter.bottomRight = layout.cameraCorners[1]
        filter.topRight = layout.cameraCorners[2]; filter.topLeft = layout.cameraCorners[3]
        return filter
    }

    /// White over the main frame except a ramp to transparent across the band facing the second camera.
    private static func featherMask(feather: CGRect, canvas: CGSize, cameraOnRight: Bool) -> CIImage {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: cameraOnRight ? feather.minX : feather.maxX, y: 0)
        gradient.point1 = CGPoint(x: cameraOnRight ? feather.maxX : feather.minX, y: 0)
        gradient.color0 = .white; gradient.color1 = CIColor(red: 0, green: 0, blue: 0)
        return gradient.outputImage!.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    private func compose(primary: CIImage, camera: CIImage?, layout: MultiCamStitchLayout, cameraTransform: CIFilter & CIPerspectiveTransform, featherMask: CIImage?) -> CIImage {
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)
        var result = CIImage(color: .black).cropped(to: canvas)
        if let camera {
            cameraTransform.inputImage = camera
            if let warped = cameraTransform.outputImage { result = warped.cropped(to: canvas).composited(over: result) }
        }
        var placed = primary.transformed(by: CGAffineTransform(scaleX: layout.scale, y: layout.scale))
            .transformed(by: CGAffineTransform(translationX: layout.primaryFrame.minX, y: layout.primaryFrame.minY))
        if let featherMask, camera != nil {
            let blend = CIFilter.blendWithMask()
            blend.inputImage = placed; blend.backgroundImage = result; blend.maskImage = featherMask
            if let output = blend.outputImage { return output.cropped(to: canvas) }
        }
        placed = placed.cropped(to: canvas)
        return placed.composited(over: result)
    }
}
