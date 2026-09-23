import CoreGraphics
import Foundation
import simd

/// Effects keep following a player through short losses and can be placed by
/// hand where tracking never found them. Everything here is display-side:
/// the confirmed samples and the raw gaps remain the record of what was seen.
extension PlayerMotion {
    /// Merge a pass into a missing interval without replacing any existing
    /// source samples. This is intentionally different from `continuing` and
    /// `prepending`, which are used by the explicit Track actions and are
    /// allowed to replace the requested range.
    func filling(with partial: Self, in range: ClosedRange<Double>) -> Self {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              range.upperBound >= range.lowerBound else { return self }
        let tolerance = 1.0 / 600
        let additions = partial.samples.filter { sample in
            range.contains(sample.time) &&
            isMissing(at: sample.time) &&
            !samples.contains { abs($0.time - sample.time) < tolerance }
        }
        guard !additions.isEmpty else { return self }

        var result = self
        result.automaticallyInterpolatesTinyGaps = partial.automaticallyInterpolatesTinyGaps ?? automaticallyInterpolatesTinyGaps
        result.samples = (samples + additions).sorted { $0.time < $1.time }

        // Treat consecutive samples as covered spans. Preserve the remaining
        // edges of the original gap and re-add any loss intervals reported by
        // the fill pass itself.
        let ordered = additions.sorted { $0.time < $1.time }
        var covered: [ClosedRange<Double>] = []
        var start = ordered[0].time
        var end = start
        for sample in ordered.dropFirst() {
            if sample.time - end <= 0.2 {
                end = sample.time
            } else {
                covered.append(start...end)
                start = sample.time; end = sample.time
            }
        }
        covered.append(start...end)

        func subtract(_ gap: ClosedRange<Double>, by span: ClosedRange<Double>) -> [ClosedRange<Double>] {
            guard gap.overlaps(span) else { return [gap] }
            var pieces: [ClosedRange<Double>] = []
            if gap.lowerBound < span.lowerBound { pieces.append(gap.lowerBound...span.lowerBound.nextDown) }
            if gap.upperBound > span.upperBound { pieces.append(span.upperBound.nextUp...gap.upperBound) }
            return pieces
        }

        var intervals = (gaps ?? []).flatMap { gap in
            covered.reduce([gap]) { remaining, span in
                remaining.flatMap { subtract($0, by: span) }
            }
        }
        intervals += (partial.gaps ?? []).compactMap { gap in
            let lower = max(range.lowerBound, gap.lowerBound)
            let upper = min(range.upperBound, gap.upperBound)
            return lower <= upper ? lower...upper : nil
        }
        if let oldLoss = lostAt, let first = additions.first, first.time > oldLoss {
            intervals.append(oldLoss...first.time.nextDown)
        }
        result.gaps = intervals.isEmpty ? nil : intervals.sorted { $0.lowerBound < $1.lowerBound }
        let hasConfirmedFuture = samples.contains { sample in
            sample.time > range.upperBound && !isMissing(at: sample.time)
        }
        if hasConfirmedFuture {
            // A fill pass is allowed to fail inside the gap. Its temporary
            // terminal loss must not hide confirmed samples that already exist
            // after the gap.
            result.lostAt = lostAt
        } else if let partialLoss = partial.lostAt {
            result.lostAt = partialLoss
        } else if let oldLoss = lostAt,
                  additions.contains(where: { $0.time >= oldLoss }) {
            // The fill pass crossed the previous terminal loss and reached a
            // confirmed frame, so that loss is now an internal gap instead.
            result.lostAt = nil
        }
        result.recoveryCount = (recoveryCount ?? 0) + (partial.recoveryCount ?? 0)
        result.jerseyProfile = partial.jerseyProfile ?? jerseyProfile
        result.identity = partial.identity ?? identity
        result.engine = partial.engine ?? engine
        result.inferred = nil
        return result
    }

    /// The longest interval `bridged` will ever fill; each effect then limits
    /// display with its own `gapBridging`, without recomputing positions.
    static let maximumBridgeHorizon = 4.0
    static let maximumHoldSeconds = 1.0
    private static let inferredInterval = 1.0 / 12

    /// Raw untracked intervals inside `range`, including the untracked lead-in,
    /// every recorded gap and the tail after a loss or the last sample.
    func missingIntervals(in range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        guard let first = samples.first, let last = samples.last else { return [range] }
        var intervals: [ClosedRange<Double>] = []
        if first.time - range.lowerBound > 0.12 { intervals.append(range.lowerBound...first.time.nextDown) }
        for gap in gaps ?? [] where gap.upperBound >= range.lowerBound && gap.lowerBound <= range.upperBound {
            intervals.append(max(range.lowerBound, gap.lowerBound)...min(range.upperBound, gap.upperBound))
        }
        let tail = min(lostAt ?? .infinity, last.time)
        if range.upperBound - tail > 0.12 { intervals.append(max(range.lowerBound, tail.nextUp)...range.upperBound) }
        return intervals.sorted { $0.lowerBound < $1.lowerBound }
    }

    func nextMissing(after time: Double, in range: ClosedRange<Double>) -> Double? {
        missingIntervals(in: range).first { $0.lowerBound > time + 0.02 }?.lowerBound
    }

    func previousMissing(before time: Double, in range: ClosedRange<Double>) -> Double? {
        missingIntervals(in: range).last { $0.lowerBound < time - 0.02 }?.lowerBound
    }

    /// Insert a hand-placed position. Inside a gap the gap splits around it;
    /// after a terminal loss the loss becomes a gap up to the placement.
    mutating func place(_ box: CGRect, at time: Double) {
        // A 1/60 tolerance merges distinct hand selections on 60/120 fps video.
        let tolerance = 1.0 / 600
        if let index = samples.firstIndex(where: { abs($0.time - time) < tolerance }) {
            samples[index] = .init(time: time, box: box)
        } else {
            let index = samples.firstIndex { $0.time > time } ?? samples.count
            samples.insert(.init(time: time, box: box), at: index)
        }
        var intervals: [ClosedRange<Double>] = []
        for gap in gaps ?? [] {
            guard gap.contains(time) else { intervals.append(gap); continue }
            if gap.lowerBound < time - tolerance { intervals.append(gap.lowerBound...time.nextDown) }
            if gap.upperBound > time + tolerance { intervals.append(time.nextUp...gap.upperBound) }
        }
        if let lostAt, time >= lostAt {
            if let previous = samples.last(where: { $0.time < lostAt }), time - previous.time > tolerance {
                intervals.append(max(lostAt, previous.time.nextUp)...time.nextDown)
            }
            self.lostAt = nil
        } else {
            let neighbours = samples.filter { abs($0.time - time) >= tolerance }
            if let previous = neighbours.last(where: { $0.time < time }), time - previous.time > 0.12,
               !(intervals.contains { $0.contains(previous.time.nextUp) }) {
                intervals.append(previous.time.nextUp...time.nextDown)
            }
            if let next = neighbours.first(where: { $0.time > time }), next.time - time > 0.12,
               !(intervals.contains { $0.contains(next.time.nextDown) }) {
                intervals.append(time.nextUp...next.time.nextDown)
            }
        }
        gaps = intervals.isEmpty ? nil : intervals.sorted { $0.lowerBound < $1.lowerBound }
        var placed = (anchors ?? []).filter { abs($0 - time) >= tolerance }
        placed.append(time)
        anchors = placed.sorted()
        inferred = nil
    }

    /// Recompute display-only positions for missing intervals. With a clip
    /// camera track, the confirmed neighbours are carried through the camera
    /// motion first, so a bridged ring stays on the grass during a pan.
    func bridged(camera: AnnotationCameraMotion?) -> PlayerMotion {
        var result = self
        var filled: [PlayerMotionSample] = []
        func carried(_ sample: PlayerMotionSample, to time: Double) -> PlayerMotionSample? {
            guard let camera, let from = camera.transform(at: sample.time), let to = camera.transform(at: time),
                  abs(from.matrix.determinant) > 0.00001 else { return .init(time: time, box: sample.box) }
            let relative = CameraTransform(to.matrix * from.matrix.inverse)
            guard let feet = relative.point(.init(x: sample.box.midX, y: sample.box.maxY)),
                  abs(feet.x) < 3, abs(feet.y) < 3 else { return nil }
            return .init(time: time, box: CGRect(x: feet.x - sample.box.width / 2, y: feet.y - sample.box.height,
                                                 width: sample.box.width, height: sample.box.height))
        }
        for gap in gaps ?? [] {
            guard let a = samples.last(where: { $0.time < gap.lowerBound }),
                  let b = samples.first(where: { $0.time > gap.upperBound }),
                  b.time - a.time <= Self.maximumBridgeHorizon + 0.1,
                  lostAt.map({ b.time < $0 }) ?? true,
                  !(correctionTimes?.contains { $0 > a.time && $0 <= b.time } ?? false) else { continue }
            var time = a.time + Self.inferredInterval
            while time < b.time {
                if let fromA = carried(a, to: time), let fromB = carried(b, to: time) {
                    let t = CGFloat((time - a.time) / (b.time - a.time))
                    let width = fromA.box.width + (fromB.box.width - fromA.box.width) * t
                    let height = fromA.box.height + (fromB.box.height - fromA.box.height) * t
                    let x = fromA.box.midX + (fromB.box.midX - fromA.box.midX) * t
                    let y = fromA.box.maxY + (fromB.box.maxY - fromA.box.maxY) * t
                    filled.append(.init(time: time, box: CGRect(x: x - width / 2, y: y - height, width: width, height: height)))
                }
                time += Self.inferredInterval
            }
        }
        if let lostAt, let last = samples.last(where: { $0.time < lostAt }) {
            var time = last.time + Self.inferredInterval
            while time <= last.time + Self.maximumHoldSeconds + 0.001 {
                if let held = carried(last, to: time) { filled.append(held) }
                time += Self.inferredInterval
            }
        }
        result.inferred = filled.isEmpty ? nil : filled.sorted { $0.time < $1.time }
        return result
    }
}
