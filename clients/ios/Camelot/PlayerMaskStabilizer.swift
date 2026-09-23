import CoreGraphics
import Foundation

/// A silhouette in a form that can be compared and blended frame to frame.
///
/// Two silhouettes traced from two frames have no vertex correspondence — a
/// different number of rows, at different heights, around a body that has moved.
/// Averaging them directly is meaningless. This resamples a shape to a fixed
/// number of rows expressed *relative to the player's box*, which does two jobs
/// at once: it gives every vertex a partner, and it removes the player's motion
/// and scale change, so what is left to compare is the shape itself.
///
/// That box-relative framing is also the "motion prediction / local warp" step:
/// re-anchoring last frame's profile to this frame's box already carries the
/// shape along with the player, without any optical flow.
struct PlayerBodyProfile: Equatable, Sendable {
    /// Left and right body edge per row, as fractions of the box width.
    /// Rows run top to bottom of the box. NaN marks a row with no body.
    private(set) var rows: [SIMD2<Float>]

    static let rowCount = 24

    init(rows: [SIMD2<Float>]) { self.rows = rows }

    /// Resample a traced silhouette into the canonical profile.
    init?(_ silhouette: PlayerSilhouette, box: CGRect) {
        guard box.width > 0, box.height > 0, silhouette.points.count >= 6 else { return nil }
        // The trace is a closed loop: left edge downwards, then right edge back
        // up. Splitting it in half recovers the two edges.
        let count = silhouette.points.count / 2
        guard count >= 3, count % 2 == 0 else { return nil }
        let half = count / 2
        var left: [(y: Float, x: Float)] = [], right: [(y: Float, x: Float)] = []
        for index in 0..<count {
            let x = silhouette.points[index * 2], y = silhouette.points[index * 2 + 1]
            if index < half { left.append((y, x)) } else { right.append((y, x)) }
        }
        guard let top = left.first?.y, let bottom = left.last?.y, bottom > top else { return nil }

        var rows = [SIMD2<Float>](repeating: SIMD2(.nan, .nan), count: Self.rowCount)
        let originX = Float(box.minX), width = Float(box.width)
        for index in 0..<Self.rowCount {
            let y = top + (bottom - top) * (Float(index) + 0.5) / Float(Self.rowCount)
            guard let l = Self.interpolate(left, at: y), let r = Self.interpolate(right, at: y) else { continue }
            rows[index] = SIMD2((l - originX) / width, (r - originX) / width)
        }
        guard rows.contains(where: { !$0.x.isNaN }) else { return nil }
        self.rows = rows
    }

    /// Edge position at a height, from a monotonically ordered edge trace.
    private static func interpolate(_ edge: [(y: Float, x: Float)], at y: Float) -> Float? {
        guard !edge.isEmpty else { return nil }
        let ordered = edge.sorted { $0.y < $1.y }
        if y <= ordered[0].y { return ordered[0].x }
        if y >= ordered[ordered.count - 1].y { return ordered[ordered.count - 1].x }
        for index in 1..<ordered.count where ordered[index].y >= y {
            let a = ordered[index - 1], b = ordered[index]
            let span = b.y - a.y
            guard span > 0 else { return a.x }
            let t = (y - a.y) / span
            return a.x + (b.x - a.x) * t
        }
        return ordered.last?.x
    }

    /// Blend towards `other`, per row. Rows present in only one profile are
    /// taken from whichever has them: a limb the model found this frame should
    /// not be averaged away against a row that never existed.
    func blended(with other: PlayerBodyProfile, weight: Float) -> PlayerBodyProfile {
        let t = min(1, max(0, weight))
        var merged = rows
        for index in 0..<min(rows.count, other.rows.count) {
            let mine = rows[index], theirs = other.rows[index]
            if mine.x.isNaN { merged[index] = theirs }
            else if theirs.x.isNaN { merged[index] = mine }
            else { merged[index] = mine + (theirs - mine) * t }
        }
        return PlayerBodyProfile(rows: merged)
    }

    /// Back to a drawable silhouette, anchored to a box. Passing this frame's
    /// box is what carries a previous profile onto the player's new position.
    func silhouette(in box: CGRect) -> PlayerSilhouette? {
        guard box.width > 0, box.height > 0 else { return nil }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for (index, row) in rows.enumerated() where !row.x.isNaN {
            let y = box.minY + box.height * (CGFloat(index) + 0.5) / CGFloat(rows.count)
            left.append(CGPoint(x: box.minX + CGFloat(row.x) * box.width, y: y))
            right.append(CGPoint(x: box.minX + CGFloat(row.y) * box.width, y: y))
        }
        guard left.count >= 3 else { return nil }
        return PlayerSilhouette(left + right.reversed())
    }

    /// How alike two shapes are, 0–1, ignoring position and scale. Used to catch
    /// a mask that has jumped to a differently shaped body.
    func similarity(to other: PlayerBodyProfile) -> Float {
        var total: Float = 0, counted = 0
        for index in 0..<min(rows.count, other.rows.count) {
            let mine = rows[index], theirs = other.rows[index]
            guard !mine.x.isNaN, !theirs.x.isNaN else { continue }
            let overlap = max(0, min(mine.y, theirs.y) - max(mine.x, theirs.x))
            let union = max(mine.y, theirs.y) - min(mine.x, theirs.x)
            guard union > 0 else { continue }
            total += overlap / union
            counted += 1
        }
        return counted > 0 ? total / Float(counted) : 0
    }
}

/// Confidence-weighted temporal smoothing of the player's mask.
///
/// A video segmenter's edges jitter frame to frame even when it is right, and
/// when it is unsure the mask can collapse or bleed onto a neighbour. Both look
/// bad and both mislead. The rule is the spec's: trust the network when it is
/// confident, and fall back on the shape carried forward from the last frame we
/// did trust when it is not.
struct PlayerMaskStabilizer: Sendable {
    /// The last shape confident enough to keep.
    private var held: PlayerBodyProfile?
    /// Weight given to a new mask at full confidence. Below 1 so that even a
    /// certain frame is smoothed a little; edge jitter is visible at 1.
    nonisolated(unsafe) static var maximumTrust: Float = 0.7
    /// Weight at the usable threshold. Low, because an uncertain frame during a
    /// crossing is exactly when the mask tries to grow onto someone else.
    nonisolated(unsafe) static var minimumTrust: Float = 0.15
    /// A shape this unlike the held one is rejected outright rather than blended
    /// — a sudden change of body shape is a mask that has changed player.
    nonisolated(unsafe) static var minimumShapeSimilarity: Float = 0.35

    /// Combine this frame's mask with the shape carried forward.
    ///
    /// Returns nil only when there is nothing to draw at all. A nil `measured`
    /// (the model produced nothing this frame) still yields the carried shape,
    /// which is what keeps a player visible through a blink of occlusion.
    mutating func stabilize(measured: PlayerSilhouette?, box: CGRect, confidence: Float,
                            state: PlayerTrackingState) -> PlayerSilhouette? {
        // While the player is occluded the shape is frozen along with identity:
        // whatever the model says about pixels it cannot see is not evidence.
        guard state.producesMask else { return held?.silhouette(in: box) }

        guard let measured, let fresh = PlayerBodyProfile(measured, box: box) else {
            return held?.silhouette(in: box)
        }
        guard var carried = held else {
            held = fresh
            return measured
        }
        // Shape similarity is scale- and position-free, so this asks "is this
        // the same body", not "has the player moved".
        if carried.similarity(to: fresh) < Self.minimumShapeSimilarity, confidence < PlayerTrackConfidence.certain {
            return carried.silhouette(in: box)
        }
        let span = max(0.0001, PlayerTrackConfidence.certain - PlayerTrackConfidence.usable)
        let scaled = (confidence - PlayerTrackConfidence.usable) / span
        let trust = Self.minimumTrust + (Self.maximumTrust - Self.minimumTrust) * min(1, max(0, scaled))
        carried = carried.blended(with: fresh, weight: trust)
        held = carried
        return carried.silhouette(in: box)
    }

    /// Forget the carried shape: after a reacquisition the old body is no longer
    /// a reference, and blending towards it would drag the new mask backwards.
    mutating func reset() { held = nil }
}
