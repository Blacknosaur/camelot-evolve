import CoreGraphics
import CoreVideo
import Vision

/// One person's skeleton, in display coordinates (normalised, top-left origin).
///
/// Two things here are worth more than the skeleton itself.
///
/// The **ground point** is where the player actually touches the grass. Effects
/// are anchored to the bottom of the detector box, which is only the same thing
/// when the player is upright and the box is tight — not when they lean into a
/// turn, jump, or the box has grown during fast motion. Ankles say where the
/// feet are regardless.
///
/// The **torso** is the band between shoulders and hips. Kit colour is currently
/// read from a fixed slice of the box (30–70 % across, 20–48 % down), which
/// drifts onto grass and neighbours as the box loosens. Sampling the real torso
/// is what makes the kit signature describe the shirt rather than its
/// surroundings, and identity is only as good as that signature.
struct PlayerPose: Sendable {
    /// Ankle midpoint, or the single visible ankle. Nil when neither is seen.
    let ground: CGPoint?
    /// Shoulders to hips, in display coordinates.
    let torso: CGRect?
    /// Hips to knees.
    let shorts: CGRect?
    /// Whole-body extent of the confident joints, for matching to a box.
    let extent: CGRect
    /// Nose-to-ankle distance. Kit-independent, so unlike colour it can tell
    /// team-mates apart — noisy on a distant player, meaningful on a near one.
    let stature: CGFloat?

    /// Joints below this are treated as not seen.
    static let minimumConfidence: Float = 0.3
}

/// Runs body-pose detection and matches skeletons to player boxes.
///
/// **It gives up on footage where pose finds nobody.** Measured on the May 11
/// stress clip: `VNDetectHumanBodyPoseRequest` returned *zero* observations over
/// 160 detected players, including the 18 that were more than a tenth of the
/// frame tall — not low-confidence joints, nothing at all. Like the built-in
/// segmenters and the text recogniser, it is built for a subject close to the
/// camera, and a 170 px player on a wide pitch is not one.
///
/// So the reader keeps its own counsel: it costs about 17 ms a frame, and after
/// a run of empty frames it stops asking. Footage shot closer, or a zoomed clip,
/// still gets the benefit; footage like this stops paying for nothing.
final class PlayerPoseReader {
    private let request = VNDetectHumanBodyPoseRequest()
    private var emptyFrames = 0
    /// Consecutive empty frames before this source is written off.
    static let giveUpAfter = 12
    private(set) var hasGivenUp = false

    /// Every skeleton in the frame, or nothing once this source has been
    /// written off.
    func poses(in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [PlayerPose] {
        guard !hasGivenUp else { return [] }
        guard (try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation).perform([request])) != nil,
              let results = request.results, !results.isEmpty else {
            emptyFrames += 1
            if emptyFrames >= Self.giveUpAfter { hasGivenUp = true }
            return []
        }
        emptyFrames = 0
        return results.compactMap { Self.pose(from: $0) }
    }

    /// The skeleton belonging to `box`: the one whose joints sit inside it.
    ///
    /// Matching on containment rather than on extent overlap matters, because a
    /// box that has grown over a neighbour still contains its own player's
    /// joints, and the neighbour's skeleton would win an overlap test.
    static func match(_ box: CGRect, among poses: [PlayerPose]) -> PlayerPose? {
        var best: (pose: PlayerPose, score: CGFloat)?
        for pose in poses {
            let overlap = PlayerTracker.overlap(pose.extent, box)
            guard overlap > 0.2 else { continue }
            // Prefer the skeleton whose centre is nearest the box centre; two
            // players sharing a box are separated by where their joints sit.
            let offset = hypot(pose.extent.midX - box.midX, pose.extent.midY - box.midY)
            let score = overlap - offset
            if score > (best?.score ?? -.greatestFiniteMagnitude) { best = (pose, score) }
        }
        return best?.pose
    }

    private static func pose(from observation: VNHumanBodyPoseObservation) -> PlayerPose? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        func joint(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let point = points[name], point.confidence >= PlayerPose.minimumConfidence else { return nil }
            // Vision reports a lower-left origin; the app works in top-left.
            return CGPoint(x: point.location.x, y: 1 - point.location.y)
        }
        func midpoint(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
            switch (a, b) {
            case let (first?, second?): CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
            case let (first?, nil): first
            case let (nil, second?): second
            default: nil
            }
        }
        func band(_ top: CGPoint?, _ bottom: CGPoint?, width reference: CGFloat) -> CGRect? {
            guard let top, let bottom, bottom.y > top.y else { return nil }
            // Keep the band narrower than the shoulders: the edges of a torso
            // are where the background shows between arm and body.
            let half = max(0.004, reference * 0.32)
            return CGRect(x: (top.x + bottom.x) / 2 - half, y: top.y,
                          width: half * 2, height: bottom.y - top.y)
        }

        let shoulders = midpoint(joint(.leftShoulder), joint(.rightShoulder))
        let hips = midpoint(joint(.leftHip), joint(.rightHip))
        let knees = midpoint(joint(.leftKnee), joint(.rightKnee))
        let ankles = midpoint(joint(.leftAnkle), joint(.rightAnkle))

        var shoulderWidth: CGFloat = 0
        if let left = joint(.leftShoulder), let right = joint(.rightShoulder) {
            shoulderWidth = abs(left.x - right.x)
        }
        let reference = max(shoulderWidth, 0.01)

        let all = [joint(.nose), joint(.leftShoulder), joint(.rightShoulder), joint(.leftElbow),
                   joint(.rightElbow), joint(.leftWrist), joint(.rightWrist), joint(.leftHip),
                   joint(.rightHip), joint(.leftKnee), joint(.rightKnee), joint(.leftAnkle),
                   joint(.rightAnkle), joint(.neck), joint(.root)].compactMap { $0 }
        guard all.count >= 4 else { return nil }
        let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!
        let minY = all.map(\.y).min()!, maxY = all.map(\.y).max()!
        guard maxX > minX, maxY > minY else { return nil }

        var stature: CGFloat?
        if let head = joint(.nose) ?? joint(.neck), let ankles { stature = ankles.y - head.y }

        return PlayerPose(
            ground: ankles,
            torso: band(shoulders, hips, width: reference),
            shorts: band(hips, knees, width: reference),
            extent: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            stature: stature.map { max(0, $0) })
    }
}

extension PlayerPose {
    /// The player's box with its foot line moved onto the real ground contact.
    ///
    /// Only the bottom edge moves, and only a little: a pose that disagrees
    /// wildly with the box is a skeleton from another body, not a correction.
    /// Everything downstream — ring, spotlight, trajectory — anchors to the
    /// bottom of this box, so this is where foot accuracy actually lands.
    func grounding(_ box: CGRect, tolerance: CGFloat = 0.25) -> CGRect {
        guard let ground, box.height > 0 else { return box }
        let shift = ground.y - box.maxY
        guard abs(shift) <= box.height * tolerance else { return box }
        let corrected = box.height + shift
        guard corrected > box.height * 0.5 else { return box }
        return CGRect(x: box.minX, y: box.minY, width: box.width, height: corrected)
    }
}
