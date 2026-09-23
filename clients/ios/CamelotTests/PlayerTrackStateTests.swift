import XCTest
@testable import Camelot

/// The occlusion and memory rules, tested exhaustively off-device.
///
/// These decide whether a track survives a crossing, and they are the one part
/// of the pipeline that can be checked without a model, a device or footage —
/// so they are checked properly here rather than inferred from a demo clip.
final class PlayerTrackStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PlayerTrackConfidence.certain = 0.90
        PlayerTrackConfidence.usable = 0.70
        PlayerTrackConfidence.occlusionPatience = 3
        PlayerTrackConfidence.searchHorizon = 2.5
    }

    func testOnlyConfidentFramesTeachIdentity() {
        var machine = PlayerTrackMachine(startingAt: 0)
        XCTAssertEqual(machine.advance(confidence: 0.95, at: 0.1), .learning)
        XCTAssertEqual(machine.state, .tracking)

        // The band that exists purely to stop memory poisoning: still following,
        // still adapting to pose, but not allowed near long-term identity.
        XCTAssertEqual(machine.advance(confidence: 0.80, at: 0.2), .adapting)
        XCTAssertEqual(machine.state, .partiallyOccluded)
        XCTAssertFalse(machine.advance(confidence: 0.80, at: 0.3).updatesIdentityMemory)

        XCTAssertEqual(machine.advance(confidence: 0.40, at: 0.4), .frozen)
    }

    func testOneBadFrameIsNoiseButARunIsAnOcclusion() {
        var machine = PlayerTrackMachine(startingAt: 0)
        machine.advance(confidence: 0.95, at: 0)
        machine.advance(confidence: 0.2, at: 0.1)
        XCTAssertEqual(machine.state, .partiallyOccluded, "a single bad frame must not declare an occlusion")
        machine.advance(confidence: 0.2, at: 0.2)
        XCTAssertEqual(machine.state, .partiallyOccluded)
        machine.advance(confidence: 0.2, at: 0.3)
        XCTAssertEqual(machine.state, .occluded, "sustained low confidence is an occlusion")
    }

    func testConfidenceRecoversStateAndResetsPatience() {
        var machine = PlayerTrackMachine(startingAt: 0)
        machine.advance(confidence: 0.2, at: 0.1)
        machine.advance(confidence: 0.2, at: 0.2)
        XCTAssertEqual(machine.advance(confidence: 0.97, at: 0.3), .learning)
        XCTAssertEqual(machine.state, .tracking)
        // Patience must have reset, or two more bad frames would occlude early.
        machine.advance(confidence: 0.2, at: 0.4)
        machine.advance(confidence: 0.2, at: 0.5)
        XCTAssertEqual(machine.state, .partiallyOccluded)
    }

    func testTrackIsLostOnlyAfterTheSearchHorizon() {
        var machine = PlayerTrackMachine(startingAt: 0)
        machine.advance(confidence: 0.95, at: 0)
        for step in 1...5 { machine.advance(confidence: 0.1, at: Double(step) * 0.1) }
        XCTAssertEqual(machine.state, .occluded, "still within the horizon")
        machine.search(at: 1.0)
        XCTAssertEqual(machine.state, .searching)
        machine.search(at: 3.0)
        XCTAssertEqual(machine.state, .lost, "past the horizon the track is abandoned")
        // A lost track stays lost: nothing but an explicit correction revives it.
        XCTAssertEqual(machine.advance(confidence: 0.99, at: 3.1), .frozen)
        XCTAssertEqual(machine.state, .lost)
    }

    func testReacquisitionNeverTeachesIdentity() {
        var machine = PlayerTrackMachine(startingAt: 0)
        machine.advance(confidence: 0.1, at: 0.1)
        machine.search(at: 0.5)
        let policy = machine.advance(confidence: 0.95, at: 1.0, reacquired: true)
        XCTAssertEqual(machine.state, .reacquired)
        XCTAssertTrue(policy.updatesWorkingMemory)
        XCTAssertFalse(policy.updatesIdentityMemory,
                       "a reacquisition is a hypothesis; learning from it makes a wrong match permanent")
    }

    func testUserCorrectionOutranksTheMachine() {
        var machine = PlayerTrackMachine(startingAt: 0)
        machine.search(at: 5)
        XCTAssertEqual(machine.state, .lost)
        machine.correct(at: 5)
        XCTAssertEqual(machine.state, .tracking)
        XCTAssertEqual(machine.advance(confidence: 0.95, at: 5.1), .learning)
    }

    func testOnlyFollowingStatesDrawAMask() {
        XCTAssertTrue(PlayerTrackingState.tracking.producesMask)
        XCTAssertTrue(PlayerTrackingState.partiallyOccluded.producesMask)
        XCTAssertTrue(PlayerTrackingState.reacquired.producesMask)
        XCTAssertFalse(PlayerTrackingState.occluded.producesMask, "never draw a body we cannot see")
        XCTAssertFalse(PlayerTrackingState.searching.producesMask)
        XCTAssertFalse(PlayerTrackingState.lost.producesMask)
    }
}

/// ROI geometry: the crop must lead the player, stay inside the frame and map
/// cleanly in both directions, or masks land in the wrong place.
final class PlayerROITests: XCTestCase {
    func testCropIsSquareInPixelsForLandscapeAndPortraitFootage() {
        for aspect: CGFloat in [16.0 / 9, 9.0 / 16, 2, 0.5] {
            let box = CGRect(x: 0.35, y: 0.4, width: 0.035, height: 0.12)
            let roi = PlayerROI.around(box, aspect: aspect)
            XCTAssertEqual(roi.region.width * aspect, roi.region.height, accuracy: 0.0001)
            XCTAssertTrue(roi.region.contains(box))
        }
    }

    override func setUp() {
        super.setUp()
        PlayerROI.basePadding = 0.75
        PlayerROI.velocityLead = 0.25
        PlayerROI.maximumExtent = 0.6
    }

    func testCropPadsAroundThePlayer() {
        let box = CGRect(x: 0.45, y: 0.45, width: 0.05, height: 0.12)
        let roi = PlayerROI.around(box)
        XCTAssertTrue(roi.region.contains(box), "the player must be inside their own crop")
        XCTAssertGreaterThan(roi.region.height, box.height * 1.5, "padding must actually pad")
    }

    func testCropLeadsPlayerMotion() {
        let box = CGRect(x: 0.45, y: 0.45, width: 0.05, height: 0.12)
        let still = PlayerROI.around(box)
        let running = PlayerROI.around(box, velocity: CGPoint(x: 0.6, y: 0))
        XCTAssertGreaterThan(running.region.midX, still.region.midX,
                             "the crop must reach ahead of a moving player, not trail them")
        XCTAssertTrue(running.region.contains(box))
    }

    func testCropSlidesRatherThanShrinksAtTheFrameEdge() {
        let box = CGRect(x: 0.005, y: 0.45, width: 0.05, height: 0.12)
        let middle = PlayerROI.around(CGRect(x: 0.45, y: 0.45, width: 0.05, height: 0.12))
        let edge = PlayerROI.around(box)
        XCTAssertEqual(edge.region.width, middle.region.width, accuracy: 0.001,
                       "a player on the touchline still deserves a full-sized crop")
        XCTAssertGreaterThanOrEqual(edge.region.minX, 0)
        XCTAssertLessThanOrEqual(edge.region.maxX, 1.0001)
    }

    func testCropIsBoundedSoThePlayerStaysLargeInTheModelInput() {
        let huge = CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.8)
        let roi = PlayerROI.around(huge)
        XCTAssertLessThanOrEqual(roi.region.height, PlayerROI.maximumExtent + 0.0001)
    }

    func testCoordinateRoundTrip() {
        let roi = PlayerROI.around(CGRect(x: 0.4, y: 0.4, width: 0.06, height: 0.15))
        let display = CGPoint(x: 0.42, y: 0.46)
        let round = roi.display(roi.local(display))
        XCTAssertEqual(round.x, display.x, accuracy: 0.0001)
        XCTAssertEqual(round.y, display.y, accuracy: 0.0001)
    }

    func testLaggingCropIsDetected() {
        let roi = PlayerROI.around(CGRect(x: 0.4, y: 0.4, width: 0.06, height: 0.15))
        XCTAssertTrue(roi.comfortablyContains(CGRect(x: 0.41, y: 0.41, width: 0.06, height: 0.15)))
        let escaping = CGRect(x: roi.region.maxX - 0.01, y: 0.41, width: 0.06, height: 0.15)
        XCTAssertFalse(roi.comfortablyContains(escaping), "a box at the crop edge means the ROI is lagging")
    }
}

/// Temporal stabilisation: the mask must be smoothed towards the carried shape
/// when the model is unsure, and frozen outright when the player is hidden.
final class PlayerMaskStabilizerTests: XCTestCase {
    private let box = CGRect(x: 0.4, y: 0.4, width: 0.08, height: 0.2)

    /// A simple upright body: constant width down the box.
    private func silhouette(left: CGFloat, right: CGFloat, in box: CGRect, rows: Int = 16) -> PlayerSilhouette {
        var lefts: [CGPoint] = [], rights: [CGPoint] = []
        for row in 0..<rows {
            let y = box.minY + box.height * (CGFloat(row) + 0.5) / CGFloat(rows)
            lefts.append(CGPoint(x: box.minX + box.width * left, y: y))
            rights.append(CGPoint(x: box.minX + box.width * right, y: y))
        }
        return PlayerSilhouette(lefts + rights.reversed())!
    }

    func testProfileIsPositionAndScaleFree() {
        let near = silhouette(left: 0.3, right: 0.7, in: box)
        let far = silhouette(left: 0.3, right: 0.7, in: CGRect(x: 0.1, y: 0.7, width: 0.04, height: 0.1))
        let a = PlayerBodyProfile(near, box: box)
        let b = PlayerBodyProfile(far, box: CGRect(x: 0.1, y: 0.7, width: 0.04, height: 0.1))
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertGreaterThan(a!.similarity(to: b!), 0.9,
                             "the same body shape at another position and scale is the same shape")
    }

    func testDifferentShapesAreNotSimilar() {
        let narrow = PlayerBodyProfile(silhouette(left: 0.45, right: 0.55, in: box), box: box)
        let wide = PlayerBodyProfile(silhouette(left: 0.05, right: 0.95, in: box), box: box)
        XCTAssertLessThan(narrow!.similarity(to: wide!), 0.35)
    }

    func testFirstMaskIsAcceptedUnchanged() {
        var stabilizer = PlayerMaskStabilizer()
        let first = silhouette(left: 0.3, right: 0.7, in: box)
        let result = stabilizer.stabilize(measured: first, box: box, confidence: 0.95, state: .tracking)
        XCTAssertEqual(result?.points, first.points)
    }

    func testLowConfidenceStaysNearerTheCarriedShape() {
        let held = silhouette(left: 0.3, right: 0.7, in: box)
        let jumped = silhouette(left: 0.1, right: 0.9, in: box)

        var confident = PlayerMaskStabilizer()
        _ = confident.stabilize(measured: held, box: box, confidence: 0.99, state: .tracking)
        let confidentResult = confident.stabilize(measured: jumped, box: box, confidence: 0.99, state: .tracking)

        var unsure = PlayerMaskStabilizer()
        _ = unsure.stabilize(measured: held, box: box, confidence: 0.99, state: .tracking)
        let unsureResult = unsure.stabilize(measured: jumped, box: box, confidence: 0.72, state: .partiallyOccluded)

        let heldProfile = PlayerBodyProfile(held, box: box)!
        let confidentShape = PlayerBodyProfile(confidentResult!, box: box)!
        let unsureShape = PlayerBodyProfile(unsureResult!, box: box)!
        XCTAssertGreaterThan(heldProfile.similarity(to: unsureShape), heldProfile.similarity(to: confidentShape),
                             "an unsure frame must move the mask less than a confident one")
    }

    func testHiddenPlayerFreezesTheShape() {
        var stabilizer = PlayerMaskStabilizer()
        let good = silhouette(left: 0.3, right: 0.7, in: box)
        _ = stabilizer.stabilize(measured: good, box: box, confidence: 0.95, state: .tracking)
        // Whatever the model claims about pixels it cannot see is not evidence.
        let nonsense = silhouette(left: 0.0, right: 1.0, in: box)
        let result = stabilizer.stabilize(measured: nonsense, box: box, confidence: 0.99, state: .occluded)
        let heldProfile = PlayerBodyProfile(good, box: box)!
        XCTAssertGreaterThan(heldProfile.similarity(to: PlayerBodyProfile(result!, box: box)!), 0.9)
    }

    func testMissingMaskKeepsThePlayerVisibleThroughABlink() {
        var stabilizer = PlayerMaskStabilizer()
        let good = silhouette(left: 0.3, right: 0.7, in: box)
        _ = stabilizer.stabilize(measured: good, box: box, confidence: 0.95, state: .tracking)
        let moved = box.offsetBy(dx: 0.03, dy: 0)
        let carried = stabilizer.stabilize(measured: nil, box: moved, confidence: 0.8, state: .partiallyOccluded)
        XCTAssertNotNil(carried, "one frame without a mask must not blank the player")
        // The carried shape follows the box, which is the motion compensation.
        let profile = PlayerBodyProfile(carried!, box: moved)!
        XCTAssertGreaterThan(PlayerBodyProfile(good, box: box)!.similarity(to: profile), 0.9)
    }

    func testResetForgetsTheOldBody() {
        var stabilizer = PlayerMaskStabilizer()
        _ = stabilizer.stabilize(measured: silhouette(left: 0.45, right: 0.55, in: box),
                                 box: box, confidence: 0.95, state: .tracking)
        stabilizer.reset()
        let fresh = silhouette(left: 0.1, right: 0.9, in: box)
        let result = stabilizer.stabilize(measured: fresh, box: box, confidence: 0.95, state: .reacquired)
        XCTAssertEqual(result?.points, fresh.points,
                       "after a reacquisition the previous body must not drag the new mask back")
    }
}
