import CoreGraphics
import Foundation

/// The region of the frame the segmentation model actually sees.
///
/// Running a whole 1080p pitch through a segmenter is both too slow and, as the
/// built-in Vision requests showed, useless: a 150 px player in a wide shot is
/// not a subject any general segmenter will volunteer. Cropping to the player
/// and upscaling makes the player large in the model's input, which is the whole
/// reason this type exists.
///
/// Padding is not decoration. It absorbs everything the bbox tracker gets wrong
/// between detections — fast running, camera pan, a box that has drifted onto
/// the shirt — so the body is still inside the crop when the model looks.
struct PlayerROI: Equatable, Sendable {
    /// The crop in display coordinates (normalised, top-left origin).
    let region: CGRect
    /// Square pixel size the crop is resampled to for the model.
    let pixelSize: Int

    /// Fraction of the box added around it, before velocity. The spec's 75–150%
    /// range; the lower end is used because velocity lead is added on top.
    nonisolated(unsafe) static var basePadding: CGFloat = 0.75
    /// How far ahead of the player the crop reaches, in seconds of their own
    /// motion. A player crossing the frame in a second must not leave the crop
    /// between one segmentation and the next.
    nonisolated(unsafe) static var velocityLead = 0.25
    /// Never let the crop grow past this share of the frame: past it the player
    /// is small in the model's input again and the crop has stopped helping.
    nonisolated(unsafe) static var maximumExtent: CGFloat = 0.6

    /// Build the region to segment for a player at `box`, moving at `velocity`
    /// (frame widths per second).
    ///
    /// The crop is square in *display* proportions so the resample to the
    /// model's square input does not stretch the player; a distorted body is a
    /// body the model has not been trained on.
    static func around(_ box: CGRect, velocity: CGPoint = .zero, aspect: CGFloat = 1,
                       pixelSize: Int = 384) -> PlayerROI {
        let lead = CGPoint(x: velocity.x * velocityLead, y: velocity.y * velocityLead)
        // Centre on where the player is going, not only where they were.
        let centre = CGPoint(x: box.midX + lead.x / 2, y: box.midY + lead.y / 2)
        // Square in display units means unequal normalised extents, because the
        // frame itself is not square.
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 1
        // Work in units of image height. A square crop in pixels has
        // normalized width = height / aspect, not height * aspect.
        let padded = max((box.width * (1 + basePadding) + abs(lead.x)) * aspect,
                         box.height * (1 + basePadding) + abs(lead.y))
        let height = min(maximumExtent, maximumExtent * aspect, max(0.02, padded))
        let width = height / aspect
        var region = CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
        // Slide, rather than shrink, at the edges: a player against the
        // touchline still deserves a full-sized crop.
        region.origin.x = min(max(0, region.minX), max(0, 1 - region.width))
        region.origin.y = min(max(0, region.minY), max(0, 1 - region.height))
        region = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return PlayerROI(region: region, pixelSize: pixelSize)
    }

    /// Does the crop still comfortably contain this box? A box pressed against
    /// the crop edge means the ROI is lagging the player and should be rebuilt
    /// before the next segmentation rather than after the track is lost.
    func comfortablyContains(_ box: CGRect, margin: CGFloat = 0.12) -> Bool {
        let inset = region.insetBy(dx: region.width * margin, dy: region.height * margin)
        return inset.contains(box)
    }

    /// A point inside the model's square input (0–1) back to display coordinates.
    func display(_ point: CGPoint) -> CGPoint {
        CGPoint(x: region.minX + point.x * region.width, y: region.minY + point.y * region.height)
    }

    /// A rect inside the model's square input (0–1) back to display coordinates.
    func display(_ rect: CGRect) -> CGRect {
        CGRect(x: region.minX + rect.minX * region.width, y: region.minY + rect.minY * region.height,
               width: rect.width * region.width, height: rect.height * region.height)
    }

    /// A display point into the model's input space. Outside 0–1 means the point
    /// is not in the crop at all, which callers must treat as unknown rather
    /// than as background.
    func local(_ point: CGPoint) -> CGPoint {
        guard region.width > 0, region.height > 0 else { return .zero }
        return CGPoint(x: (point.x - region.minX) / region.width, y: (point.y - region.minY) / region.height)
    }

    /// A display rect into the model's input space.
    func local(_ rect: CGRect) -> CGRect {
        guard region.width > 0, region.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - region.minX) / region.width, y: (rect.minY - region.minY) / region.height,
                      width: rect.width / region.width, height: rect.height / region.height)
    }
}
