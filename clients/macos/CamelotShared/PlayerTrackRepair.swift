import CoreGraphics
import Foundation

/// Require sustained agreement before handing an earlier repair back to saved
/// tracking. One crossing or a single matching detection is not enough.
struct PlayerTrackRejoinConfirmation {
    let start: Double
    private var matchingSince: Double?
    private var previousTime: Double?

    init(start: Double) { self.start = start }

    mutating func reset() { matchingSince = nil; previousTime = nil }

    mutating func accept(_ box: CGRect, at time: Double, saved: PlayerMotion) -> Bool {
        guard time >= start + 0.5, let old = saved.box(at: time),
              PlayerTracker.overlap(old, box) >= 0.65,
              abs(old.maxY - box.maxY) <= max(0.003, old.height * 0.15) else {
            reset(); return false
        }
        if let previousTime, time - previousTime > 0.15 { matchingSince = nil }
        if matchingSince == nil { matchingSince = time }
        previousTime = time
        return time - (matchingSince ?? time) >= 0.35
    }
}

enum PlayerTrackingSearch {
    /// A square-ish image crop keeps useful context around a small player.
    /// Clamping its centre, not just intersecting, preserves scale at the edges.
    static func region(around box: CGRect) -> CGRect? {
        guard box.width > 0, box.height > 0, box.midX.isFinite, box.midY.isFinite,
              box.intersects(CGRect(x: -0.1, y: -0.1, width: 1.2, height: 1.2)) else { return nil }
        let width = min(1, max(0.18, box.width * 8))
        let height = min(1, max(0.28, box.height * 5))
        return CGRect(x: min(1 - width, max(0, box.midX - width / 2)),
                      y: min(1 - height, max(0, box.midY - height / 2)), width: width, height: height)
    }
}

extension PlayerMotion {
    /// Overhead graphics need a steadier scale than the detector's changing
    /// head/leg extent. Average nearby complete bodies without delaying position
    /// or blending across a correction/absence. Raw tracking stays untouched.
    func overheadHeight(at time: Double) -> CGFloat? {
        guard let body = effectBodyBox(at: time) else { return nil }
        let radius = 0.8
        var low = 0, high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].time < time - radius { low = middle + 1 } else { high = middle }
        }
        let nearby = samples[low..<min(samples.count, low + 240)].filter { sample in
            let box = sample.box, range = min(time, sample.time)...max(time, sample.time)
            return abs(sample.time - time) < radius && box.minX > 0.012 && box.maxX < 0.988 &&
                box.minY > 0.025 && box.maxY < 1 - max(0.025, box.height * 0.2) &&
                (lostAt.map { sample.time < $0 } ?? true) &&
                !(gaps?.contains { $0.overlaps(range) } ?? false) &&
                !(correctionTimes?.contains { $0 > range.lowerBound && $0 <= range.upperBound } ?? false)
        }
        guard !nearby.isEmpty else { return body.height }
        let heights = nearby.map { $0.box.height }.sorted(), median = heights[heights.count / 2]
        var sum = 0.0, weight = 0.0
        for sample in nearby {
            let w = pow(1 - abs(sample.time - time) / radius, 2)
            // Limit one bad detection's influence without freezing perspective.
            sum += w * min(median * 1.2, max(median * 0.8, sample.box.height)); weight += w
        }
        return weight > 0 ? sum / weight : body.height
    }

    /// The visible detector rectangle is not the full body at an image edge.
    /// Keep a recent complete-body scale for effects; never move the feet onto
    /// the crop boundary or feed this inferred extent back into identity tracking.
    func effectBodyBox(at time: Double) -> CGRect? {
        guard let current = box(at: time) else { return nil }
        var low = 0, high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        let index = max(0, low - 1), raw = samples[index].box
        func complete(_ box: CGRect) -> Bool {
            box.minX > 0.012 && box.maxX < 0.988 && box.minY > 0.025 && box.maxY < 1 - max(0.025, box.height * 0.2)
        }
        let recent = samples[max(0, index - 90)...index].filter { sample in
            sample.time >= time - 2 && complete(sample.box) &&
            !(gaps?.contains { $0.overlaps(sample.time...max(time, sample.time)) } ?? false) &&
            !(correctionTimes?.contains { $0 > sample.time && $0 <= time } ?? false)
        }
        let ratios = recent.map { $0.box.width / max(0.001, $0.box.height) }.sorted()
        let anchor = reference.flatMap { complete($0) ? $0 : nil }
        let ratio = anchor.map { $0.width / max(0.001, $0.height) } ?? (ratios.isEmpty ? current.width / max(0.001, current.height) : ratios[ratios.count / 2])
        if complete(raw) {
            let width = current.height * ratio
            return CGRect(x: current.midX - width / 2, y: current.minY, width: width, height: current.height)
        }
        // A partial seed alone cannot tell us where the hidden feet are.
        guard !recent.isEmpty else { return nil }
        let heights = recent.map { $0.box.height }.sorted(), widths = recent.map { $0.box.width }.sorted()
        let fullHeight = heights[Int(Double(heights.count - 1) * 0.75)]
        let fullWidth = widths[widths.count / 2]
        let horizontalCrop = raw.minX <= 0.012 || raw.maxX >= 0.988
        let verticalCrop = raw.minY <= 0.025 || raw.maxY >= 1 - max(0.025, raw.height * 0.2)
        let scale = horizontalCrop ? 1 : min(1.2, max(0.9, current.width / max(0.001, fullWidth)))
        let height = verticalCrop ? max(current.height, fullHeight * scale) : current.height
        let width = height * ratio
        let centerX = raw.minX <= 0.012 ? current.maxX - width / 2 : raw.maxX >= 0.988 ? current.minX + width / 2 : current.midX
        let top = raw.minY <= 0.025 ? current.maxY - height : current.minY
        return CGRect(x: centerX - width / 2, y: top, width: width, height: height)
    }

    /// A separate floor contact estimate keeps body-box wobble out of rings and
    /// beams. Fit local motion, then use its lower-foot envelope; a running stride
    /// must not pull the ground effect up with the lifted foot. No extrapolation
    /// across missing tracking, and no claim of metric calibration without a plane.
    func groundPoint(at time: Double) -> CGPoint? {
        guard let current = effectBodyBox(at: time) else { return nil }
        if current.maxY >= 0.985 || current.minY <= 0.012 || current.minX <= 0.012 || current.maxX >= 0.988 {
            return CGPoint(x: current.midX, y: current.maxY)
        }
        let radius = 0.18
        var lower = 0, upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].time < time - radius { lower = middle + 1 } else { upper = middle }
        }
        let nearby = samples[lower..<min(samples.count, lower + 64)].filter { sample in
            abs(sample.time - time) <= radius &&
            (lostAt.map { sample.time < $0 } ?? true) &&
            !(gaps?.contains { $0.overlaps(min(time, sample.time)...max(time, sample.time)) } ?? false) &&
            !(correctionTimes?.contains { $0 > min(time, sample.time) && $0 <= max(time, sample.time) } ?? false)
        }
        guard nearby.count >= 3 else { return CGPoint(x: current.midX, y: current.maxY) }
        let meanTime = nearby.map(\.time).reduce(0, +) / Double(nearby.count)
        let meanY = nearby.map { $0.box.maxY }.reduce(0, +) / Double(nearby.count)
        let denominator = nearby.reduce(0.0) { $0 + pow($1.time - meanTime, 2) }
        guard denominator > 0.00001 else { return CGPoint(x: current.midX, y: current.maxY) }
        let slope = nearby.reduce(0.0) { $0 + ($1.time - meanTime) * ($1.box.maxY - meanY) } / denominator
        let intercepts = nearby.map { $0.box.maxY - slope * ($0.time - time) }.sorted()
        let footY = intercepts[min(intercepts.count - 1, Int(Double(intercepts.count - 1) * 0.75))]
        // Outlier detector boxes cannot push an indicator far below the player.
        let adjustment = min(current.height * 0.08, max(-current.height * 0.04, footY - current.maxY))
        return CGPoint(x: current.midX, y: current.maxY + adjustment)
    }
}
