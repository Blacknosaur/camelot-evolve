import CoreGraphics
import CoreVideo
import ImageIO
import Foundation
import simd

enum PlayerTrackingLimits {
    /// Local recovery window. After this, sparse detection looks for stronger
    /// individual evidence of a return, without extending the predicted path.
    /// Predicted positions remain recovery hints only; they are never rendered
    /// or persisted as confirmed samples.
    static let maximumRecoverySeconds = 2.5
    /// Old running speed becomes unsafe quickly when a player stops or turns.
    /// Continue searching for longer, but never carry that velocity indefinitely.
    static let maximumPredictionSeconds = 0.75
    /// Highest rate the per-frame identity logic is sampled at. Every gate here
    /// was tuned on 30 fps footage; 60 fps costs twice as much for no extra
    /// accuracy, so faster sources are decimated to this.
    /// Overridable only so the device benchmark can time the same footage at
    /// two rates in one thermal state.
    nonisolated(unsafe) static var maximumSampleRate = 30.0
    /// Seconds between sampled frames for a source of this rate. Sources at or
    /// below the cap keep every frame.
    static func samplingInterval(sourceFrameRate: Double) -> Double {
        guard sourceFrameRate.isFinite, sourceFrameRate > 0 else { return 1 / maximumSampleRate }
        return 1 / min(maximumSampleRate, sourceFrameRate)
    }
    /// Smallest body size the association gates are scaled by (frame units).
    static let minimumGateWidth: CGFloat = 0.03
    static let minimumGateHeight: CGFloat = 0.06
    /// A body that suddenly stands this much taller than the player's recent
    /// height is two bodies in one detector box (someone passing in front).
    static let mergedHeightRatio: CGFloat = 1.35
    static func isMerged(_ box: CGRect, recentHeights: [CGFloat]) -> Bool {
        guard recentHeights.count >= 8 else { return false }
        let sorted = recentHeights.sorted()
        return box.height > sorted[sorted.count / 2] * mergedHeightRatio
    }
    /// Diagnostic hook for tests: receives one line per tracking decision.
    nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)? = nil
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
        guard bins.count == other.bins.count, !bins.isEmpty else { return 0 }
        return zip(bins, other.bins).reduce(0) { $0 + sqrt(max(0, $1.0 * $1.1)) }
    }

    /// Body regions sampled inside a detector box. The torso carries the shirt;
    /// the shorts region is a second, independent kit feature for the roster.
    enum Zone: Sendable {
        case torso, shorts, head, legs
        var horizontal: (offset: CGFloat, width: CGFloat) {
            switch self {
            case .head: (0.34, 0.32)
            default: (0.28, 0.44)
            }
        }
        var vertical: (offset: CGFloat, height: CGFloat) {
            switch self {
            case .torso: (0.20, 0.28)
            case .shorts: (0.52, 0.16)
            case .head: (0.01, 0.13)
            case .legs: (0.72, 0.22)
            }
        }
    }

    /// Chromaticity distribution of a region (r and b shares of r+g+b, 5×5
    /// soft bins over 0.2–0.5). Independent of brightness, so a floodlit blue
    /// shirt whose pixels read as "neutral" in the hue histogram still sits in
    /// a different place from a white one.
    init(chromaOf colors: [SIMD3<Float>]) {
        var histogram = [Float](repeating: 0, count: 25)
        for rgb in colors {
            let sum = max(0.05, rgb.x + rgb.y + rgb.z)
            let r = min(3.999, max(0, (rgb.x / sum - 0.2) / 0.3 * 4)), b = min(3.999, max(0, (rgb.z / sum - 0.2) / 0.3 * 4))
            let r0 = Int(r), b0 = Int(b), fr = r - Float(r0), fb = b - Float(b0)
            histogram[r0 * 5 + b0] += (1 - fr) * (1 - fb)
            histogram[(r0 + 1) * 5 + b0] += fr * (1 - fb)
            histogram[r0 * 5 + b0 + 1] += (1 - fr) * fb
            histogram[(r0 + 1) * 5 + b0 + 1] += fr * fb
        }
        let total = max(1, histogram.reduce(0, +))
        bins = histogram.map { $0 / total }
    }

    /// Brightness distribution of a region. Skin, hair and socks differ far
    /// more in tone than in hue, which the kit histogram deliberately ignores.
    init(brightnessOf colors: [SIMD3<Float>]) {
        var histogram = [Float](repeating: 0, count: 15)
        for rgb in colors {
            let value = min(14, max(0, (0.299 * rgb.x + 0.587 * rgb.y + 0.114 * rgb.z) * 14))
            let lower = min(14, Int(value)), upper = min(14, lower + 1), fraction = value - Float(lower)
            histogram[lower] += 1 - fraction; histogram[upper] += fraction
        }
        let total = max(1, histogram.reduce(0, +))
        bins = histogram.map { $0 / total }
    }

    /// Enough samples to describe a region. A masked sample discards everything
    /// off the body, so it clears the bar with fewer points than a box sample
    /// that is padded out with grass and whoever is standing behind the player.
    private static func minimumSamples(masked: Bool) -> Int { masked ? 36 : 60 }

    static func tone(_ buffer: CVPixelBuffer, box: CGRect, orientation: CGImagePropertyOrientation, zone: Zone,
                     mask: PlayerPixelMask? = nil, region: CGRect? = nil) -> Self? {
        let colors = sampleColors(buffer, box: box, orientation: orientation, zone: zone, mask: mask, region: region)
        return colors.count >= minimumSamples(masked: mask != nil) ? Self(brightnessOf: colors) : nil
    }

    static func sample(_ buffer: CVPixelBuffer, box: CGRect, orientation: CGImagePropertyOrientation, zone: Zone = .torso,
                       mask: PlayerPixelMask? = nil, region: CGRect? = nil) -> Self? {
        let colors = sampleColors(buffer, box: box, orientation: orientation, zone: zone, mask: mask, region: region)
        return colors.count >= minimumSamples(masked: mask != nil) ? Self(colors: colors) : nil
    }

    /// Mean torso colour for list swatches; not an identity feature.
    static func meanColor(_ colors: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard !colors.isEmpty else { return nil }
        return colors.reduce(SIMD3<Float>.zero, +) / Float(colors.count)
    }

    /// `mask` is tracking v2's subject mask: sample points that fall off the
    /// player are dropped rather than averaged in. Nil samples the whole zone,
    /// which is v1's behaviour and every other caller's.
    /// `region` replaces the band derived from `box` and `zone` — body pose
    /// knows where the shirt actually is, where the fixed slice is only a guess
    /// that drifts onto grass and neighbours as the box loosens.
    static func sampleColors(_ buffer: CVPixelBuffer, box: CGRect, orientation: CGImagePropertyOrientation, zone: Zone = .torso,
                             mask: PlayerPixelMask? = nil, region: CGRect? = nil) -> [SIMD3<Float>] {
        guard box.width > 0, box.height > 0,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let area = region?.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let usable = area.map { !$0.isNull && $0.width > 0.002 && $0.height > 0.004 } ?? false
        let horizontal = zone.horizontal, vertical = zone.vertical
        var colors: [SIMD3<Float>] = []; colors.reserveCapacity(120)
        for row in 0..<10 {
            for column in 0..<12 {
                let display: CGPoint
                if usable, let area {
                    display = CGPoint(x: area.minX + area.width * (CGFloat(column) + 0.5) / 12,
                                      y: area.minY + area.height * (CGFloat(row) + 0.5) / 10)
                } else {
                    display = CGPoint(x: box.minX + box.width * (horizontal.offset + (CGFloat(column) + 0.5) * horizontal.width / 12),
                                      y: box.minY + box.height * (vertical.offset + (CGFloat(row) + 0.5) * vertical.height / 10))
                }
                if let mask, !mask.contains(display) { continue }
                let point = AnalysisEngine.bufferPoint(display, orientation: orientation)
                let x = Int(point.x * CGFloat(width)), y = Int(point.y * CGFloat(height))
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                let p = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
                colors.append(SIMD3(Float(p[2]), Float(p[1]), Float(p[0])) / 255)
            }
        }
        return colors
    }
}

struct PlayerJerseyProfile: Codable, Equatable, Sendable {
    var trusted: [PlayerJerseySignature]? = nil
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
        return max(anchor.similarity(to: signature) * 0.6 + best * 0.4, trusted?.map { $0.similarity(to: signature) }.max() ?? 0)
    }

    /// A user pick is stronger evidence than repeated automatic observations.
    mutating func confirm(_ signature: PlayerJerseySignature) { examples = [signature, signature] }

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

    /// Re-express recent feet in the current frame after a camera move, so a
    /// fitted velocity describes the player rather than the pan.
    mutating func applyCamera(_ transform: CameraTransform) {
        samples = samples.compactMap { sample in
            guard let feet = transform.point(.init(x: sample.box.midX, y: sample.box.maxY)),
                  abs(feet.x) < 4, abs(feet.y) < 4 else { return nil }
            return .init(time: sample.time, box: CGRect(x: feet.x - sample.box.width / 2, y: feet.y - sample.box.height,
                                                        width: sample.box.width, height: sample.box.height))
        }
    }

    func predicted(at time: Double, cameraVelocity: CGPoint = .zero, playerVelocity: CGPoint? = nil) -> CGRect? {
        guard let last = samples.last else { return nil }
        guard samples.count >= 3, let first = samples.first, last.time - first.time > 0.06 else { return last.box }
        let meanT = samples.map(\.time).reduce(0, +) / Double(samples.count)
        var denominator = 0.0, dx = 0.0, dy = 0.0
        for sample in samples {
            let dt = sample.time - meanT
            denominator += dt * dt; dx += dt * sample.box.midX; dy += dt * sample.box.maxY
        }
        guard denominator > 0.00001 else { return last.box }
        let horizon = min(PlayerTrackingLimits.maximumPredictionSeconds, max(0, time - last.time))
        let maximum = max(0.04, last.box.height * 2)
        let vx = min(maximum, max(-maximum, playerVelocity?.x ?? (dx / denominator - cameraVelocity.x)))
        let vy = min(maximum, max(-maximum, playerVelocity?.y ?? (dy / denominator - cameraVelocity.y)))
        return last.box.offsetBy(dx: vx * horizon, dy: vy * horizon)
    }

    /// Image-plane feet velocity from the recent confirmed samples. Callers
    /// apply it only while the camera itself has barely moved, so a pan is
    /// not counted twice.
    func velocity() -> CGPoint? {
        guard let last = samples.last, samples.count >= 3, let first = samples.first,
              last.time - first.time > 0.06 else { return nil }
        let meanT = samples.map(\.time).reduce(0, +) / Double(samples.count)
        var denominator = 0.0, dx = 0.0, dy = 0.0
        for sample in samples {
            let dt = sample.time - meanT
            denominator += dt * dt
            dx += dt * sample.box.midX
            dy += dt * sample.box.maxY
        }
        guard denominator > 0.00001 else { return nil }
        return CGPoint(x: dx / denominator, y: dy / denominator)
    }
}

enum PlayerIdentityAssociation {
    struct Candidate {
        let box: CGRect
        let jersey: PlayerJerseySignature?
        var crowded = false
        /// Caller-owned index, so richer roster observations can be looked up.
        var tag = 0
    }
    struct Match {
        let candidate: Candidate
        let score: CGFloat
    }

    /// `overlapping` optionally supplies independently validated overlap.
    /// Both current tracking modes use box IoU for the same identity decisions.
    static func choose(_ candidates: [Candidate], expected: CGRect, optical: CGRect?, profile: PlayerJerseyProfile,
                       recovering: Bool, recoveryAge: Double = 0,
                       exitSide: PlayerExitSide? = nil,
                       bodyReference: CGRect? = nil,
                       requiredMargin: CGFloat? = nil,
                       appearance: ((Candidate) -> CGFloat?)? = nil,
                       overlapping: ((CGRect, CGRect) -> CGFloat)? = nil) -> Match? {
        let dormant = recovering && recoveryAge > PlayerTrackingLimits.maximumRecoverySeconds
        let ranked = ranked(candidates, expected: expected, optical: optical, profile: profile,
                            recovering: recovering, recoveryAge: recoveryAge, exitSide: exitSide, bodyReference: bodyReference, appearance: appearance,
                            overlapping: overlapping)
        guard let best = ranked.first, best.score >= minimumScore(recovering: recovering),
              ranked.count == 1 || best.score - ranked[1].score >= (requiredMargin ?? margin(recovering: recovering, dormant: dormant)) else { return nil }
        return best
    }

    static func minimumScore(recovering: Bool) -> CGFloat { recovering ? 0.58 : 0.45 }
    static func margin(recovering: Bool, dormant: Bool) -> CGFloat { dormant ? 0.16 : recovering ? 0.12 : 0.08 }

    /// Routine detector refreshes must stay attached to the live optical box.
    /// Appearance is allowed to choose among plausible recovery candidates,
    /// but it is not strong enough to move a visible track onto a teammate.
    static func isContinuous(_ candidate: CGRect, from optical: CGRect) -> Bool {
        PlayerTracker.overlap(candidate, optical) > 0.05 ||
            hypot(candidate.midX - optical.midX, candidate.maxY - optical.maxY) <= max(0.04, optical.height * 0.6)
    }

    /// Every candidate passing the identity gates, best first. The roster
    /// resolves competing identities on top of this per-player ranking.
    static func ranked(_ candidates: [Candidate], expected: CGRect, optical: CGRect?, profile: PlayerJerseyProfile,
                       recovering: Bool, recoveryAge: Double = 0,
                       exitSide: PlayerExitSide? = nil,
                       bodyReference: CGRect? = nil,
                       appearance: ((Candidate) -> CGFloat?)? = nil,
                       overlapping: ((CGRect, CGRect) -> CGFloat)? = nil) -> [Match] {
        let dormant = recovering && recoveryAge > PlayerTrackingLimits.maximumRecoverySeconds
        let expected = bodyReference.map { PlayerBodyExtent.estimate(visible: expected, reference: $0) } ?? expected
        let similarity: (Candidate) -> CGFloat? = appearance ?? { $0.jersey.map { CGFloat(profile.similarity(to: $0)) } }
        // Gates scale with the body, but a distant player is only a dozen
        // pixels wide: below a minimum unit, detector jitter and a small pan
        // would exceed any width-relative tolerance.
        let unitWidth = max(PlayerTrackingLimits.minimumGateWidth, expected.width)
        let unitHeight = max(PlayerTrackingLimits.minimumGateHeight, expected.height)
        return candidates.compactMap { candidate -> Match? in
            let box = PlayerBodyExtent.estimate(visible: candidate.box, reference: bodyReference ?? expected, expected: expected)
            // Single-player callers have already identity-gated edge returns.
            // The pre-exit trajectory is stale, but the known body scale is not.
            let edgeReturn = recovering && bodyReference != nil && (exitSide?.isNearEdge(candidate.box) == true)
            let dx = edgeReturn ? 0 : abs(box.midX - expected.midX) / unitWidth
            let dy = edgeReturn ? 0 : abs(box.maxY - expected.maxY) / unitHeight
            let referenceHeight = edgeReturn ? bodyReference!.height : expected.height
            guard dx < (dormant ? 3 : recovering ? 2 : 1.3), dy < (dormant ? 1.6 : recovering ? 1.2 : 0.8),
                  box.height / referenceHeight > 0.55, box.height / referenceHeight < 1.8 else { return nil }
            let appearance = similarity(candidate)
            let hasProfile = !profile.examples.isEmpty
            if hasProfile, (appearance ?? 0) < (dormant ? 0.82 : recovering ? 0.74 : 0.60) { return nil }
            if recovering {
                // An unconfirmed seed normally cannot recover: its one example
                // may include an overlapping opponent. A lone body that matches
                // every cue almost perfectly is the exception, so a player
                // tackled right after being picked is not lost for good.
                guard profile.isConfirmed || (!candidate.crowded && (appearance ?? 0) >= 0.9) else { return nil }
            }
            if recovering, candidate.crowded {
                // Without continuous motion, a crowded body needs a clearly
                // different opponent beside it before identity can be restored.
                let over = overlapping ?? { PlayerTracker.overlap($0, $1) }
                let neighbours = candidates.filter { $0.box != candidate.box && over($0.box, candidate.box) > 0.25 }
                guard let appearance, appearance >= 0.82, !neighbours.isEmpty,
                      neighbours.allSatisfy({ other in
                          guard let score = similarity(other) else { return false }
                          return score < 0.55 && appearance - score > 0.3
                      }) else { return nil }
            }
            let spatial = max(0, 1 - hypot(dx, dy) / (dormant ? 3.3 : recovering ? 2.2 : 1.5))
            let overlap = optical.map { PlayerTracker.overlap($0, box) } ?? 0
            let base = hasProfile ? (appearance ?? 0) * 0.45 + spatial * 0.4 + overlap * 0.15 : spatial * 0.6 + overlap * 0.4
            // A remembered exit edge is useful when a player returns near the
            // image boundary, but it must remain a prior rather than a gate:
            // camera motion, a tactical change, or a genuine re-entry from a
            // different edge can still win on the stronger identity cues.
            let sideBonus = recovering ? (exitSide.map { $0.reentryScore(for: box) } ?? 0) * (dormant ? 0.16 : 0.12) : 0
            let score = base + sideBonus
            return Match(candidate: candidate, score: score)
        }.sorted { $0.score > $1.score }
    }
}

/// Reacquisition requires agreement in two detector observations, not a single
/// same-color body passing through the predicted position. Keep a small set of
/// candidates while that evidence arrives. A single pending candidate was too
/// eager to discard the correct return when two same-kit bodies crossed during
/// recovery.
struct PlayerRecoveryConfirmation {
    private struct Observation {
        var time: Double
        var match: PlayerIdentityAssociation.Match
        var camera: CameraTransform?
        var confirmations: Int
        var score: CGFloat
        var samples: [PlayerMotionSample]
    }
    private static let maximumHypotheses = 3
    private static let decisionMargin: CGFloat = 0.06
    private var pending: [Observation] = []
    /// Only the winning hypothesis; source-frame boxes, never camera-warped.
    private(set) var confirmedSamples: [PlayerMotionSample] = []

    /// A gated sighting is the next search hint, not yet a confirmed identity.
    /// Using the old pre-occlusion velocity again would outrun a player who
    /// stopped, preventing the second observation from ever confirming them.
    func expected(at time: Double, camera: CameraTransform?, maximumInterval: Double = 0.3) -> CGRect? {
        guard let pending = pending
            .filter({ time > $0.time && time - $0.time <= maximumInterval })
            .max(by: { lhs, rhs in
                if lhs.confirmations != rhs.confirmations { return lhs.confirmations < rhs.confirmations }
                return lhs.score < rhs.score
            }) else { return nil }
        let box = pending.match.candidate.box
        guard let camera, let old = pending.camera, abs(old.matrix.determinant) > 0.00001,
              let feet = CameraTransform(camera.matrix * old.matrix.inverse)
                .point(.init(x: box.midX, y: box.maxY)) else { return box }
        return box.offsetBy(dx: feet.x - box.midX, dy: feet.y - box.maxY)
    }

    /// Feed all identity-gated candidates from a detector frame. The returned
    /// match is the only candidate allowed to become confirmed tracking.
    /// Competing candidates remain alive until one has both temporal support
    /// and a meaningful lead, so an ambiguous crossing becomes a short gap
    /// instead of an identity switch.
    mutating func accept(_ matches: [PlayerIdentityAssociation.Match], at time: Double,
                         camera: CameraTransform? = nil, requiredObservations: Int = 2,
                         maximumInterval: Double = 0.3, toleratesMiss: Bool = false) -> PlayerIdentityAssociation.Match? {
        confirmedSamples = []
        let eligible = matches.filter {
            $0.score >= PlayerIdentityAssociation.minimumScore(recovering: true)
        }
        guard !eligible.isEmpty else {
            if toleratesMiss { pending.removeAll { time - $0.time > maximumInterval } }
            else { pending.removeAll() }
            return nil
        }

        pending.removeAll { time - $0.time > maximumInterval }
        var next: [Observation] = []
        var used = Set<Int>()

        for previous in pending {
            let projected = projectedBox(previous, into: camera)
            guard let best = eligible.enumerated()
                .filter({ !used.contains($0.offset) })
                .min(by: { distance($0.element.candidate.box, projected) < distance($1.element.candidate.box, projected) }),
                  distance(best.element.candidate.box, projected) <= continuityLimit(projected, candidate: best.element.candidate.box) else {
                continue
            }
            used.insert(best.offset)
            // A detector may be asked twice for the same source frame while a
            // focused crop is retried. Do not let that create fake temporal
            // support.
            guard time - previous.time >= 0.04 else {
                next.append(previous)
                continue
            }
            next.append(.init(time: time, match: best.element, camera: camera,
                              confirmations: previous.confirmations + 1,
                              score: previous.score * 0.55 + best.element.score * 0.45,
                              samples: Array((previous.samples.filter { time - $0.time <= 0.5 } +
                                  [.init(time: time, box: best.element.candidate.box)]).suffix(12))))
        }

        for (index, match) in eligible.enumerated() where !used.contains(index) {
            next.append(.init(time: time, match: match, camera: camera,
                              confirmations: 1, score: match.score,
                              samples: [.init(time: time, box: match.candidate.box)]))
        }

        // Do not let multiple detector boxes for the same body consume the
        // hypothesis budget.
        next.sort {
            if $0.confirmations != $1.confirmations { return $0.confirmations > $1.confirmations }
            return $0.score > $1.score
        }
        var unique: [Observation] = []
        for candidate in next where !unique.contains(where: {
            let width = max(PlayerTrackingLimits.minimumGateWidth,
                            max($0.match.candidate.box.width, candidate.match.candidate.box.width))
            let height = max(PlayerTrackingLimits.minimumGateHeight,
                             max($0.match.candidate.box.height, candidate.match.candidate.box.height))
            return distance($0.match.candidate.box, candidate.match.candidate.box) <=
                hypot(width * 0.15, height * 0.15)
        }) {
            unique.append(candidate)
            if unique.count == Self.maximumHypotheses { break }
        }
        pending = unique

        guard let best = pending.first(where: { $0.confirmations >= requiredObservations }) else { return nil }
        let rival = pending.dropFirst().first {
            $0.confirmations >= min(2, best.confirmations)
        }
        guard rival == nil || best.score - rival!.score >= Self.decisionMargin else { return nil }
        confirmedSamples = best.samples
        pending.removeAll()
        return best.match
    }

    mutating func reset() { pending.removeAll(); confirmedSamples.removeAll() }

    /// Compatibility helper for callers and tests that only have one gated
    /// candidate, such as the present-anywhere recovery path.
    mutating func accept(_ box: CGRect?, at time: Double, camera: CameraTransform? = nil,
                         requiredObservations: Int = 2, maximumInterval: Double = 0.3) -> Bool {
        guard let box else { reset(); return false }
        let candidate = PlayerIdentityAssociation.Candidate(box: box, jersey: nil)
        let match = PlayerIdentityAssociation.Match(candidate: candidate, score: 1)
        return accept([match], at: time, camera: camera,
                      requiredObservations: requiredObservations,
                      maximumInterval: maximumInterval) != nil
    }

    private func projectedBox(_ observation: Observation, into camera: CameraTransform?) -> CGRect {
        let box = observation.match.candidate.box
        guard let camera, let old = observation.camera,
              abs(old.matrix.determinant) > 0.00001,
              let feet = CameraTransform(camera.matrix * old.matrix.inverse)
                .point(.init(x: box.midX, y: box.maxY)) else { return box }
        return box.offsetBy(dx: feet.x - box.midX, dy: feet.y - box.maxY)
    }

    private func distance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        hypot(lhs.midX - rhs.midX, lhs.maxY - rhs.maxY)
    }

    private func continuityLimit(_ expected: CGRect, candidate: CGRect) -> CGFloat {
        let width = max(PlayerTrackingLimits.minimumGateWidth, max(expected.width, candidate.width))
        let height = max(PlayerTrackingLimits.minimumGateHeight, max(expected.height, candidate.height))
        return hypot(width * 1.6, height * 0.9)
    }
}
