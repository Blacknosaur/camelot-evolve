import CoreGraphics
import CoreVideo
import ImageIO
import Foundation
import simd

enum PlayerTrackingLimits {
    /// Maximum time to carry a confirmed trajectory through a temporary loss.
    /// Predicted positions remain recovery hints only; they are never rendered
    /// or persisted as confirmed samples.
    static let maximumRecoverySeconds = 2.5
}

/// Compact torso color distribution, including stripes and neutral kits. Never
/// discard green pixels categorically: a green jersey is not necessarily grass.
struct PlayerJerseySignature: Codable, Equatable, Sendable {
    var bins: [Float]

    init(colors: [SIMD3<Float>]) {
        var histogram = [Float](repeating: 0, count: 15)
        for rgb in colors {
            let high = max(rgb.x, max(rgb.y, rgb.z)), low = min(rgb.x, min(rgb.y, rgb.z))
            let delta = high - low, saturation = high > 0 ? delta / high : 0
            if saturation < 0.2 || high < 0.12 {
                let value = min(2, max(0, high * 2))
                let lower = min(2, Int(value)), upper = min(2, lower + 1), fraction = value - Float(lower)
                histogram[12 + lower] += 1 - fraction; histogram[12 + upper] += fraction
            } else {
                var hue: Float
                if high == rgb.x { hue = (rgb.y - rgb.z) / delta }
                else if high == rgb.y { hue = 2 + (rgb.z - rgb.x) / delta }
                else { hue = 4 + (rgb.x - rgb.y) / delta }
                if hue < 0 { hue += 6 }
                let bin = hue * 2, index = Int(bin) % 12, fraction = bin - floor(bin)
                histogram[index] += 1 - fraction; histogram[(index + 1) % 12] += fraction
            }
        }
        let total = max(1, histogram.reduce(0, +))
        bins = histogram.map { $0 / total }
    }

    func similarity(to other: Self) -> Float {
        guard bins.count == 15, other.bins.count == 15 else { return 0 }
        return zip(bins, other.bins).reduce(0) { $0 + sqrt(max(0, $1.0 * $1.1)) }
    }

    static func sample(_ buffer: CVPixelBuffer, box: CGRect, orientation: CGImagePropertyOrientation) -> Self? {
        guard box.width > 0, box.height > 0,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        var colors: [SIMD3<Float>] = []; colors.reserveCapacity(120)
        for row in 0..<10 {
            for column in 0..<12 {
                let point = AnalysisEngine.bufferPoint(CGPoint(x: box.minX + box.width * (0.28 + (CGFloat(column) + 0.5) * 0.44 / 12),
                                                              y: box.minY + box.height * (0.20 + (CGFloat(row) + 0.5) * 0.28 / 10)), orientation: orientation)
                let x = Int(point.x * CGFloat(width)), y = Int(point.y * CGFloat(height))
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                let p = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
                colors.append(SIMD3(Float(p[2]), Float(p[1]), Float(p[0])) / 255)
            }
        }
        return colors.count >= 60 ? Self(colors: colors) : nil
    }
}

struct PlayerJerseyProfile: Codable, Equatable, Sendable {
    private(set) var examples: [PlayerJerseySignature] = []
    /// The seed alone may include an overlapping opponent. Recovery needs a
    /// second clear observation from a later frame before trusting that kit.
    var isConfirmed: Bool { examples.count >= 2 }

    static func resuming(_ profile: Self?) -> Self {
        // Correct can replace a provisional mixed/occluded seed, but never
        // silently teaches a confirmed saved player a different identity.
        if let profile, profile.isConfirmed { return profile }
        return Self()
    }

    func similarity(to signature: PlayerJerseySignature) -> Float {
        guard let anchor = examples.first else { return 0 }
        // Retain the original identity anchor; adaptive examples cannot slowly
        // teach this player another team's shirt after a crossing.
        let best = examples.map { $0.similarity(to: signature) }.max() ?? 0
        return anchor.similarity(to: signature) * 0.6 + best * 0.4
    }

    mutating func learn(_ signature: PlayerJerseySignature, clear: Bool) {
        guard clear, examples.isEmpty || similarity(to: signature) >= 0.78 else { return }
        if examples.count == 8 { examples.remove(at: 1) }
        examples.append(signature)
    }
}

/// Recent confirmed feet, not extrapolated output. Linear fitting is less noisy
/// than a velocity estimated from only the last two detection boxes.
struct PlayerTrackingTrajectory {
    private(set) var samples: [PlayerMotionSample] = []

    mutating func append(_ sample: PlayerMotionSample) {
        if let last = samples.last, sample.time <= last.time { return }
        if let last = samples.last, sample.time - last.time > 0.25 { samples = [] }
        samples.append(sample)
        samples = Array(samples.filter { $0.time >= sample.time - 0.7 }.suffix(24))
    }

    func predicted(at time: Double, cameraVelocity: CGPoint = .zero) -> CGRect? {
        guard let last = samples.last else { return nil }
        guard samples.count >= 3, let first = samples.first, last.time - first.time > 0.06 else { return last.box }
        let meanT = samples.map(\.time).reduce(0, +) / Double(samples.count)
        var denominator = 0.0, dx = 0.0, dy = 0.0
        for sample in samples {
            let dt = sample.time - meanT
            denominator += dt * dt; dx += dt * sample.box.midX; dy += dt * sample.box.maxY
        }
        guard denominator > 0.00001 else { return last.box }
        let horizon = min(PlayerTrackingLimits.maximumRecoverySeconds, max(0, time - last.time))
        let maximum = max(0.04, last.box.height * 2)
        let vx = min(maximum, max(-maximum, dx / denominator - cameraVelocity.x))
        let vy = min(maximum, max(-maximum, dy / denominator - cameraVelocity.y))
        return last.box.offsetBy(dx: vx * horizon, dy: vy * horizon)
    }
}

enum PlayerIdentityAssociation {
    struct Candidate {
        let box: CGRect
        let jersey: PlayerJerseySignature?
        var crowded = false
    }
    struct Match {
        let candidate: Candidate
        let score: CGFloat
    }

    static func choose(_ candidates: [Candidate], expected: CGRect, optical: CGRect?, profile: PlayerJerseyProfile,
                       recovering: Bool) -> Match? {
        let ranked = candidates.compactMap { candidate -> Match? in
            let box = candidate.box
            let dx = abs(box.midX - expected.midX) / max(0.015, expected.width)
            let dy = abs(box.maxY - expected.maxY) / max(0.03, expected.height)
            guard dx < (recovering ? 2 : 1.3), dy < (recovering ? 1.2 : 0.8),
                  box.height / expected.height > 0.55, box.height / expected.height < 1.8 else { return nil }
            let appearance = candidate.jersey.map { CGFloat(profile.similarity(to: $0)) }
            let hasProfile = !profile.examples.isEmpty
            if hasProfile, (appearance ?? 0) < (recovering ? 0.74 : 0.60) { return nil }
            if recovering {
                guard profile.isConfirmed else { return nil }
                if candidate.crowded {
                    // A clearly visible jersey can distinguish overlapping
                    // opponents. Same-kit or unreadable overlaps stay hidden.
                    let neighbours = candidates.filter { $0.box != box && PlayerTracker.overlap($0.box, box) > 0.25 }
                    guard let appearance, appearance >= 0.82, !neighbours.isEmpty,
                          neighbours.allSatisfy({ other in
                              guard let jersey = other.jersey else { return false }
                              let score = CGFloat(profile.similarity(to: jersey))
                              return score < 0.55 && appearance - score > 0.3
                          }) else { return nil }
                }
            }
            let spatial = max(0, 1 - hypot(dx, dy) / (recovering ? 2.2 : 1.5))
            let overlap = optical.map { PlayerTracker.overlap($0, box) } ?? 0
            let score = hasProfile ? (appearance ?? 0) * 0.45 + spatial * 0.4 + overlap * 0.15 : spatial * 0.6 + overlap * 0.4
            return Match(candidate: candidate, score: score)
        }.sorted { $0.score > $1.score }
        guard let best = ranked.first, best.score >= (recovering ? 0.58 : 0.45),
              ranked.count == 1 || best.score - ranked[1].score >= (recovering ? 0.12 : 0.08) else { return nil }
        return best
    }
}

/// Reacquisition requires agreement in two detector observations, not a single
/// same-color body passing through the predicted position.
struct PlayerRecoveryConfirmation {
    private struct Observation {
        var time: Double
        var box: CGRect
        var camera: CameraTransform?
    }
    private var pending: Observation?
    mutating func accept(_ box: CGRect?, at time: Double, camera: CameraTransform? = nil) -> Bool {
        guard let box else { pending = nil; return false }
        let previous = pending
        pending = .init(time: time, box: box, camera: camera)
        guard let previous, time - previous.time >= 0.04, time - previous.time <= 0.3 else { return false }
        var feet = CGPoint(x: previous.box.midX, y: previous.box.maxY)
        if let camera, let old = previous.camera, abs(old.matrix.determinant) > 0.00001,
           let mapped = CameraTransform(camera.matrix * old.matrix.inverse).point(feet) { feet = mapped }
        let confirmed = abs(box.midX - feet.x) < max(box.width, previous.box.width) * 0.8 &&
            abs(box.maxY - feet.y) < max(box.height, previous.box.height) * 0.5
        if confirmed { pending = nil }
        return confirmed
    }
}
