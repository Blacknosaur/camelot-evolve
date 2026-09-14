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

    func transform(at time: Double) -> CameraTransform? {
        guard let current = rawTransform(at: time) else { return nil }
        guard let referenceTime else { return current }
        guard let reference = rawTransform(at: referenceTime), abs(reference.matrix.determinant) > 0.00001 else { return nil }
        return CameraTransform(current.matrix * reference.matrix.inverse)
    }

    private func rawTransform(at time: Double) -> CameraTransform? {
        guard let first = samples.first, let last = samples.last, time >= first.time - 0.05,
              time <= last.time + 0.15, lostAt.map({ time < $0 }) ?? true else { return nil }
        var low = 0, high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < time { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return first.transform }
        let a = samples[low - 1], b = samples[low]
        let fraction = min(1, max(0, (time - a.time) / max(0.001, b.time - a.time)))
        return CameraTransform(values: zip(a.transform.values, b.transform.values).map { $0 + ($1 - $0) * fraction })
    }
    func points(_ points: [CGPoint], at time: Double) -> [CGPoint]? {
        guard let transform = transform(at: time) else { return nil }
        let mapped = points.compactMap { transform.point($0) }
        return mapped.count == points.count ? mapped : nil
    }
}

enum CameraMotionTracking {
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
        func image(_ buffer: CVPixelBuffer) -> CGImage? {
            let source = CIImage(cvPixelBuffer: buffer).oriented(orientation)
            let scale = min(1, 640 / max(source.extent.width, source.extent.height))
            let reduced = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return context.createCGImage(reduced, from: reduced.extent)
        }
        guard let previous = image(previous), let current = image(current) else { return nil }
        return try register(previous: previous, current: current)
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
        var previous: CGImage?
        var anchor: CGImage?
        var anchorTime = start
        var anchorTransform = matrix_identity_float3x3
        var lastTime = start - 1
        var accumulated = matrix_identity_float3x3
        var motion = AnnotationCameraMotion(samples: [.init(time: start, transform: .identity)])
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time - lastTime >= 0.045, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if ProcessInfo.processInfo.thermalState == .critical { throw AnalysisError.thermal }
            let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
            guard let current = context.createCGImage(image, from: image.extent) else { continue }
            if let previous {
                // Register back to a short-lived key image instead of integrating
                // every small frame error. Fall back to adjacent frames for fast pans.
                if let anchor, let direct = try? registerBackground(previous: anchor, current: current) {
                    accumulated = direct.matrix * anchorTransform
                } else if let step = try registerBackground(previous: previous, current: current) {
                    accumulated = step.matrix * accumulated
                    anchor = current; anchorTransform = accumulated; anchorTime = time
                } else { motion.lostAt = time; break }
                guard abs(accumulated[2][2]) > 0.00001 else { motion.lostAt = time; break }
                accumulated *= 1 / accumulated[2][2]
                motion.samples.append(.init(time: time, transform: CameraTransform(accumulated)))
            }
            if anchor == nil || time - anchorTime >= 1 {
                anchor = current; anchorTransform = accumulated; anchorTime = time
            }
            previous = current; lastTime = time
            progress(min(1, (time - start) / max(0.01, end - start)))
        }
        if reader.status == .failed { throw AnalysisError.reader(reader.error?.localizedDescription ?? "Camera tracking decode failed") }
        progress(1)
        return motion
    }
}
