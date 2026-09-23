import Foundation
import CoreGraphics
import simd

/// A small metric model for the image plane. Points are normalized, top-left
/// image coordinates, as used by the analysis renderer.
struct GroundCalibration: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case localScale
        case plane
        var id: String { rawValue }
    }

    var mode: Mode
    var points: [CGPoint]
    var lengthMeters: Double
    var widthMeters: Double
    var referenceTime: Double
    var imageAspectRatio: Double
    var fixedCamera: Bool = false
    var cameraMotion: AnnotationCameraMotion? = nil
    var fieldReference: GroundFieldReference? = nil
    var lineReferences: [GroundLineObservation]? = nil
    var circleReference: GroundCircleReference? = nil

    init(mode: Mode, points: [CGPoint], lengthMeters: Double, widthMeters: Double = 0,
         referenceTime: Double, imageAspectRatio: Double, fixedCamera: Bool = false,
         cameraMotion: AnnotationCameraMotion? = nil) {
        self.mode = mode; self.points = points; self.lengthMeters = lengthMeters
        self.widthMeters = widthMeters; self.referenceTime = referenceTime
        self.imageAspectRatio = imageAspectRatio; self.fixedCamera = fixedCamera
        self.cameraMotion = cameraMotion
    }

    // Defaults make old saved annotations decode safely when new fields are absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .localScale
        points = try c.decodeIfPresent([CGPoint].self, forKey: .points) ?? []
        lengthMeters = try c.decodeIfPresent(Double.self, forKey: .lengthMeters) ?? 0
        widthMeters = try c.decodeIfPresent(Double.self, forKey: .widthMeters) ?? 0
        referenceTime = try c.decodeIfPresent(Double.self, forKey: .referenceTime) ?? 0
        imageAspectRatio = try c.decodeIfPresent(Double.self, forKey: .imageAspectRatio) ?? 1
        fixedCamera = try c.decodeIfPresent(Bool.self, forKey: .fixedCamera) ?? false
        cameraMotion = try c.decodeIfPresent(AnnotationCameraMotion.self, forKey: .cameraMotion)
        fieldReference = try c.decodeIfPresent(GroundFieldReference.self, forKey: .fieldReference)
        lineReferences = try c.decodeIfPresent([GroundLineObservation].self, forKey: .lineReferences)
        circleReference = try c.decodeIfPresent(GroundCircleReference.self, forKey: .circleReference)
    }

    var valid: Bool {
        guard lengthMeters.isFinite, lengthMeters > 0, imageAspectRatio.isFinite, imageAspectRatio > 0,
              referenceTime.isFinite, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        switch mode {
        case .localScale:
            guard points.count == 2 else { return false }
            let d = CGPoint(x: points[1].x - points[0].x, y: points[1].y - points[0].y)
            return hypot(Double(d.x) * imageAspectRatio, Double(d.y)) > 1e-9
        case .plane:
            guard points.count == 4, widthMeters.isFinite, widthMeters > 0,
                  let projection = AnalysisFieldGuide.projection(corners: points) else { return false }
            return projection.values.allSatisfy(\.isFinite)
        }
    }

    var isApproximate: Bool { mode == .localScale }

    /// A freeze frame reuses the visible ground pose without another camera pass.
    func frozen(at time: Double) -> Self? {
        guard valid, let camera = cameraTransform(at: time) else { return nil }
        let mapped = points.compactMap { camera.point($0) }
        guard mapped.count == points.count else { return nil }
        var result = self
        result.points = mapped; result.referenceTime = time
        result.circleReference = circleReference?.transformed(by: camera)
        if let lines = lineReferences {
            let moved = lines.map { GroundLineObservation(kind: $0.kind, points: $0.points.compactMap { camera.point($0) }) }
            result.lineReferences = moved.allSatisfy { $0.points.count == 2 } ? moved : nil
        }
        result.fixedCamera = true; result.cameraMotion = nil
        return result.valid ? result : nil
    }

    func worldPoint(_ point: CGPoint, at time: Double) -> CGPoint? {
        guard valid, let referencePoint = referencePoint(point, at: time) else { return nil }
        switch mode {
        case .localScale:
            let delta = CGPoint(x: referencePoint.x - points[0].x, y: referencePoint.y - points[0].y)
            let x = Double(delta.x) * imageAspectRatio, y = Double(delta.y)
            let basis = CGPoint(x: points[1].x - points[0].x, y: points[1].y - points[0].y)
            let scale = lengthMeters / hypot(Double(basis.x) * imageAspectRatio, Double(basis.y))
            return finite(CGPoint(x: x * scale, y: y * scale))
        case .plane:
            guard let projection = AnalysisFieldGuide.projection(corners: points),
                  let center = projection.point(CGPoint(x: 0.5, y: 0.5)),
                  let inverse = inversePoint(referencePoint, transform: projection, anchor: center) else { return nil }
            return finite(CGPoint(x: inverse.x * lengthMeters, y: inverse.y * widthMeters))
        }
    }

    func imagePoint(_ world: CGPoint, at time: Double) -> CGPoint? {
        guard valid, world.x.isFinite, world.y.isFinite,
              let camera = cameraTransform(at: time) else { return nil }
        let reference: CGPoint?
        switch mode {
        case .localScale:
            let basis = CGPoint(x: points[1].x - points[0].x, y: points[1].y - points[0].y)
            let scale = lengthMeters / hypot(Double(basis.x) * imageAspectRatio, Double(basis.y))
            guard scale > 0 else { return nil }
            reference = CGPoint(x: points[0].x + world.x / scale / imageAspectRatio,
                                y: points[0].y + world.y / scale)
        case .plane:
            guard let projection = AnalysisFieldGuide.projection(corners: points) else { return nil }
            reference = projectWorld(world, with: projection)
        }
        guard let reference, reference.x.isFinite, reference.y.isFinite else { return nil }
        return camera.point(reference)
    }

    func distance(from a: CGPoint, to b: CGPoint, at time: Double) -> Double? {
        guard let lhs = worldPoint(a, at: time), let rhs = worldPoint(b, at: time) else { return nil }
        let value = hypot(Double(lhs.x - rhs.x), Double(lhs.y - rhs.y))
        return value.isFinite ? value : nil
    }

    func speed(of motion: PlayerMotion, at time: Double) -> Double? {
        guard valid, time.isFinite, !motion.isMissing(at: time) else { return nil }
        let samples = motion.samples
        guard !samples.isEmpty else { return nil }
        func lowerBound(_ value: Double) -> Int {
            var low = 0, high = samples.count
            while low < high {
                let mid = (low + high) / 2
                if samples[mid].time < value { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let startIndex = lowerBound(time - 0.3)
        let endIndex = lowerBound(time + 0.3)
        guard startIndex < samples.count else { return nil }
        let lower = max(time - 0.3, samples[startIndex].time)
        let upperSampleIndex = min(samples.count - 1, max(startIndex, endIndex))
        let upper = min(time + 0.3, samples[upperSampleIndex].time)
        guard upper - lower >= 0.2, motion.box(at: time) != nil else { return nil }
        let spanStart = max(0, startIndex - 1), spanEnd = min(samples.count - 1, upperSampleIndex + 1)
        guard spanStart <= spanEnd else { return nil }
        for index in spanStart..<spanEnd {
            let a = samples[index].time, b = samples[index + 1].time
            if a < upper && b > lower && b - a > 0.2 { return nil }
        }
        let interval = lower...upper
        if motion.lostAt.map({ interval.lowerBound < $0 && interval.upperBound >= $0 }) ?? false { return nil }
        if motion.gaps?.contains(where: { $0.lowerBound <= interval.upperBound && $0.upperBound >= interval.lowerBound }) ?? false { return nil }
        var values: [(Double, CGPoint)] = []
        let count = min(21, max(2, Int(ceil((upper - lower) / 0.03)) + 1))
        for index in 0..<count {
            let sampleTime = lower + (upper - lower) * Double(index) / Double(count - 1)
            // A cropped box ends at the image edge, not at the player's feet.
            // Full-body display estimates cannot be reported as measured speed.
            guard !motion.isMissing(at: sampleTime), let box = motion.box(at: sampleTime),
                  !PlayerPresence.leftFrame(box),
                  let world = worldPoint(CGPoint(x: box.midX, y: box.maxY), at: sampleTime) else { return nil }
            values.append((sampleTime, world))
        }
        guard values.count >= 2 else { return nil }
        let meanT = values.map(\.0).reduce(0, +) / Double(values.count)
        let meanX = values.map { Double($0.1.x) }.reduce(0, +) / Double(values.count)
        let meanY = values.map { Double($0.1.y) }.reduce(0, +) / Double(values.count)
        let denominator = values.reduce(0) { $0 + ($1.0 - meanT) * ($1.0 - meanT) }
        guard denominator > 1e-9 else { return nil }
        let vx = values.reduce(0) { $0 + ($1.0 - meanT) * (Double($1.1.x) - meanX) } / denominator
        let vy = values.reduce(0) { $0 + ($1.0 - meanT) * (Double($1.1.y) - meanY) } / denominator
        let result = hypot(vx, vy)
        return result.isFinite ? result : nil
    }

    func circle(center: CGPoint, radiusMeters: Double, at time: Double) -> [CGPoint]? {
        guard mode == .plane, radiusMeters.isFinite, radiusMeters >= 0,
              let origin = worldPoint(center, at: time),
              let projection = AnalysisFieldGuide.projection(corners: points),
              let camera = cameraTransform(at: time) else { return nil }
        var result: [CGPoint] = []; result.reserveCapacity(32)
        for i in 0..<32 {
            let angle = Double(i) * 2 * .pi / 32
            let world = CGPoint(x: origin.x + cos(angle) * radiusMeters, y: origin.y + sin(angle) * radiusMeters)
            guard let reference = projectWorld(world, with: projection), let point = camera.point(reference) else { return nil }
            result.append(point)
        }
        return result
    }

    private func projectWorld(_ world: CGPoint, with projection: CameraTransform) -> CGPoint? {
        let mapped = projection.matrix * SIMD3(Float(world.x / lengthMeters), Float(world.y / widthMeters), 1)
        let center = projection.matrix * SIMD3(0.5, 0.5, 1)
        guard mapped.z.isFinite, abs(mapped.z) > max(0.00001, abs(center.z) * 0.0001),
              mapped.z * center.z > 0 else { return nil }
        return finite(CGPoint(x: CGFloat(mapped.x / mapped.z), y: CGFloat(mapped.y / mapped.z)))
    }

    func cameraTransform(at time: Double) -> CameraTransform? {
        guard time.isFinite else { return nil }
        if fixedCamera { return .identity }
        guard var motion = cameraMotion else {
            return abs(time - referenceTime) <= 0.12 ? .identity : nil
        }
        // Use the same source-frame boundary tolerance and failure rules as
        // drawings; a field reference may be authored anywhere within the clip.
        motion.referenceTime = referenceTime
        return motion.transform(at: time)
    }

    private func referencePoint(_ point: CGPoint, at time: Double) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, let camera = cameraTransform(at: time) else { return nil }
        guard let inverse = inversePoint(point, transform: camera) else { return nil }
        return inverse
    }

    private func inversePoint(_ point: CGPoint, transform: CameraTransform, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> CGPoint? {
        guard transform.values.count == 9, transform.values.allSatisfy(\.isFinite),
              abs(transform.matrix.determinant) > 1e-7 else { return nil }
        let inverse = simd_inverse(transform.matrix)
        let value = inverse * SIMD3(Float(point.x), Float(point.y), 1)
        let center = inverse * SIMD3(Float(anchor.x), Float(anchor.y), 1)
        guard value.z.isFinite, center.z.isFinite,
              abs(value.z) > max(0.00001, abs(center.z) * 0.0001),
              value.z * center.z > 0 else { return nil }
        let mapped = CGPoint(x: CGFloat(value.x / value.z), y: CGFloat(value.y / value.z))
        return mapped.x.isFinite && mapped.y.isFinite ? mapped : nil
    }

    private func finite(_ point: CGPoint) -> CGPoint? {
        point.x.isFinite && point.y.isFinite ? point : nil
    }
}
