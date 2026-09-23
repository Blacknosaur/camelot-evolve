import CoreGraphics
import CoreVideo
import ImageIO
import Foundation

/// Pixel membership for one tracked body, in display coordinates (normalised,
/// top-left origin) — the same space player boxes and annotations use.
protocol PlayerPixelMask: Sendable {
    func contains(_ point: CGPoint) -> Bool
}

/// A tracked player's shape on one frame: what tracking v2 produces instead of
/// a rectangle.
///
/// Stored as flat x,y pairs in display coordinates, rounded to a thousandth of
/// the frame. It is a closed loop traced down the body's left edge and back up
/// its right, so it is compact and cheap to fill — at the cost of not hollowing
/// out the gap between a player's legs.
struct PlayerSilhouette: Codable, Equatable, Sendable {
    var points: [Float]

    init?(_ outline: [CGPoint]) {
        guard outline.count >= 6 else { return nil }
        points = outline.flatMap { point in
            [Float((point.x * 1000).rounded() / 1000), Float((point.y * 1000).rounded() / 1000)]
        }
    }

    /// The closed body path mapped into a view or video frame.
    func path(in frame: CGRect) -> CGPath? {
        guard points.count >= 6 else { return nil }
        let path = CGMutablePath()
        for index in stride(from: 0, to: points.count - 1, by: 2) {
            let point = CGPoint(x: frame.minX + CGFloat(points[index]) * frame.width,
                                y: frame.minY + CGFloat(points[index + 1]) * frame.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// One frame's answer from a segmentation model.
struct PlayerSegmentation: Sendable {
    /// The player's shape, in display coordinates.
    let silhouette: PlayerSilhouette?
    /// Box tightened to the mask, in display coordinates.
    let box: CGRect
    /// Predicted mask quality, 0–1. This is not an identity confidence and must
    /// never authorize a player association or overwrite body geometry.
    let confidence: Float
}

/// A model that segments one tracked player across frames.
///
/// The contract deliberately separates `begin` from `next`. `begin` is the only
/// place an object is identified — by the user's selection, or by a
/// reacquisition that has already passed the identity gates. `next` may only
/// continue what `begin` established; it is never given a chance to decide which
/// object it is looking at, because that decision belongs to the track manager.
protocol PlayerTemporalSegmenter: AnyObject {
    /// Does this implementation actually carry temporal memory between frames?
    ///
    /// This is not decoration. A per-frame segmenter prompted with the previous
    /// box produces plausible-looking masks while being blind to everything that
    /// makes video tracking work, and the difference is invisible in a single
    /// frame. Benchmarks and diagnostics report this so results from a per-frame
    /// stand-in are never mistaken for results from a real VOS.
    var carriesTemporalMemory: Bool { get }

    /// Identify the object to follow, from a box the user or the recovery search
    /// chose. Resets any memory the implementation holds.
    func begin(frame: CVPixelBuffer, orientation: CGImagePropertyOrientation,
               roi: PlayerROI, prompt: CGRect) throws -> PlayerSegmentation?

    /// Continue the established object into this frame.
    func next(frame: CVPixelBuffer, orientation: CGImagePropertyOrientation,
              roi: PlayerROI) throws -> PlayerSegmentation?

    /// Drop temporal state without forgetting which object was chosen. Used
    /// after an occlusion, where memory of the frames we could not see is worse
    /// than no memory at all.
    func forgetRecentMemory()
}
