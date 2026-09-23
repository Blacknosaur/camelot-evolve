import XCTest
@testable import Camelot

final class PlayerTrackingIdentityTests: XCTestCase {
    func testPartialBodyAssociationUsesHiddenExtentWithoutChangingTheObservation() throws {
        let full = CGRect(x: 0.3, y: 0.88, width: 0.05, height: 0.2)
        let visible = full.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let blue = signature(repeating: SIMD3<Float>(0.08, 0.18, 0.78))
        var profile = PlayerJerseyProfile(); profile.learn(blue, clear: true); profile.learn(blue, clear: true)
        let matched = try XCTUnwrap(PlayerIdentityAssociation.choose([.init(box: visible, jersey: blue)],
                                    expected: full, optical: visible, profile: profile, recovering: false))
        XCTAssertEqual(matched.candidate.box, visible)
        let estimate = PlayerBodyExtent.estimate(visible: visible, reference: full)
        XCTAssertEqual(estimate.maxY, full.maxY, accuracy: 0.0001)
        XCTAssertGreaterThan(estimate.maxY, 1)
    }

    func testOccludedLowerBodyUsesVisibleHeadAndLearnedScaleForFeet() {
        let full = CGRect(x: 0.3, y: 0.42, width: 0.06, height: 0.24)
        let visible = CGRect(x: 0.3, y: 0.42, width: 0.06, height: 0.10)
        let estimate = PlayerBodyExtent.estimate(visible: visible, reference: full, expected: full)

        XCTAssertEqual(estimate.minY, visible.minY, accuracy: 0.0001,
                       "The visible head anchors the inferred body")
        XCTAssertEqual(estimate.maxY, full.maxY, accuracy: 0.0001,
                       "The hidden legs extend to the learned foot line")
    }

    func testAutomaticAppearanceCanRecognizeAReentryWithoutAReadableNumber() {
        let shirt = signature(repeating: SIMD3<Float>(0.08, 0.18, 0.78))
        let body = CGRect(x: 0.3, y: 0.4, width: 0.06, height: 0.2)
        var memory = PlayerIdentityMemory()
        for time in [0.0, 1.0] {
            memory.learn(PlayerObservation(box: body, jersey: shirt, chroma: shirt,
                                           print: [1, 0, 0], time: time, upperBodyPrint: [1, 0, 0]), clear: true)
        }

        var returning = PlayerObservation(box: body, jersey: shirt, number: nil,
                                          chroma: shirt, print: [0.99, 0.04, 0], upperBodyPrint: [0.99, 0.04, 0])
        XCTAssertTrue(memory.gallery?.isReady == true)
        XCTAssertNil(memory.number.confirmed)
        XCTAssertTrue(memory.recognizesAutomaticReturn(returning))

        returning.print = [0, 1, 0]
        XCTAssertTrue(memory.recognizesAutomaticReturn(returning),
                      "Matching head/torso identity survives a changed whole-body pose")
        returning.upperBodyPrint = [0, 1, 0]
        XCTAssertFalse(memory.recognizesAutomaticReturn(returning),
                       "A different appearance must not be accepted just because the kit matches")
    }

    func testSameKitAtEitherExitEdgeCannotProveIdentity() {
        let shirt = signature(repeating: SIMD3<Float>(0.08, 0.18, 0.78))
        var memory = PlayerIdentityMemory()
        memory.learn(PlayerObservation(box: CGRect(x: 0.35, y: 0.4, width: 0.06, height: 0.2), jersey: shirt), clear: true)

        let partialReturn = PlayerObservation(box: CGRect(x: 0.01, y: 0.42, width: 0.05, height: 0.12), jersey: shirt)
        XCTAssertFalse(memory.recognizesEdgeReturn(partialReturn, through: .left))
        let rightReturn = PlayerObservation(box: CGRect(x: 0.94, y: 0.42, width: 0.05, height: 0.12), jersey: shirt)
        XCTAssertFalse(memory.recognizesEdgeReturn(rightReturn, through: .right),
                       "A teammate entering at the remembered edge is not identity evidence")
        XCTAssertFalse(memory.recognizesEdgeReturn(partialReturn, through: .right))
        XCTAssertFalse(memory.recognizesEdgeReturn(
            PlayerObservation(box: CGRect(x: 0.45, y: 0.42, width: 0.05, height: 0.12), jersey: shirt), through: .left),
                       "The edge fallback must not become a whole-frame same-kit fallback")
    }

    func testRightEdgeReturnRequiresMatchingAppearanceAndRejectsWrongNumber() {
        let shirt = signature(repeating: SIMD3<Float>(0.08, 0.18, 0.78))
        var memory = PlayerIdentityMemory()
        for time in [0.0, 1.0] {
            memory.learn(PlayerObservation(box: box(x: 0.4), jersey: shirt,
                                           print: [1, 0, 0], time: time, upperBodyPrint: [1, 0, 0]), clear: true)
        }
        var returning = PlayerObservation(box: CGRect(x: 0.94, y: 0.4, width: 0.05, height: 0.2),
                                          jersey: shirt, print: [0.99, 0.04, 0], upperBodyPrint: [0.99, 0.04, 0])
        XCTAssertTrue(memory.recognizesEdgeReturn(returning, through: .right))
        returning.print = [0, 1, 0]
        returning.upperBodyPrint = [0, 1, 0]
        XCTAssertFalse(memory.recognizesEdgeReturn(returning, through: .right))
        returning.print = nil
        returning.upperBodyPrint = nil
        XCTAssertFalse(memory.recognizesEdgeReturn(returning, through: .right))
        returning.print = [1, 0, 0]
        returning.upperBodyPrint = [1, 0, 0]
        memory.number.manual = "9"; returning.number = "3"
        XCTAssertFalse(memory.recognizesEdgeReturn(returning, through: .right))
        XCTAssertFalse(memory.recognizesAutomaticReturn(returning))
        returning.number = "9"
        XCTAssertTrue(memory.recognizesEdgeReturn(returning, through: .right))
    }

    func testPartialReturnRequiresMatchingUpperBodyNotJustMatchingKit() {
        let shirt = signature(repeating: SIMD3<Float>(0.08, 0.18, 0.78))
        var memory = PlayerIdentityMemory()
        for time in [0.0, 1.0] {
            memory.learn(PlayerObservation(box: box(x: 0.4), jersey: shirt, time: time,
                                           upperBodyPrint: [1, 0, 0]), clear: true)
        }
        var partial = PlayerObservation(box: CGRect(x: 0.94, y: 0.9, width: 0.05, height: 0.09),
                                        jersey: shirt, isPartial: true, upperBodyPrint: [0.99, 0.04, 0])
        XCTAssertTrue(memory.recognizesEdgeReturn(partial, through: .right))
        partial.upperBodyPrint = [0, 1, 0]
        XCTAssertFalse(memory.recognizesEdgeReturn(partial, through: .right))
        partial.upperBodyPrint = nil
        XCTAssertFalse(memory.recognizesEdgeReturn(partial, through: .right))
    }

    func testDormantRecoveryRequiresThreeFreshMatchesAndRejectsSameKitAmbiguity() {
        var confirmation = PlayerRecoveryConfirmation()
        let target = box(x: 0.4), blue = signature(repeating: SIMD3<Float>(0.08, 0.18, 0.78))
        XCTAssertFalse(confirmation.accept(target, at: 4, requiredObservations: 3, maximumInterval: 0.6))
        XCTAssertFalse(confirmation.accept(target, at: 4.4, requiredObservations: 3, maximumInterval: 0.6))
        XCTAssertTrue(confirmation.accept(target, at: 4.8, requiredObservations: 3, maximumInterval: 0.6))
        XCTAssertFalse(confirmation.accept(target, at: 5.2, requiredObservations: 3, maximumInterval: 0.6))
        XCTAssertFalse(confirmation.accept(nil, at: 5.6))
        XCTAssertFalse(confirmation.accept(target, at: 6, requiredObservations: 3, maximumInterval: 0.6))
        var profile = PlayerJerseyProfile(); profile.learn(blue, clear: true); profile.learn(blue, clear: true)
        let candidates = [PlayerIdentityAssociation.Candidate(box: target.offsetBy(dx: -0.02, dy: 0), jersey: blue),
                          .init(box: target.offsetBy(dx: 0.02, dy: 0), jersey: blue)]
        XCTAssertNil(PlayerIdentityAssociation.choose(candidates, expected: target, optical: nil, profile: profile, recovering: true, recoveryAge: 4))
    }

    func testCameraAlignedPlayerVelocityOverridesAcceleratingScreenTrajectory() {
        var trajectory = PlayerTrackingTrajectory()
        for index in 0...6 {
            let time = Double(index) * 0.1
            trajectory.append(.init(time: time, box: box(x: 0.1 + time * time * 0.3)))
        }
        let still = trajectory.samples.last!.box
        XCTAssertEqual(trajectory.predicted(at: 1.5, playerVelocity: .zero), still,
                       "A camera pan is not player velocity")
        let velocity = CGPoint(x: 0.02, y: 0.01)
        XCTAssertEqual(trajectory.predicted(at: 9, playerVelocity: velocity), trajectory.predicted(at: 3.1, playerVelocity: velocity))
    }

    func testJerseySignaturesDistinguishPrimaryColorsStripesAndShadow() {
        let green = signature(repeating: SIMD3<Float>(0.08, 0.72, 0.18))
        let blue = signature(repeating: SIMD3<Float>(0.08, 0.18, 0.78))
        let white = signature(repeating: SIMD3<Float>(0.92, 0.92, 0.92))
        let striped = PlayerJerseySignature(colors: Array(repeating: SIMD3<Float>(0.85, 0.08, 0.08), count: 60) +
            Array(repeating: SIMD3<Float>(0.92, 0.92, 0.92), count: 60))
        let shadow = signature(repeating: SIMD3<Float>(0.01, 0.08, 0.015))

        XCTAssertGreaterThan(green.similarity(to: green), 0.99)
        XCTAssertLessThan(green.similarity(to: blue), 0.5)
        XCTAssertLessThan(green.similarity(to: white), 0.5)
        XCTAssertLessThan(green.similarity(to: striped), 0.8)
        XCTAssertLessThan(green.similarity(to: shadow), 0.9)
        XCTAssertGreaterThan(white.similarity(to: striped), 0.4)
    }

    func testProfileLearnsOnlyClearAnchoredExamplesAndIsBounded() {
        let anchor = signature(repeating: SIMD3<Float>(0.06, 0.65, 0.16))
        let nearby = signature(repeating: SIMD3<Float>(0.08, 0.60, 0.20))
        let mismatch = signature(repeating: SIMD3<Float>(0.08, 0.16, 0.78))
        var profile = PlayerJerseyProfile()

        profile.learn(anchor, clear: false)
        XCTAssertTrue(profile.examples.isEmpty)
        profile.learn(anchor, clear: true)
        XCTAssertEqual(profile.examples, [anchor])
        profile.learn(mismatch, clear: true)
        XCTAssertEqual(profile.examples, [anchor], "A clear observation from another kit must not rewrite identity")
        profile.learn(nearby, clear: true)
        XCTAssertEqual(profile.examples.count, 2)

        for _ in 0..<20 { profile.learn(nearby, clear: true) }
        XCTAssertLessThanOrEqual(profile.examples.count, 8)
        XCTAssertEqual(profile.examples.first, anchor, "The original identity anchor remains fixed")
    }

    func testAssociationRejectsJerseyMismatchAndSameKitAmbiguity() {
        let expected = CGRect(x: 0.45, y: 0.5, width: 0.1, height: 0.2)
        let green = signature(repeating: SIMD3<Float>(0.08, 0.72, 0.18))
        let blue = signature(repeating: SIMD3<Float>(0.08, 0.18, 0.78))
        var profile = PlayerJerseyProfile(); profile.learn(green, clear: true)

        let mismatch = PlayerIdentityAssociation.choose(
            [.init(box: expected, jersey: blue)], expected: expected, optical: nil, profile: profile, recovering: false)
        XCTAssertNil(mismatch)

        let left = expected.offsetBy(dx: -0.025, dy: 0)
        let right = expected.offsetBy(dx: 0.025, dy: 0)
        let ambiguous = PlayerIdentityAssociation.choose(
            [.init(box: left, jersey: green), .init(box: right, jersey: green)],
            expected: expected, optical: nil, profile: profile, recovering: false)
        XCTAssertNil(ambiguous, "Two equally plausible same-kit candidates must not be arbitrarily assigned")

        let directionExpected = expected.offsetBy(dx: 0.08, dy: 0)
        let directional = PlayerIdentityAssociation.choose(
            [.init(box: left, jersey: green), .init(box: directionExpected, jersey: green)],
            expected: directionExpected, optical: nil, profile: profile, recovering: false)
        XCTAssertEqual(directional?.candidate.box, directionExpected,
                       "When appearance is equal, the candidate along the established direction wins")
    }

    func testTrajectoryPredictionFavorsEstablishedDirectionAndResetsAfterGap() {
        var trajectory = PlayerTrackingTrajectory()
        trajectory.append(.init(time: 0, box: box(x: 0.10)))
        trajectory.append(.init(time: 0.10, box: box(x: 0.20)))
        trajectory.append(.init(time: 0.20, box: box(x: 0.30)))
        let predicted = XCTAssertNotNilAndReturn(trajectory.predicted(at: 0.30))
        XCTAssertGreaterThan(predicted.midX, 0.30)
        let cameraCompensated = XCTAssertNotNilAndReturn(trajectory.predicted(at: 0.30, cameraVelocity: CGPoint(x: 0.8, y: 0)))
        XCTAssertLessThan(cameraCompensated.midX, predicted.midX)

        trajectory.append(.init(time: 0.60, box: box(x: 0.80)))
        XCTAssertEqual(trajectory.samples.count, 1, "A long observation gap starts a fresh recent-history window")
        XCTAssertEqual(trajectory.predicted(at: 0.70)!.midX, 0.85, accuracy: 0.0001)
    }

    func testTrajectoryPredictionIsBoundedAtMaximumRecoveryHorizon() {
        var trajectory = PlayerTrackingTrajectory()
        trajectory.append(.init(time: 0, box: box(x: 0.10)))
        trajectory.append(.init(time: 0.10, box: box(x: 0.20)))
        trajectory.append(.init(time: 0.20, box: box(x: 0.30)))

        let capped = XCTAssertNotNilAndReturn(trajectory.predicted(at: 3.0))
        let atLimit = XCTAssertNotNilAndReturn(trajectory.predicted(at: 0.20 + PlayerTrackingLimits.maximumRecoverySeconds))
        XCTAssertEqual(capped.midX, atLimit.midX, accuracy: 0.0001)
        XCTAssertEqual(capped.maxY, atLimit.maxY, accuracy: 0.0001)
    }

    func testTrajectoryRetainsRecentConfirmedMotionDuringRecoveryGap() {
        var trajectory = PlayerTrackingTrajectory()
        trajectory.append(.init(time: 1.0, box: box(x: 0.10)))
        trajectory.append(.init(time: 1.10, box: box(x: 0.20)))
        trajectory.append(.init(time: 1.20, box: box(x: 0.30)))

        // No samples are appended while the player is hidden. The confirmed
        // pre-gap history remains available as a bounded reacquisition hint.
        let predicted = XCTAssertNotNilAndReturn(trajectory.predicted(at: 2.0))
        XCTAssertGreaterThan(predicted.midX, box(x: 0.30).midX)
        XCTAssertEqual(predicted.midX, trajectory.predicted(at: 1.20 + 0.8)!.midX, accuracy: 0.0001)
    }

    func testRecoveryDoesNotTrustAnUnconfirmedSeedJersey() {
        let target = box(x: 0.4), blue = signature(repeating: SIMD3<Float>(0.08, 0.18, 0.78))
        var profile = PlayerJerseyProfile(); profile.learn(blue, clear: true)
        // A lone body matching the seed almost perfectly may recover even
        // before the profile is confirmed; an overlapping one may not.
        let candidates = [PlayerIdentityAssociation.Candidate(box: target, jersey: blue)]
        XCTAssertNotNil(PlayerIdentityAssociation.choose(candidates, expected: target, optical: nil, profile: profile, recovering: true))
        XCTAssertNil(PlayerIdentityAssociation.choose([.init(box: target, jersey: blue, crowded: true)], expected: target, optical: nil, profile: profile, recovering: true))
        let weaker = signature(repeating: SIMD3<Float>(0.3, 0.3, 0.6))
        XCTAssertNil(PlayerIdentityAssociation.choose([.init(box: target, jersey: weaker)], expected: target, optical: nil, profile: profile, recovering: true))
        XCTAssertTrue(PlayerJerseyProfile.resuming(profile).examples.isEmpty, "Correct can replace an ambiguous first jersey")
        profile.learn(blue, clear: true)
        XCTAssertEqual(PlayerJerseyProfile.resuming(profile), profile)
        XCTAssertNotNil(PlayerIdentityAssociation.choose(candidates, expected: target, optical: nil, profile: profile, recovering: true))
    }

    func testRecoveryUsesClearJerseyToSeparateOverlappingOpponentsButNotTeammates() {
        let target = box(x: 0.4), blue = signature(repeating: SIMD3<Float>(0.08, 0.18, 0.78))
        let white = signature(repeating: SIMD3<Float>(0.92, 0.92, 0.92))
        var profile = PlayerJerseyProfile(); profile.learn(blue, clear: true); profile.learn(blue, clear: true)
        let selected = PlayerIdentityAssociation.Candidate(box: target, jersey: blue, crowded: true)
        let opponent = PlayerIdentityAssociation.Candidate(box: target.offsetBy(dx: 0.025, dy: 0), jersey: white, crowded: true)
        XCTAssertEqual(PlayerIdentityAssociation.choose([selected, opponent], expected: target, optical: nil, profile: profile, recovering: true)?.candidate.box, target)
        let teammate = PlayerIdentityAssociation.Candidate(box: opponent.box, jersey: blue, crowded: true)
        XCTAssertNil(PlayerIdentityAssociation.choose([selected, teammate], expected: target, optical: nil, profile: profile, recovering: true))
    }

    func testRecoveryConfirmationCompensatesForFastCameraPan() {
        var confirmation = PlayerRecoveryConfirmation()
        let target = box(x: 0.4)
        XCTAssertFalse(confirmation.accept(target, at: 1, camera: .identity))
        let pan = CameraTransform(values: [1, 0, -0.2, 0, 1, 0, 0, 0, 1])
        XCTAssertTrue(confirmation.accept(target.offsetBy(dx: -0.2, dy: 0), at: 1.15, camera: pan))
    }

    func testRecoveryRequiresTwoTimelyConsistentObservations() {
        var confirmation = PlayerRecoveryConfirmation()
        let candidate = box(x: 0.4)
        XCTAssertFalse(confirmation.accept(candidate, at: 1.0))
        XCTAssertFalse(confirmation.accept(candidate, at: 1.01), "Observations closer than the minimum interval do not confirm")
        XCTAssertTrue(confirmation.accept(candidate, at: 1.06))
        XCTAssertFalse(confirmation.accept(candidate, at: 1.19), "A new occlusion requires fresh confirmation")

        var late = PlayerRecoveryConfirmation()
        XCTAssertFalse(late.accept(candidate, at: 2.0))
        XCTAssertFalse(late.accept(candidate, at: 2.31), "A stale observation cannot confirm reacquisition")
    }

    func testRecoveryKeepsCompetingCandidatesUntilOneHasTemporalLead() {
        var confirmation = PlayerRecoveryConfirmation()
        func match(_ box: CGRect, _ score: CGFloat) -> PlayerIdentityAssociation.Match {
            .init(candidate: .init(box: box, jersey: nil), score: score)
        }

        XCTAssertNil(confirmation.accept([
            match(box(x: 0.40), 0.70), match(box(x: 0.46), 0.69)
        ], at: 1.0, requiredObservations: 2))
        XCTAssertNil(confirmation.accept([
            match(box(x: 0.41), 0.78), match(box(x: 0.45), 0.70)
        ], at: 1.1, requiredObservations: 2),
        "Two same-kit returns with similar support remain ambiguous")

        let accepted = confirmation.accept([
            match(box(x: 0.42), 0.82)
        ], at: 1.2, requiredObservations: 2)
        XCTAssertEqual(accepted?.candidate.box.midX ?? -1, box(x: 0.42).midX, accuracy: 0.0001)
    }

    func testExitSidePriorPrefersSameEdgeWithoutRejectingOtherEdges() {
        let blue = signature(repeating: SIMD3<Float>(0.08, 0.18, 0.78))
        var profile = PlayerJerseyProfile()
        profile.learn(blue, clear: true)
        profile.learn(blue, clear: true)

        let expected = box(x: 0.40)
        let left = PlayerIdentityAssociation.Candidate(box: box(x: 0.20), jersey: blue)
        let right = PlayerIdentityAssociation.Candidate(box: box(x: 0.65), jersey: blue)
        let ranked = PlayerIdentityAssociation.ranked(
            [left, right], expected: expected, optical: nil, profile: profile,
            recovering: true, recoveryAge: 4, exitSide: .left)

        XCTAssertEqual(ranked.first?.candidate.box, left.box,
                       "A return near the remembered exit edge wins equal motion/identity evidence")
        XCTAssertTrue(ranked.contains { $0.candidate.box == right.box },
                      "The edge memory is a soft prior, not a hard gate")
    }

    func testExitSideDetectsTheStrongestFrameEdge() {
        XCTAssertEqual(PlayerExitSide.detect(CGRect(x: -0.03, y: 0.4, width: 0.1, height: 0.2)), .left)
        XCTAssertEqual(PlayerExitSide.detect(CGRect(x: 0.93, y: 0.4, width: 0.1, height: 0.2)), .right)
        XCTAssertEqual(PlayerExitSide.detect(CGRect(x: 0.4, y: -0.02, width: 0.1, height: 0.2)), .top)
        XCTAssertEqual(PlayerExitSide.detect(CGRect(x: 0.4, y: 0.82, width: 0.1, height: 0.2)), .bottom)
        XCTAssertNil(PlayerExitSide.detect(box(x: 0.4)))
    }

    func testRoutineAssociationRequiresOpticalContinuity() {
        let current = box(x: 0.4)
        XCTAssertTrue(PlayerIdentityAssociation.isContinuous(current.offsetBy(dx: 0.02, dy: 0), from: current))
        XCTAssertFalse(PlayerIdentityAssociation.isContinuous(current.offsetBy(dx: 0.3, dy: 0), from: current))
    }

    func testRecoveryCanSurviveOneMissWithoutCountingItAsEvidence() {
        let candidate = PlayerIdentityAssociation.Candidate(box: CGRect(x: 0.1, y: 0.5, width: 0.05, height: 0.15), jersey: nil)
        let matches = [PlayerIdentityAssociation.Match(candidate: candidate, score: 0.9)]
        var recovery = PlayerRecoveryConfirmation()
        XCTAssertNil(recovery.accept(matches, at: 1, requiredObservations: 3, toleratesMiss: true))
        XCTAssertNil(recovery.accept([], at: 1.07, requiredObservations: 3, toleratesMiss: true))
        XCTAssertNil(recovery.accept(matches, at: 1.14, requiredObservations: 3, toleratesMiss: true))
        XCTAssertNotNil(recovery.accept(matches, at: 1.21, requiredObservations: 3, toleratesMiss: true))
        XCTAssertEqual(recovery.confirmedSamples.map(\.time), [1, 1.14, 1.21], "Keep real sightings, not the missed frame")
        XCTAssertNil(recovery.accept(matches, at: 2, requiredObservations: 3, toleratesMiss: true))
        XCTAssertTrue(recovery.confirmedSamples.isEmpty, "Never reuse a previous recovery's history")
        XCTAssertNil(recovery.accept([], at: 2.4, requiredObservations: 3, toleratesMiss: true))
        XCTAssertNil(recovery.expected(at: 2.41, camera: nil))
    }

    func testConfirmedRecoveryHistoryContainsOnlyTheWinningObservedPositions() {
        var recovery = PlayerRecoveryConfirmation()
        for frame in 0...2 {
            let time = 1 + Double(frame) * 0.07
            let moving = CGRect(x: 0.1 + Double(frame) * 0.01, y: 0.5, width: 0.05, height: 0.15)
            let rival = CGRect(x: 0.7, y: 0.5, width: 0.05, height: 0.15)
            let matches = [PlayerIdentityAssociation.Match(candidate: .init(box: moving, jersey: nil, tag: 1), score: 0.95),
                           .init(candidate: .init(box: rival, jersey: nil, tag: 2), score: 0.7)]
            let accepted = recovery.accept(matches, at: time, requiredObservations: 3)
            if frame < 2 { XCTAssertNil(accepted); XCTAssertTrue(recovery.confirmedSamples.isEmpty) }
            else { XCTAssertEqual(accepted?.candidate.tag, 1) }
        }
        XCTAssertEqual(recovery.confirmedSamples.count, 3)
        for (index, sample) in recovery.confirmedSamples.enumerated() {
            XCTAssertEqual(sample.time, 1 + Double(index) * 0.07, accuracy: 0.0001)
            XCTAssertEqual(sample.box.minX, 0.1 + Double(index) * 0.01, accuracy: 0.0001)
        }
        recovery.reset()
        XCTAssertTrue(recovery.confirmedSamples.isEmpty)
    }

    func testPendingRecoveryUsesObservedStopAndExpiresWithoutEvidence() throws {
        var confirmation = PlayerRecoveryConfirmation()
        let stopped = box(x: 0.4)
        XCTAssertFalse(confirmation.accept(stopped, at: 1, camera: .identity))
        XCTAssertEqual(try XCTUnwrap(confirmation.expected(at: 1.15, camera: .identity)).midX, stopped.midX, accuracy: 0.0001)
        let pan = CameraTransform(values: [1, 0, -0.2, 0, 1, 0, 0, 0, 1])
        let expected = try XCTUnwrap(confirmation.expected(at: 1.15, camera: pan))
        XCTAssertEqual(expected.midX, stopped.midX - 0.2, accuracy: 0.0001)
        XCTAssertNil(confirmation.expected(at: 1.5, camera: .identity))
        XCTAssertFalse(confirmation.accept(nil, at: 1.15))
        XCTAssertNil(confirmation.expected(at: 1.2, camera: .identity), "A rejected association cannot become temporal evidence")
    }

    func testOldVelocityCannotRunTheSearchOntoADistantTeammate() throws {
        var trajectory = PlayerTrackingTrajectory()
        for frame in 0...20 {
            let t = Double(frame) / 30
            trajectory.append(.init(time: t, box: CGRect(x: 0.5 + t * 0.1, y: 0.5, width: 0.025, height: 0.08)))
        }
        let last = try XCTUnwrap(trajectory.samples.last)
        let predicted = try XCTUnwrap(trajectory.predicted(at: last.time + 2.4))
        XCTAssertLessThanOrEqual(predicted.midX - last.box.midX, 0.076)
    }

    func testLegacyAndNewCodableProfilesRoundTripAndTrackOperationsPreserveIdentity() throws {
        let id = UUID(), otherID = UUID()
        let profile = profile(for: SIMD3<Float>(0.08, 0.18, 0.78))
        let first = PlayerMotion(samples: [.init(time: 0, box: box(x: 0.1))], trackID: id, jerseyProfile: profile)
        let other = PlayerMotion(samples: [.init(time: 0, box: box(x: 0.7))], trackID: otherID,
                                  jerseyProfile: self.profile(for: SIMD3<Float>(0.08, 0.72, 0.18)))

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first))) as! [String: Any]
        legacyObject.removeValue(forKey: "jerseyProfile")
        let legacyJSON = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertNil(try JSONDecoder().decode(PlayerMotion.self, from: legacyJSON).jerseyProfile)
        XCTAssertEqual(first, try JSONDecoder().decode(PlayerMotion.self, from: JSONEncoder().encode(first)))

        var updatedProfile = profile
        updatedProfile.learn(signature(repeating: SIMD3<Float>(0.09, 0.62, 0.20)), clear: true)
        let continuation = PlayerMotion(samples: [.init(time: 1, box: box(x: 0.2))], trackID: id, jerseyProfile: updatedProfile)
        XCTAssertEqual(first.continuing(with: continuation, from: 1).jerseyProfile, updatedProfile)
        let noProfileContinuation = PlayerMotion(samples: [.init(time: 1, box: box(x: 0.2))], trackID: id)
        XCTAssertEqual(first.continuing(with: noProfileContinuation, from: 1).jerseyProfile, profile)
        XCTAssertEqual(first.bound(at: 0)?.jerseyProfile, profile)

        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 2)
        var label = AnalysisAnnotation(tool: .text, points: [.init(x: 0.1, y: 0.2)], text: "Player", start: 0, end: 2)
        label.playerMotion = first
        var halo = AnalysisAnnotation(tool: .spotlight, points: [first.samples[0].box.origin], start: 0, end: 2)
        halo.playerMotion = first
        var linked = AnalysisAnnotation(tool: .zone, points: [.zero, .init(x: 0.2, y: 0.2)], start: 0, end: 2)
        linked.linkedPlayers = [first, other]
        var unrelated = AnalysisAnnotation(tool: .text, points: [.zero], text: "Other", start: 0, end: 2)
        unrelated.playerMotion = other
        clip.annotations = [label, halo, linked, unrelated]
        clip.storePlayerTrack(first); clip.storePlayerTrack(other)
        clip.storePlayerTrack(first.continuing(with: continuation, from: 1))
        XCTAssertEqual(clip.trackingLibrary?.players.count, 2)
        XCTAssertEqual(clip.trackingLibrary?.players.first(where: { $0.id == id })?.motion.jerseyProfile, updatedProfile)
        XCTAssertEqual(clip.trackingLibrary?.players.first(where: { $0.id == otherID })?.motion.jerseyProfile, other.jerseyProfile)
        XCTAssertEqual(clip.annotations[0].playerMotion?.jerseyProfile, updatedProfile)
        XCTAssertEqual(clip.annotations[1].playerMotion?.jerseyProfile, updatedProfile)
        XCTAssertEqual(clip.annotations[2].linkedPlayers?.first?.jerseyProfile, updatedProfile)
        XCTAssertEqual(clip.annotations[2].linkedPlayers?.last?.jerseyProfile, other.jerseyProfile)
        XCTAssertEqual(clip.annotations[3].playerMotion?.jerseyProfile, other.jerseyProfile)
    }

    private func signature(repeating color: SIMD3<Float>) -> PlayerJerseySignature {
        PlayerJerseySignature(colors: Array(repeating: color, count: 120))
    }

    private func profile(for color: SIMD3<Float>) -> PlayerJerseyProfile {
        var result = PlayerJerseyProfile(); result.learn(signature(repeating: color), clear: true); return result
    }

    private func box(x: CGFloat) -> CGRect { CGRect(x: x, y: 0.5, width: 0.1, height: 0.2) }

    private func XCTAssertNotNilAndReturn<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        XCTAssertNotNil(value, file: file, line: line)
        return value!
    }
}
