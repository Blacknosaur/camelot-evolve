@preconcurrency import AVFoundation
import CoreImage
import Vision
import simd

/// Projective image motion in normalized, top-left display coordinates. This is
/// camera compensation, not metric pitch calibration or a 3-D camera pose.
struct CameraTransform: Codable, Equatable, Sendable {
    var values: [Double]
    static let identity = Self(values: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    init(values: [Double]) { self.values = values }
    init(_ matrix: simd_float3x3) {
        values = (0..<9).map { Double(matrix[$0 % 3][$0 / 3]) }
    }
    var matrix: simd_float3x3 {
        guard values.count == 9 else { return matrix_identity_float3x3 }
        return simd_float3x3(columns: (SIMD3(Float(values[0]), Float(values[3]), Float(values[6])),
                                      SIMD3(Float(values[1]), Float(values[4]), Float(values[7])),
                                      SIMD3(Float(values[2]), Float(values[5]), Float(values[8]))))
    }
    func point(_ point: CGPoint) -> CGPoint? {
        guard values.count == 9 else { return nil }
        let value = matrix * SIMD3(Float(point.x), Float(point.y), 1)
        guard value.z.isFinite, abs(value.z) > 0.0001 else { return nil }
        let x = CGFloat(value.x / value.z), y = CGFloat(value.y / value.z)
        return x.isFinite && y.isFinite ? CGPoint(x: x, y: y) : nil
    }

    /// Homographies are defined only up to scale. Canonicalize before blending
    /// so two equivalent matrices cannot cancel or bend the pitch in between.
    var normalized: Self? {
        guard values.count == 9, values.allSatisfy(\.isFinite), abs(values[8]) > 1e-9 else { return nil }
        let result = Self(values: values.map { $0 / values[8] })
        guard abs(result.matrix.determinant) > 1e-7 else { return nil }
        return result
    }
}

struct AnnotationCameraMotion: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        var time: Double
        var transform: CameraTransform
    }
    var samples: [Sample]
    var lostAt: Double?
    var trackID: UUID? = nil
    var referenceTime: Double? = nil

    var coveredDuration: Double {
        max(0, min(samples.last?.time ?? 0, lostAt ?? .infinity) - (samples.first?.time ?? 0))
    }

    func covers(_ range: ClosedRange<Double>) -> Bool {
        transform(at: range.lowerBound) != nil && transform(at: range.upperBound) != nil
    }

    func transform(at time: Double) -> CameraTransform? {
        guard let current = rawTransform(at: time) else { return nil }
        guard let referenceTime else { return current }
        guard let reference = rawTransform(at: referenceTime), abs(reference.matrix.determinant) > 0.00001 else { return nil }
        return CameraTransform(current.matrix * reference.matrix.inverse)
    }

    private func rawTransform(at time: Double) -> CameraTransform? {
        guard time.isFinite, let first = samples.first, let last = samples.last, time >= first.time - 0.05,
              time <= last.time + 0.15, lostAt.map({ time < $0 }) ?? true else { return nil }
        var low = 0, high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < time { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return first.transform.normalized }
        let a = samples[low - 1], b = samples[low]
        guard let lhs = a.transform.normalized, let rhs = b.transform.normalized else { return nil }
        let fraction = min(1, max(0, (time - a.time) / max(0.001, b.time - a.time)))
        return CameraTransform(values: zip(lhs.values, rhs.values).map { $0 + ($1 - $0) * fraction }).normalized
    }
    func points(_ points: [CGPoint], at time: Double) -> [CGPoint]? {
        guard let transform = transform(at: time) else { return nil }
        let mapped = points.compactMap { transform.point($0) }
        return mapped.count == points.count ? mapped : nil
    }
}

enum CameraMotionTracking {
    /// The editing camera pass uses independently verified sparse scene matches.
    /// Keep the lightweight recovery warp below separate from player tracking.
    static func registerScene(previous: CGImage, current: CGImage) throws -> CameraTransform? {
        guard let previous = CameraFeatureRegistration.Frame(previous), let current = CameraFeatureRegistration.Frame(current) else { return nil }
        return try registerScene(previous: previous, current: current)
    }

    static func registerScene(previous: CameraFeatureRegistration.Frame, current: CameraFeatureRegistration.Frame) throws -> CameraTransform? {
        guard previous.image.width == current.image.width, previous.image.height == current.image.height else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previous.image)
        try VNImageRequestHandler(cgImage: current.image).perform([request])
        let initial: CameraTransform
        if let translation = request.results?.first?.alignmentTransform,
           translation.tx.isFinite, translation.ty.isFinite {
            initial = .init(values: [1, 0, Double(translation.tx) / Double(current.image.width),
                                    0, 1, -Double(translation.ty) / Double(current.image.height), 0, 0, 1])
        } else { return nil }
        if let refined = CameraFeatureRegistration.register(previous: previous, current: current, initial: initial) { return refined }
        // Translation is only a search initializer. If roll/zoom exceeds that
        // search window, try Vision's projective proposal, verified by the same
        // independent correspondences rather than accepting its matrix alone.
        let projective = VNHomographicImageRegistrationRequest(targetedCGImage: previous.image)
        try VNImageRequestHandler(cgImage: current.image).perform([projective])
        guard let observation = projective.results?.first else { return nil }
        let w = Float(current.image.width), h = Float(current.image.height)
        let pixels = simd_float3x3(columns: (SIMD3(w, 0, 0), SIMD3(0, -h, 0), SIMD3(0, h, 1)))
        var matrix = pixels.inverse * observation.warpTransform * pixels
        guard abs(matrix[2][2]) > 0.00001 else { return nil }
        matrix *= 1 / matrix[2][2]
        let proposal = CameraTransform(matrix)
        guard CameraFeatureRegistration.plausible(proposal) else { return nil }
        return CameraFeatureRegistration.register(previous: previous, current: current, initial: proposal)
    }
    /// Prefer the upper scene (stands, fences, field edge) over moving foreground
    /// players. Conjugate the crop warp back into full-frame coordinates.
    static func registerBackground(previous: CGImage, current: CGImage) throws -> CameraTransform? {
        let fraction: CGFloat = 0.62
        let region = CGRect(x: 0, y: 0, width: previous.width, height: Int(CGFloat(previous.height) * fraction))
        guard previous.width == current.width, previous.height == current.height,
              let a = previous.cropping(to: region), let b = current.cropping(to: region) else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: a)
        try VNImageRequestHandler(cgImage: b).perform([request])
        guard let translation = request.results?.first?.alignmentTransform else { return nil }
        let translated = CameraTransform(values: [1, 0, translation.tx / CGFloat(a.width), 0, 1, -translation.ty / CGFloat(a.height), 0, 0, 1].map(Double.init))
        guard translated.values.allSatisfy(\.isFinite), abs(translation.tx) < CGFloat(a.width) * 0.6,
              abs(translation.ty) < CGFloat(a.height) * 0.6,
              imagesAgree(previous: a, current: b, transform: translated) else { return nil }
        var cropped = translated
        if let projective = try? register(previous: a, current: b, maximumDisplacement: 0.6),
           let center = projective.point(.init(x: 0.5, y: 0.5)), let shifted = translated.point(.init(x: 0.5, y: 0.5)),
           hypot(center.x - shifted.x, center.y - shifted.y) < 0.003 {
            cropped = projective
        }
        let scale = CameraTransform(values: [1, 0, 0, 0, Double(region.height) / Double(previous.height), 0, 0, 0, 1]).matrix
        return CameraTransform(scale * cropped.matrix * scale.inverse)
    }

    static func register(previous: CVPixelBuffer, current: CVPixelBuffer, orientation: CGImagePropertyOrientation, context: CIContext) throws -> CameraTransform? {
        guard let previous = sceneImage(previous, orientation: orientation, context: context),
              let current = sceneImage(current, orientation: orientation, context: context) else { return nil }
        return try registerBackground(previous: previous, current: current)
    }

    /// One owned 640-long-side frame. The caller keeps it; the decoder buffer
    /// is not copied and must not be used after the next sample.
    static func sceneFrame(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, context: CIContext) -> CameraFeatureRegistration.Frame? {
        guard let image = sceneImage(buffer, orientation: orientation, context: context) else { return nil }
        return CameraFeatureRegistration.Frame(image)
    }

    private static func sceneImage(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, context: CIContext) -> CGImage? {
        let source = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let scale = min(1, 640 / max(source.extent.width, source.extent.height))
        let reduced = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(reduced, from: reduced.extent)
    }
    /// Registration maps the targeted (previous) image onto the handler's
    /// reference (current) image. Vision matrices use bottom-left pixel units.
    static func register(previous: CGImage, current: CGImage, maximumDisplacement: CGFloat = 0.18) throws -> CameraTransform? {
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: previous)
        try VNImageRequestHandler(cgImage: current).perform([request])
        guard let observation = request.results?.first else { return nil }
        let width = Float(current.width), height = Float(current.height)
        let pixels = simd_float3x3(columns: (SIMD3(width, 0, 0), SIMD3(0, -height, 0), SIMD3(0, height, 1)))
        var matrix = pixels.inverse * observation.warpTransform * pixels
        guard abs(matrix[2][2]) > 0.0001 else { return nil }
        matrix *= 1 / matrix[2][2]
        let transform = CameraTransform(matrix)
        let corners: [CGPoint] = [.zero, .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1), .init(x: 0.5, y: 0.5)]
        guard transform.values.allSatisfy(\.isFinite), matrix.determinant > 0.5, matrix.determinant < 2,
              corners.allSatisfy({ point in
                  guard let moved = transform.point(point) else { return false }
                  return hypot(moved.x - point.x, moved.y - point.y) < maximumDisplacement
              }) else { return nil }
        guard imagesAgree(previous: previous, current: current, transform: transform) else { return nil }
        return transform
    }

    /// Vision can return a plausible matrix even for unrelated shots. Verify
    /// textured image locations after the warp instead of trusting matrix shape.
    private static func imagesAgree(previous: CGImage, current: CGImage, transform: CameraTransform) -> Bool {
        let width = 160, height = 90
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return bytes
        }
        let a = pixels(previous), b = pixels(current)
        func color(_ pixels: [UInt8], _ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * width + x) * 4
            return SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255
        }
        var checked = 0, agreeing = 0
        for y in stride(from: 2, to: height - 2, by: 2) {
            for x in stride(from: 2, to: width - 2, by: 2) {
                let reference = color(a, x, y)
                let horizontal = abs(reference - color(a, x + 1, y)).sum() / 3
                let vertical = abs(reference - color(a, x, y + 1)).sum() / 3
                guard max(horizontal, vertical) > 0.055, reference.max() > 0.15,
                      let point = transform.point(CGPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height))) else { continue }
                let targetX = Int(point.x * Double(width)), targetY = Int(point.y * Double(height))
                guard targetX >= 1, targetY >= 1, targetX < width - 1, targetY < height - 1 else { continue }
                var difference: Float = 1
                for dy in -1...1 {
                    for dx in -1...1 { difference = min(difference, abs(reference - color(b, targetX + dx, targetY + dy)).sum() / 3) }
                }
                checked += 1
                if difference < 0.12 { agreeing += 1 }
            }
        }
        return checked >= 20 && Double(agreeing) / Double(checked) >= 0.70
    }

    static func track(url: URL, from start: Double, to end: Double,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> AnnotationCameraMotion {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw AnalysisError.noVideoTrack }
        let size = try await video.load(.naturalSize)
        let frameRate = try await video.load(.nominalFrameRate)
        let fallbackFrameDuration = frameRate > 0 ? 1 / Double(frameRate) : 1 / 30
        let orientation = AnalysisEngine.orientation(for: try await video.load(.preferredTransform))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let scale = min(1, 640 / max(size.width, size.height))
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: max(2, Int(size.width * scale / 2) * 2),
            kCVPixelBufferHeightKey as String: max(2, Int(size.height * scale / 2) * 2)
        ])
        output.alwaysCopiesSampleData = false; reader.add(output)
        guard reader.startReading() else { throw AnalysisError.reader("Cannot open video for camera tracking") }
        defer { reader.cancelReading() }
        let context = CIContext(options: [.cacheIntermediates: false])
        var previous: CameraFeatureRegistration.Frame?
        var reference: CameraFeatureRegistration.Frame?
        var anchor: CameraFeatureRegistration.Frame?
        var anchorTime = start
        var anchorTransform = matrix_identity_float3x3
        var lastTime = start - 1
        var lastFrameEnd = start
        var accumulated = matrix_identity_float3x3
        var motion = AnnotationCameraMotion(samples: [.init(time: start, transform: .identity)])
        var nextSample = output.copyNextSampleBuffer()
        while let sample = nextSample {
            nextSample = output.copyNextSampleBuffer()
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let duration = CMSampleBufferGetDuration(sample).seconds
            let frameEnd = time + (duration.isFinite && duration > 0 ? duration : fallbackFrameDuration)
            // Include the terminal decoded frame even when it falls between the
            // normal analysis samples. The displayed last frame lasts to its end.
            guard time - lastTime >= 0.045 || nextSample == nil || frameEnd >= end - 1 / 600,
                  let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if ProcessInfo.processInfo.thermalState == .critical { throw AnalysisError.thermal }
            let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
            guard let decoded = context.createCGImage(image, from: image.extent),
                  let current = CameraFeatureRegistration.Frame(decoded) else { continue }
            if let previous {
                // Keep the original scene as well as a rolling anchor. When a
                // pan returns, register to the original pixels to remove the
                // accumulated error, using the last pose only to locate patches.
                let prediction = CameraTransform(accumulated)
                let referenceVisible = Self.referenceStillVisible(prediction)
                if referenceVisible, let reference,
                   let direct = CameraFeatureRegistration.register(previous: reference, current: current, initial: prediction) {
                    accumulated = direct.matrix
                    anchor = current; anchorTransform = accumulated; anchorTime = time
                } else if let anchor, let direct = try? registerScene(previous: anchor, current: current) {
                    accumulated = direct.matrix * anchorTransform
                } else if let step = try registerScene(previous: previous, current: current) {
                    accumulated = step.matrix * accumulated
                    anchor = current; anchorTransform = accumulated; anchorTime = time
                } else { motion.lostAt = time; break }
                guard abs(accumulated[2][2]) > 0.00001 else { motion.lostAt = time; break }
                accumulated *= 1 / accumulated[2][2]
                motion.samples.append(.init(time: time, transform: CameraTransform(accumulated)))
            }
            if reference == nil { reference = current }
            if anchor == nil || time - anchorTime >= 1 {
                anchor = current; anchorTransform = accumulated; anchorTime = time
            }
            previous = current; lastTime = time; lastFrameEnd = frameEnd
            progress(min(1, (time - start) / max(0.01, end - start)))
        }
        if reader.status == .failed { throw AnalysisError.reader(reader.error?.localizedDescription ?? "Camera tracking decode failed") }
        if motion.lostAt == nil, let last = motion.samples.last,
           previous != nil, end - lastFrameEnd <= max(0.05, fallbackFrameDuration * 1.5), last.time < end {
            motion.samples.append(.init(time: end, transform: last.transform))
        }
        progress(1)
        return motion
    }

    /// Pitch points as well as the far touchline. A pan that keeps the grass
    /// and loses the stands can still re-lock to the original frame.
    static func referenceStillVisible(_ prediction: CameraTransform) -> Bool {
        let probes = [CGPoint(x: 0.2, y: 0.28), .init(x: 0.5, y: 0.28), .init(x: 0.8, y: 0.28),
                      .init(x: 0.2, y: 0.55), .init(x: 0.5, y: 0.55), .init(x: 0.8, y: 0.55),
                      .init(x: 0.25, y: 0.78), .init(x: 0.5, y: 0.78), .init(x: 0.75, y: 0.78)]
        let visible = CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96)
        return probes.compactMap { prediction.point($0) }.filter { visible.contains($0) }.count >= 4
    }
}

/// Camera motion accumulated from a trusted frame, including after the direct
/// pair no longer overlaps. The transform maps that trusted frame into the
/// latest one. A failed step holds the last good pose briefly, then reports nil.
struct IncrementalSceneCamera {
    private var reference: CameraFeatureRegistration.Frame?
    private var previous: CameraFeatureRegistration.Frame?
    private var anchor: CameraFeatureRegistration.Frame?
    private var anchorTransform = matrix_identity_float3x3
    private var accumulated = matrix_identity_float3x3
    private var lastGood = matrix_identity_float3x3
    private var lastGoodTime = -Double.infinity
    private var primed = false

    mutating func reset() { self = IncrementalSceneCamera() }

    /// The first call stores the origin and returns identity.
    mutating func observe(_ frame: CameraFeatureRegistration.Frame, at time: Double) -> CameraTransform? {
        if !primed {
            primed = true
            reference = frame
            previous = frame
            anchor = frame
            lastGoodTime = time
            return .identity
        }
        let prediction = CameraTransform(accumulated)
        var updated = false
        if CameraMotionTracking.referenceStillVisible(prediction), let reference,
           let direct = CameraFeatureRegistration.register(previous: reference, current: frame, initial: prediction) {
            accumulated = direct.matrix
            anchor = frame
            anchorTransform = accumulated
            updated = true
        } else if let anchor, let direct = try? CameraMotionTracking.registerScene(previous: anchor, current: frame) {
            accumulated = direct.matrix * anchorTransform
            updated = true
        } else if let previous, let step = try? CameraMotionTracking.registerScene(previous: previous, current: frame) {
            accumulated = step.matrix * accumulated
            anchor = frame
            anchorTransform = accumulated
            updated = true
        }
        previous = frame
        guard updated, abs(accumulated[2][2]) > 0.00001 else {
            return time - lastGoodTime <= 0.45 ? CameraTransform(lastGood) : nil
        }
        accumulated *= 1 / accumulated[2][2]
        lastGood = accumulated
        lastGoodTime = time
        return CameraTransform(accumulated)
    }
}
