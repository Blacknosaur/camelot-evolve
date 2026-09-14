import XCTest
@testable import Camelot

final class PlayerTrackingIdentityTests: XCTestCase {
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
        let candidates = [PlayerIdentityAssociation.Candidate(box: target, jersey: blue)]
        XCTAssertNil(PlayerIdentityAssociation.choose(candidates, expected: target, optical: nil, profile: profile, recovering: true))
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
