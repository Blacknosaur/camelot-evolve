import CoreGraphics
import Foundation

/// Source-frame navigation for manual review. The clip's Out time is exclusive.
struct PlayerFrameReview {
    let range: ClosedRange<Double>
    let frameRate: Double
    static let selectionDragDistance: CGFloat = 12

    private var rate: Double { frameRate.isFinite && frameRate > 0 ? frameRate : 30 }

    func next(after time: Double) -> Double? {
        let next = (floor(time * rate + 0.0001) + 1) / rate
        return next < range.upperBound - 0.0001 ? max(range.lowerBound, next) : nil
    }

    func previous(before time: Double) -> Double? {
        guard time > range.lowerBound + 0.0001 else { return nil }
        return max(range.lowerBound, (ceil(time * rate - 0.0001) - 1) / rate)
    }
}



enum PlayerTrackingSearch {
    static func recoveryInterval(confirming: Bool, exited: Bool, dormant: Bool) -> Double {
        confirming ? 0.06 : exited ? 0.1 : dormant ? 0.4 : 0.12
    }

    /// A candidate cannot explain its own relocation: cameraPosition must come
    /// from registering the last trusted image, never from a pending match.
    static func allowsReturn(_ box: CGRect, through side: PlayerExitSide?,
                             cameraPosition: CGRect?, strongIdentity: Bool, exitPosition: CGRect? = nil) -> Bool {
        guard let side else { return true }
        if side.isNearEdge(box), exitPosition.map({ edgeRegion(side, near: $0).contains(CGPoint(x: box.midX, y: box.midY)) }) ?? true { return true }
        guard strongIdentity, let cameraPosition, !side.isNearEdge(cameraPosition) else { return false }
        return abs(box.midX - cameraPosition.midX) <= max(0.06, cameraPosition.width * 2) &&
            abs(box.maxY - cameraPosition.maxY) <= max(0.06, cameraPosition.height * 0.6)
    }

    /// Search the remembered image exit as well as the camera-warped prediction.
    /// The player can re-enter at the edge while that prediction follows the pitch.
    static func edgeRegion(_ side: PlayerExitSide, near box: CGRect) -> CGRect {
        switch side {
        case .left: CGRect(x: 0, y: min(0.5, max(0, box.midY - 0.25)), width: 0.3, height: 0.5)
        case .right: CGRect(x: 0.7, y: min(0.5, max(0, box.midY - 0.25)), width: 0.3, height: 0.5)
        case .top: CGRect(x: min(0.5, max(0, box.midX - 0.25)), y: 0, width: 0.5, height: 0.35)
        case .bottom: CGRect(x: min(0.5, max(0, box.midX - 0.25)), y: 0.65, width: 0.5, height: 0.35)
        }
    }

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

/// Last trusted body moved by camera motion and a short player velocity.
/// The result is a search or occlusion position, never a saved measurement by itself.
enum PlayerSceneProjection {
    static func box(_ origin: CGRect, at time: Double, originTime: Double, camera: CameraTransform?, velocity: CGPoint?) -> CGRect? {
        guard origin.width > 0, origin.height > 0, time.isFinite, originTime.isFinite else { return nil }
        let dt = CGFloat(min(PlayerTrackingLimits.maximumPredictionSeconds, max(0, time - originTime)))
        let shifted = origin.offsetBy(dx: (velocity?.x ?? 0) * dt, dy: (velocity?.y ?? 0) * dt)
        guard let camera else { return shifted }
        guard let feet = camera.point(CGPoint(x: shifted.midX, y: shifted.maxY)) else { return nil }
        let moved = shifted.offsetBy(dx: feet.x - shifted.midX, dy: feet.y - shifted.maxY)
        guard moved.width > 0, moved.height > 0, moved.minX.isFinite, moved.minY.isFinite else { return nil }
        return moved
    }
}

/// Keep the marker on a player who is still partly in frame and partly hidden.
/// A body that has left the picture, or been hidden for more than a second,
/// stays unmarked until a real detection confirms it.
enum PlayerOcclusionHold {
    static let maximumSeconds = 1.0

    static func box(trusted: CGRect, trustedTime: Double, at time: Double, camera: CameraTransform?, velocity: CGPoint?, bodyStillVisible: Bool) -> CGRect? {
        guard bodyStillVisible, time >= trustedTime, time - trustedTime <= maximumSeconds,
              let moved = PlayerSceneProjection.box(trusted, at: time, originTime: trustedTime, camera: camera, velocity: velocity) else { return nil }
        let image = CGRect(x: 0, y: 0, width: 1, height: 1)
        let visible = moved.intersection(image)
        guard !visible.isNull, !visible.isInfinite,
              visible.width >= moved.width * 0.35, visible.height >= moved.height * 0.35 else { return nil }
        return moved
    }
}

/// A visible crop and a full-body estimate serve different purposes. Only the
/// visible rectangle is an observation; the estimate restores body proportions
/// for appearance sampling and association at image edges.
enum PlayerBodyExtent {
    static func isCropped(_ box: CGRect) -> Bool {
        box.minX <= 0.008 || box.maxX >= 0.992 || box.minY <= 0.008 || box.maxY >= 0.992
    }

    static func estimate(visible: CGRect, reference: CGRect, expected: CGRect? = nil) -> CGRect {
        guard reference.width > 0.003, reference.height > 0.008 else { return visible }

        // A detector can stop at the shirt hem, a few pixels before the image
        // boundary. Treat that as a lower-body crop only when the known body
        // proportions put the feet outside the image and much of the body is missing.
        // Width changes sharply as a runner turns side-on; a narrow shirt must
        // not shrink the full-body height while the feet are outside the image.
        let bodyHeight = reference.height * min(1.25, max(0.95, visible.width / reference.width))
        if visible.maxY >= 1 - bodyHeight * 0.25,
           visible.minY + bodyHeight > 0.985,
           visible.height < bodyHeight * 0.9 {
            return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: bodyHeight)
        }

        // The detector can return only the upper half of a player when an
        // opponent covers the legs. There is no frame edge to flag that case,
        // so use the last complete body as a scale prior and the visible head
        // (the current top edge) as the anchor. `expected` is only a gate: it
        // prevents a normal stride or a newly appearing small body from being
        // stretched into a full player.
        if let expected,
           !isCropped(visible),
           visible.height < reference.height * 0.78,
           visible.width >= reference.width * 0.55,
           visible.minY >= expected.minY - reference.height * 0.45,
           visible.minY <= expected.minY + reference.height * 0.35,
           visible.maxY < expected.maxY - reference.height * 0.16 {
            let scale = min(1.25, max(0.8, visible.width / reference.width))
            let width = max(visible.width, reference.width * scale)
            let height = max(visible.height, reference.height * scale)
            return CGRect(x: visible.midX - width / 2, y: visible.minY, width: width, height: height)
        }

        guard isCropped(visible) else { return visible }
        let horizontal = visible.minX <= 0.008 || visible.maxX >= 0.992
        let vertical = visible.minY <= 0.008 || visible.maxY >= 0.992
        let scale = horizontal ? (vertical ? 1 : visible.height / reference.height) : visible.width / reference.width
        let bounded = min(1.25, max(0.8, scale))
        let width = horizontal ? max(visible.width, reference.width * bounded) : visible.width
        let height = vertical ? max(visible.height, reference.height * bounded) : visible.height
        let x = visible.minX <= 0.008 ? visible.maxX - width : visible.minX
        let y = visible.minY <= 0.008 ? visible.maxY - height : visible.minY
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

extension PlayerMotion {
    /// Explicit redo owns this half-open source-time range, including manual
    /// picks. Identity and samples outside it survive. Unfinished frames stay
    /// missing if the new pass is stopped or fails.
    func clearingTracking(in range: ClosedRange<Double>) -> Self {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              range.upperBound > range.lowerBound else { return self }
        var result = self
        let contains: (Double) -> Bool = { $0 >= range.lowerBound && $0 < range.upperBound }
        result.samples.removeAll { contains($0.time) }
        result.anchors = anchors?.filter { !contains($0) }
        result.correctionTimes = correctionTimes?.filter { !contains($0) }
        result.inferred = nil
        var missing = gaps ?? []
        if let lostAt {
            let end = max(range.upperBound, (samples.last?.time ?? lostAt) + 0.12)
            if end >= lostAt { missing.append(lostAt...end) }
        }
        result.lostAt = nil
        missing.append(range.lowerBound...range.upperBound.nextDown)
        result.gaps = missing.sorted { $0.lowerBound < $1.lowerBound }
        result.hidesUncertainPositions = true
        return result
    }

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
            // Ignore gross outliers without clipping normal stride variation to
            // a median which may alternate between the high and low samples.
            guard sample.box.height >= median * 0.5, sample.box.height <= median * 1.5 else { continue }
            sum += w * sample.box.height; weight += w
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
        func usable(_ sample: PlayerMotionSample) -> Bool {
            let span = min(time, sample.time)...max(time, sample.time)
            return abs(sample.time - time) <= 2 && complete(sample.box) &&
                (lostAt.map { span.upperBound < $0 } ?? true) &&
                !(gaps?.contains { $0.overlaps(span) } ?? false) &&
                !(correctionTimes?.contains { $0 > span.lowerBound && $0 <= span.upperBound } ?? false)
        }
        var recent = samples[max(0, index - 90)...index].filter(usable)
        // Offline tracking can see a body become fully visible later. This
        // supports partial seeds and backward passes using the same identity
        // segment; no extent is borrowed across a correction or missing span.
        if recent.isEmpty {
            recent = samples[index..<min(samples.count, index + 91)].filter(usable)
        }
        let ratios = recent.map { $0.box.width / max(0.001, $0.box.height) }.sorted()
        let anchor = reference.flatMap { complete($0) ? $0 : nil }
        let ratio = anchor.map { $0.width / max(0.001, $0.height) } ?? (ratios.isEmpty ? current.width / max(0.001, current.height) : ratios[ratios.count / 2])
        // Tracking already stores inferred full-body extents outside the image.
        // A confirmed return can therefore be drawable without a new complete
        // sample in this segment. Do not mistake that estimate for an old box
        // clipped to the boundary and hide it after a gap.
        let hasEstimatedExtent = raw.minX < -0.001 || raw.minY < -0.001 || raw.maxX > 1.001 || raw.maxY > 1.001
        if (hasEstimatedExtent && recent.isEmpty) || complete(raw) || !PlayerPresence.leftFrame(raw) {
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

extension PlayerMotion {
    /// A missing frame needs a new pick. Never silently substitute a past/future frame.
    func trackingSeed(at time: Double) -> CGRect? { isMissing(at: time) ? nil : box(at: time) }

    /// An explicit fix invalidates the old automatic section up to the next
    /// manual boundary. Stopping/loss must not resurrect the wrong old player.
    func preparingCorrection(at start: Double, direction: PlayerTrackingDirection) -> Self {
        var result = self
        let lower = direction == .forward ? start : repairStart(from: start, to: -.infinity)
        let upper = direction == .forward ? repairEnd(from: start, to: .infinity) : start
        result.samples.removeAll { $0.time > lower && $0.time < upper }
        result.inferred = result.inferred?.filter { $0.time < lower || $0.time > upper }
        if direction == .forward, upper == .infinity { result.lostAt = start.nextUp }
        return result
    }
}


enum PlayerSelection {
    /// Prefer the body actually touched. A tiny neighbouring detection's padded
    /// target must not steal a tap inside the selected player's full body.
    static func box(at point: CGPoint, among boxes: [CGRect], aspectRatio: CGFloat) -> CGRect? {
        let direct = boxes.filter { $0.contains(point) }
        let candidates = direct.isEmpty ? boxes.filter { $0.insetBy(dx: -0.014, dy: -0.014).contains(point) } : direct
        return candidates.min {
            hypot(($0.midX - point.x) * aspectRatio, $0.midY - point.y) <
                hypot(($1.midX - point.x) * aspectRatio, $1.midY - point.y)
        }
    }
}
