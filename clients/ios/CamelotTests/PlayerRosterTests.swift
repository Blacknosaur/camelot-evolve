import XCTest
import UIKit
import SwiftUI
@testable import Camelot

final class PlayerRosterTests: XCTestCase {
    private let blue = SIMD3<Float>(0.08, 0.18, 0.78)
    private let white = SIMD3<Float>(0.92, 0.92, 0.92)
    private let red = SIMD3<Float>(0.85, 0.08, 0.08)

    // MARK: Exclusive assignment

    func testEachBodyGoesToOnePlayerAndSameKitAmbiguityHidesBoth() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let expectations = [
            expectation(a, x: 0.2, color: blue), expectation(b, x: 0.6, color: white),
            expectation(c, x: 0.40, color: red), expectation(d, x: 0.44, color: red),
        ]
        let observations = [observation(x: 0.21, color: blue), observation(x: 0.61, color: white), observation(x: 0.42, color: red)]
        let result = PlayerRosterAssociation.assign(expectations, observations: observations)
        XCTAssertEqual(result.assignment(for: a)?.observation, 0)
        XCTAssertEqual(result.assignment(for: b)?.observation, 1)
        XCTAssertNil(result.assignment(for: c)); XCTAssertNil(result.assignment(for: d))
        XCTAssertTrue(result.ambiguous.contains(c) || result.ambiguous.contains(d), "Two red players equally near one red body must not be guessed")
        XCTAssertEqual(result.claimed, [0, 1, 2]); XCTAssertEqual(result.contested, [2])
        XCTAssertEqual(Set(result.assignments.map(\.observation)).count, result.assignments.count)
    }

    func testReturningPlayerCannotTakeTheBodyAnActiveTeammateOwns() {
        let active = UUID(), returning = UUID()
        var missing = expectation(returning, x: 0.22, color: blue, recovering: true, age: 0.8)
        let result = PlayerRosterAssociation.assign([expectation(active, x: 0.2, color: blue), missing],
                                                    observations: [observation(x: 0.21, color: blue), observation(x: 0.3, color: blue)])
        XCTAssertEqual(result.assignment(for: active)?.observation, 0)
        XCTAssertEqual(result.assignment(for: returning)?.observation, 1, "With the teammate's body taken, the returning player recovers on the free body")
        missing = expectation(returning, x: 0.22, color: blue, recovering: true, age: 0.8)
        let single = PlayerRosterAssociation.assign([expectation(active, x: 0.2, color: blue), missing],
                                                    observations: [observation(x: 0.21, color: blue)])
        XCTAssertEqual(single.assignment(for: active)?.observation, 0)
        XCTAssertNil(single.assignment(for: returning))
    }

    func testOffscreenReturnNeedsIndividualEvidenceEvenForOneCandidate() {
        let id = UUID()
        let unknown = expectation(id, x: -0.3, color: blue, recovering: true, age: 6)
        let teammate = observation(x: 0.02, color: blue)
        XCTAssertNil(PlayerRosterAssociation.assign([unknown], observations: [teammate]).assignment(for: id))
        let justOutside = expectation(id, x: 1.0, color: blue, recovering: true, age: 0.2)
        XCTAssertNil(PlayerRosterAssociation.assign([justOutside], observations: [observation(x: 0.94, color: blue)]).assignment(for: id),
                     "A short offscreen return still needs individual evidence")
        var remembered = memory(blue)
        for _ in 0..<3 { remembered.number.vote("9") }
        let expected = PlayerRosterAssociation.Expectation(id: id, box: box(x: -0.3), memory: remembered, recovering: true, recoveryAge: 6)
        var returning = teammate; returning.number = "9"
        XCTAssertEqual(PlayerRosterAssociation.assign([expected], observations: [returning]).assignment(for: id)?.observation, 0)
        returning.number = "8"
        XCTAssertNil(PlayerRosterAssociation.assign([expected], observations: [returning]).assignment(for: id))
        returning.number = nil
        XCTAssertNil(PlayerRosterAssociation.assign([expected], observations: [returning]).assignment(for: id))
    }

    func testProvisionalTrackletCannotStealAConfirmedPlayersRecovery() {
        let saved = UUID(), provisional = UUID()
        let missing = expectation(saved, x: 0.2, color: blue, recovering: true, age: 0.2)
        var newcomer = expectation(provisional, x: 0.21, color: blue)
        newcomer.isProvisional = true
        let result = PlayerRosterAssociation.assign([newcomer, missing], observations: [observation(x: 0.21, color: blue)])
        XCTAssertEqual(result.assignment(for: saved)?.observation, 0)
        XCTAssertNil(result.assignment(for: provisional))
        XCTAssertEqual(result.assignments.count, 1)
    }

    // MARK: Numbers and identity memory

    func testShirtNumbersNeedAgreementAndDecideBetweenSameKitPlayers() {
        var votes = PlayerNumberVotes()
        votes.vote("7"); votes.vote("7"); votes.vote("1"); votes.vote("77"); votes.vote("0"); votes.vote("abc")
        XCTAssertNil(votes.confirmed)
        votes.vote("7")
        XCTAssertEqual(votes.confirmed, "7")
        XCTAssertEqual(votes.total, 5)
        var seven = memory(blue), ten = memory(blue)
        for _ in 0..<3 { seven.number.vote("7"); ten.number.vote("10") }
        var body = observation(x: 0.3, color: blue); body.number = "10"
        XCTAssertEqual(seven.similarity(to: body), 0, "A confirmed different number is decisive")
        XCTAssertGreaterThan(ten.similarity(to: body) ?? 0, 0.99)
        let unread = observation(x: 0.3, color: blue)
        XCTAssertGreaterThan(seven.similarity(to: unread) ?? 0, 0.9, "An unreadable number never rejects a matching kit")
        let a = UUID(), b = UUID()
        let result = PlayerRosterAssociation.assign(
            [.init(id: a, box: box(x: 0.3), memory: seven, recovering: false, recoveryAge: 0),
             .init(id: b, box: box(x: 0.3), memory: ten, recovering: false, recoveryAge: 0)],
            observations: [body])
        XCTAssertEqual(result.assignment(for: b)?.observation, 0)
        XCTAssertNil(result.assignment(for: a))
    }

    func testMemoryKeepsConfirmedKitAndResumesLikeJerseyProfiles() {
        var memory = PlayerIdentityMemory()
        var mixed = observation(x: 0.3, color: blue); mixed.crowded = true
        memory.learn(mixed, clear: false)
        XCTAssertTrue(memory.jersey.examples.isEmpty)
        memory.learn(observation(x: 0.3, color: blue), clear: true)
        XCTAssertEqual(memory.kitColor?.count, 3)
        XCTAssertFalse(memory.isConfirmed)
        XCTAssertTrue(PlayerIdentityMemory.resuming(memory, jersey: nil).jersey.examples.isEmpty, "A provisional kit may be replaced")
        memory.learn(observation(x: 0.3, color: blue), clear: true)
        XCTAssertTrue(memory.isConfirmed)
        XCTAssertEqual(PlayerIdentityMemory.resuming(memory, jersey: nil), memory)
        var legacy = PlayerJerseyProfile()
        legacy.learn(signature(white), clear: true); legacy.learn(signature(white), clear: true)
        XCTAssertEqual(PlayerIdentityMemory.resuming(nil, jersey: legacy).jersey, legacy, "Older saved tracks contribute their jersey")
        XCTAssertLessThan(memory.similarity(to: observation(x: 0.3, color: white)) ?? 1, 0.5)
    }

    func testSkinAndSockToneSeparateTwoPlayersInTheSameKit() {
        let light = SIMD3<Float>(0.85, 0.72, 0.62), dark = SIMD3<Float>(0.30, 0.20, 0.14)
        func body(head: SIMD3<Float>, x: Double = 0.3) -> PlayerObservation {
            var observation = observation(x: x, color: white)
            observation.head = PlayerJerseySignature(brightnessOf: Array(repeating: head, count: 120))
            observation.legs = PlayerJerseySignature(brightnessOf: Array(repeating: white, count: 120))
            return observation
        }
        var lighter = PlayerIdentityMemory(), darker = PlayerIdentityMemory()
        for _ in 0..<2 { lighter.learn(body(head: light), clear: true); darker.learn(body(head: dark), clear: true) }
        XCTAssertTrue(lighter.head?.isConfirmed == true)
        XCTAssertGreaterThan(lighter.similarity(to: body(head: light)) ?? 0, 0.9)
        XCTAssertLessThan(lighter.similarity(to: body(head: dark)) ?? 1, 0.7, "Same shirt, different skin tone: clearly not the same player")
        XCTAssertGreaterThan(darker.similarity(to: body(head: dark)) ?? 0, 0.9)
        XCTAssertGreaterThan(lighter.similarity(to: observation(x: 0.3, color: white)) ?? 0, 0.9, "An unreadable head never penalises")
        let a = UUID(), b = UUID()
        let result = PlayerRosterAssociation.assign(
            [.init(id: a, box: box(x: 0.3), memory: lighter, recovering: true, recoveryAge: 1),
             .init(id: b, box: box(x: 0.3), memory: darker, recovering: true, recoveryAge: 1)],
            observations: [body(head: dark, x: 0.31)])
        XCTAssertEqual(result.assignment(for: b)?.observation, 0)
        XCTAssertNil(result.assignment(for: a))
        let decoded = try? JSONDecoder().decode(PlayerIdentityMemory.self, from: JSONEncoder().encode(lighter))
        XCTAssertEqual(decoded, lighter)
    }

    func testFloodlitBlueAndWhiteKitsAreSeparatedByChromaticity() {
        let floodlitBlue = SIMD3<Float>(0.44, 0.51, 0.60), floodlitWhite = SIMD3<Float>(0.84, 0.85, 0.78)
        let blueHue = PlayerJerseySignature(colors: Array(repeating: floodlitBlue, count: 120))
        let whiteHue = PlayerJerseySignature(colors: Array(repeating: floodlitWhite, count: 120))
        _ = (blueHue, whiteHue) // uniform synthetic colours separate by hue; real floodlit pixels mix into the neutral bins
        let blueChroma = PlayerJerseySignature(chromaOf: Array(repeating: floodlitBlue, count: 120))
        let whiteChroma = PlayerJerseySignature(chromaOf: Array(repeating: floodlitWhite, count: 120))
        XCTAssertLessThan(blueChroma.similarity(to: whiteChroma), 0.5)
        XCTAssertGreaterThan(blueChroma.similarity(to: PlayerJerseySignature(chromaOf: Array(repeating: SIMD3<Float>(0.30, 0.36, 0.44), count: 120))), 0.8,
                             "The same kit in shadow keeps its chromaticity")
        func body(_ color: SIMD3<Float>) -> PlayerObservation {
            PlayerObservation(box: box(x: 0.3), jersey: PlayerJerseySignature(colors: Array(repeating: color, count: 120)),
                              chroma: PlayerJerseySignature(chromaOf: Array(repeating: color, count: 120)))
        }
        var blue = PlayerIdentityMemory()
        blue.learn(body(floodlitBlue), clear: true); blue.learn(body(floodlitBlue), clear: true)
        XCTAssertGreaterThan(blue.similarity(to: body(floodlitBlue)) ?? 0, 0.9)
        XCTAssertLessThan(blue.similarity(to: body(floodlitWhite)) ?? 1, 0.5, "A white body must fail the kit gate for a blue player")
        XCTAssertNil(PlayerRosterAssociation.assign([.init(id: UUID(), box: box(x: 0.3), memory: blue, recovering: false, recoveryAge: 0)],
                                                    observations: [body(floodlitWhite)]).assignments.first)
    }

    func testAppearanceRankingDoesNotSaturateSameKitPlayers() throws {
        var identity = memory(blue)
        var gallery = PlayerAppearanceGallery()
        for time in [0.0, 0.5, 1] { gallery.add([1, 0], at: time) }
        identity.gallery = gallery
        var target = observation(x: 0.3, color: blue); target.print = [0.95, 0.31225]
        var teammate = target; teammate.print = [0.85, 0.52678]
        XCTAssertGreaterThan(try XCTUnwrap(identity.similarity(to: target)), try XCTUnwrap(identity.similarity(to: teammate)))
        gallery.add([0, 1], at: 2)
        XCTAssertEqual(gallery.prints.first, [1, 0], "The initial reference is retained across new viewpoints")
    }

    func testAppearanceGalleryRejectsIncompatibleAndInvalidEmbeddings() {
        var gallery = PlayerAppearanceGallery()
        gallery.add([1, 0], at: 0)
        gallery.add([1, 0, 0], at: 1)
        gallery.add([.nan, 1], at: 2)
        gallery.add([0, 0], at: 3)
        XCTAssertEqual(gallery.prints.count, 1)
        XCTAssertNil(gallery.similarity(to: [1, 0, 0]))
    }

    func testLongAbsenceCannotBeResolvedByGenericAppearanceAlone() {
        var mine = memory(blue)
        let look: [Float] = [1, 0, 0, 0]
        var gallery = PlayerAppearanceGallery()
        gallery.add(look, at: 0); gallery.add(look, at: 0.5); gallery.add(look, at: 1)
        mine.gallery = gallery
        var candidate = observation(x: 0.8, color: blue); candidate.print = look
        XCTAssertNil(PlayerPresence.findAnywhere([candidate], memory: mine), "One visible teammate is still ambiguous when the actual player is offscreen")
        for _ in 0..<3 { mine.number.vote("9") }
        candidate.number = "9"
        XCTAssertEqual(PlayerPresence.findAnywhere([candidate], memory: mine), 0)
        var rival = candidate; rival.box = box(x: 0.1)
        XCTAssertNil(PlayerPresence.findAnywhere([candidate, rival], memory: mine), "An ambiguous number reading must not pick a body")
        XCTAssertNil(PlayerPresence.findAnywhere([candidate], memory: mine, plausible: { _ in false }))
        candidate.number = "8"
        XCTAssertNil(PlayerPresence.findAnywhere([candidate], memory: mine))
    }


    // MARK: Roster pass state

    func testRosterDiscoversAPlayerKeepsItsIdentityAcrossAHiddenSecondAndRecordsTheGap() {
        var roster = RosterState(start: 0, priors: [])
        let step = 1.0 / 15
        var time = 0.0
        func frame(_ observations: [PlayerObservation]) {
            _ = roster.step(time: time, camera: nil, absolute: nil, observations: observations)
            time += step
        }
        for index in 0..<12 { frame([observation(x: 0.2 + Double(index) * 0.01, color: blue), observation(x: 0.7, color: white)]) }
        XCTAssertEqual(roster.identities.count, 2)
        XCTAssertTrue(roster.identities.allSatisfy { !$0.isProvisional }, "Clear, confirmed bodies become players after half a second")
        let runner = roster.identities.first { $0.memory.similarity(to: observation(x: 0, color: blue)) ?? 0 > 0.9 }!.id
        let hiddenFrom = time
        for _ in 0..<15 { frame([observation(x: 0.7, color: white)]) }
        XCTAssertEqual(roster.identities.count, 2, "A missing player is remembered, not dropped")
        XCTAssertNotNil(roster.identities.first { $0.id == runner }?.missingSince)
        let predicted = roster.identities.first { $0.id == runner }!.expectation(at: time).box!
        XCTAssertGreaterThan(predicted.midX, 0.36, "The runner's motion continues to be predicted while hidden")
        for _ in 0..<3 { frame([observation(x: predicted.minX, color: blue), observation(x: 0.7, color: white)]) }
        let recovered = roster.identities.first { $0.id == runner }!
        XCTAssertNil(recovered.missingSince)
        XCTAssertEqual(recovered.gaps.count, 1)
        XCTAssertEqual(recovered.gaps[0].lowerBound, hiddenFrom - step, accuracy: 0.01)
        XCTAssertEqual(roster.identities.count, 2, "The returning body must not spawn a duplicate player")
        let entries = roster.finish()
        XCTAssertEqual(entries.count, 2)
        let entry = entries.first { $0.id == runner }!
        XCTAssertTrue(entry.isNew)
        XCTAssertEqual(entry.motion.gaps?.count, 1)
        XCTAssertEqual(entry.motion.recoveryCount, 1)
        XCTAssertEqual(entry.motion.gapBridging, PlayerMotion.defaultGapBridging)
        XCTAssertTrue(entry.memory.isConfirmed)
        XCTAssertNil(entry.motion.lostAt)
        XCTAssertNil(entry.motion.box(at: hiddenFrom + 0.4), "A one-second loss is not bridged until positions are stored")
        XCTAssertNil(entry.motion.bridged(camera: nil).box(at: hiddenFrom + 0.4), "Storing a track must not conceal uncertain identity")
    }

    func testRosterUsesSavedPlayersAsPriorsAndTreatsOverlapsConservatively() {
        var prior = PlayerMotion(samples: [.init(time: 0, box: box(x: 0.2)), .init(time: 0.5, box: box(x: 0.25))])
        prior.jerseyProfile = memory(blue).jersey
        let saved = UUID()
        var roster = RosterState(start: 0, priors: [.init(id: saved, motion: prior, memory: memory(blue))])
        XCTAssertEqual(roster.identities.first?.id, saved)
        XCTAssertNil(roster.identities.first?.missingSince, "Visible at the pass start: tracked without recovery gates")
        _ = roster.step(time: 0, camera: nil, absolute: nil, observations: [observation(x: 0.2, color: blue)])
        _ = roster.step(time: 1.0 / 15, camera: nil, absolute: nil, observations: [observation(x: 0.205, color: blue)])
        XCTAssertEqual(roster.identities.first?.samples.count, 2)
        XCTAssertFalse(roster.finish().first?.isNew ?? true)
        var unconfirmed = PlayerJerseyProfile(); unconfirmed.learn(signature(blue), clear: true)
        var weak = prior; weak.jerseyProfile = unconfirmed
        XCTAssertTrue(RosterState(start: 0, priors: [.init(id: UUID(), motion: weak, memory: nil)]).identities.isEmpty,
                      "An unconfirmed kit cannot recognise anyone")
        var later = RosterState(start: 3, priors: [.init(id: saved, motion: prior, memory: memory(blue))])
        XCTAssertNil(later.identities.first?.expectation(at: 3).box, "Not visible at the start: recognised on appearance only")
        var overlapped = observation(x: 0.5, color: blue); overlapped.crowded = true
        _ = later.step(time: 3, camera: nil, absolute: nil, observations: [overlapped])
        XCTAssertTrue(later.identities.first?.samples.isEmpty ?? false)
        XCTAssertEqual(later.identities.count, 1, "Crowded bodies do not start provisional players")
    }

    func testNewSameKitBodyNeverForcesAMergeWithTheOnlyMissingPlayer() {
        var roster = RosterState(start: 0, priors: [])
        var time = 0.0
        func frame(_ observations: [PlayerObservation]) {
            _ = roster.step(time: time, camera: nil, absolute: nil, observations: observations)
            time += 1.0 / 15
        }
        let team = (0..<4).map { 0.15 + Double($0) * 0.2 }
        for _ in 0..<12 { frame(team.map { observation(x: $0, color: blue) }) }
        for _ in 0..<50 { frame(team.dropLast().map { observation(x: $0, color: blue) }) }
        let missing = roster.identities.first { $0.recovering && !$0.isProvisional }!
        let originalSamples = missing.samples
        for _ in 0..<12 { frame((team.dropLast() + [0.84]).map { observation(x: $0, color: blue) }) }
        let preserved = roster.identities.first { $0.id == missing.id }
        XCTAssertNotNil(preserved?.missingSince)
        XCTAssertEqual(preserved?.samples, originalSamples, "A new same-kit body cannot inherit a missing player's ID")
        XCTAssertTrue(roster.identities.contains { $0.id != missing.id && $0.previous.map { abs($0.minX - 0.84) < 0.001 } == true })
    }

    func testCroppedCrowdedAndConflictingBodiesCannotPoisonAnyMemoryCue() {
        var mine = memory(blue)
        for _ in 0..<3 { mine.number.vote("9") }
        let saved = mine
        for kind in 0..<3 {
            var bad = observation(x: 0.3, color: blue)
            bad.print = [0, 1, 0]; bad.number = "8"
            bad.head = signature(red); bad.chroma = signature(white)
            if kind == 0 { bad.box.origin.x = -0.02; bad.number = "9" }
            if kind == 1 { bad.crowded = true; bad.number = "9" }
            mine.learn(bad, clear: true)
            XCTAssertEqual(mine, saved)
        }
    }

    func testReturnSuggestionsKeepDifferentTeammatesInTheSameFrameAndBoundMemory() {
        let image = UIImage()
        let candidates = (0..<4).map { i in
            PlayerReacquisitionCandidate(time: 5, box: box(x: Double(i) * 0.2), score: 0.9, thumbnail: image)
        }
        let duplicate = PlayerReacquisitionCandidate(time: 5.4, box: candidates[0].box, score: 0.89, thumbnail: image)
        let selected = PlayerReacquisitionSearch.diverseCandidates(candidates + [duplicate], limit: 12)
        XCTAssertEqual(selected.count, 4)
        XCTAssertEqual(Set(selected.map(\.id)), Set(candidates.map(\.id)))
        XCTAssertEqual(PlayerReacquisitionSearch.diverseCandidates(candidates, limit: 2).count, 2)
        XCTAssertTrue(PlayerReacquisitionSearch.diverseCandidates(candidates, limit: 0).isEmpty)
    }

    // MARK: Bridging and hand placement

    func testBridgedPositionsAreCameraAwareBoundedAndHoldBrieflyAfterALoss() throws {
        var motion = PlayerMotion(samples: [.init(time: 0.5, box: box(x: 0.28)), .init(time: 1, box: box(x: 0.3)), .init(time: 2.5, box: box(x: 0.5)), .init(time: 3, box: box(x: 0.52))])
        motion.gaps = [(1.0).nextUp...(2.5).nextDown]
        motion.gapBridging = 2 // Explicit user-requested estimate
        XCTAssertNil(motion.box(at: 1.3), "Nothing is bridged before positions are computed")
        let flat = motion.bridged(camera: nil)
        XCTAssertEqual(try XCTUnwrap(flat.box(at: 1.3)).midX, 0.39, accuracy: 0.002)
        XCTAssertEqual(flat.gaps, motion.gaps, "Raw gaps stay recorded")
        XCTAssertTrue(flat.isMissing(at: 1.3))
        let pan = AnnotationCameraMotion(samples: [.init(time: 0, transform: .identity), .init(time: 2, transform: .identity),
                                                   .init(time: 2.5, transform: .init(values: [1, 0, 0.2, 0, 1, 0, 0, 0, 1]))], lostAt: nil)
        let steady = motion.bridged(camera: pan)
        XCTAssertEqual(try XCTUnwrap(steady.box(at: 1.3)).midX, 0.35, accuracy: 0.002,
                       "The later sample only moved because the camera panned; the player stays put")
        var limited = flat; limited.gapBridging = 0.5
        XCTAssertNil(limited.box(at: 1.3))
        var legacy = flat; legacy.gapBridging = nil
        XCTAssertNil(legacy.box(at: 1.3), "Older drawings keep the 0.4-second bridge")
        var lost = PlayerMotion(samples: [.init(time: 0, box: box(x: 0.1)), .init(time: 1, box: box(x: 0.2))])
        lost.lostAt = 1.01; lost.gapBridging = 2
        XCTAssertNil(lost.box(at: 1.5))
        let held = lost.bridged(camera: nil)
        XCTAssertEqual(try XCTUnwrap(held.box(at: 1.5)).midX, 0.25, accuracy: 0.002, "The last position is kept for a moment")
        XCTAssertNil(held.box(at: 2.3), "The hold is bounded")
        let laterPan = AnnotationCameraMotion(samples: [.init(time: 0, transform: .identity), .init(time: 1, transform: .identity),
                                                        .init(time: 2, transform: .init(values: [1, 0, 0.2, 0, 1, 0, 0, 0, 1]))], lostAt: nil)
        XCTAssertEqual(try XCTUnwrap(lost.bridged(camera: laterPan).box(at: 1.5)).midX, 0.35, accuracy: 0.01,
                       "Held positions move with the camera")
        var off = held; off.gapBridging = 0
        XCTAssertNil(off.box(at: 1.5))
    }

    func testHandPlacementSplitsTheGapIsExactAndSurvivesRepairsElsewhere() throws {
        var motion = PlayerMotion(samples: [.init(time: 1, box: box(x: 0.3)), .init(time: 4, box: box(x: 0.6))])
        motion.gaps = [(1.0).nextUp...(4.0).nextDown]; motion.gapBridging = 2; motion.smoothing = 1
        XCTAssertNil(motion.bridged(camera: nil).box(at: 2.5), "A three-second gap is beyond the effect's limit")
        motion.place(box(x: 0.4), at: 2.5)
        XCTAssertEqual(motion.anchors, [2.5])
        XCTAssertEqual(motion.gaps?.count, 2)
        XCTAssertEqual(motion.samples.map(\.time), [1, 2.5, 4])
        let bridged = motion.bridged(camera: nil)
        XCTAssertEqual(try XCTUnwrap(bridged.box(at: 2.5)).midX, box(x: 0.4).midX, accuracy: 0.0001, "The placement is exact, not smoothed")
        XCTAssertEqual(try XCTUnwrap(bridged.box(at: 1.75)).midX, 0.4, accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(bridged.box(at: 3.25)).midX, 0.55, accuracy: 0.002)
        XCTAssertTrue(bridged.isMissing(at: 1.75))
        var lost = PlayerMotion(samples: [.init(time: 0, box: box(x: 0.1))]); lost.lostAt = 0.5
        lost.place(box(x: 0.3), at: 1.5)
        XCTAssertNil(lost.lostAt); XCTAssertEqual(lost.gaps?.count, 1); XCTAssertEqual(lost.samples.count, 2)
        var trailing = PlayerMotion(samples: [.init(time: 0, box: box(x: 0.1))])
        trailing.place(box(x: 0.2), at: 1)
        XCTAssertEqual(trailing.gaps?.first?.lowerBound ?? 0, 0, accuracy: 0.001)
        let repaired = motion.continuing(with: PlayerMotion(samples: [.init(time: 2, box: box(x: 0.35)), .init(time: 3, box: box(x: 0.5))]), from: 2)
        XCTAssertEqual(repaired.anchors, [2.5], "Automatic tracking preserves the manual selection")
        XCTAssertEqual(repaired.gapBridging, 2)
        let elsewhere = motion.continuing(with: PlayerMotion(samples: [.init(time: 3.5, box: box(x: 0.55)), .init(time: 3.8, box: box(x: 0.58))]), from: 3.5)
        XCTAssertEqual(elsewhere.anchors, [2.5])
    }

    func testMissingIntervalsAndGapNavigationCoverLeadInGapsAndTail() {
        var motion = PlayerMotion(samples: [.init(time: 2, box: box(x: 0.3)), .init(time: 5, box: box(x: 0.5))])
        motion.gaps = [3...3.5]; motion.lostAt = 4.5
        let intervals = motion.missingIntervals(in: 0...8)
        XCTAssertEqual(intervals.count, 3)
        XCTAssertEqual(intervals[0].upperBound, 2, accuracy: 0.001); XCTAssertEqual(intervals[1], 3...3.5)
        XCTAssertEqual(intervals[2].lowerBound, 4.5, accuracy: 0.001); XCTAssertEqual(intervals[2].upperBound, 8)
        XCTAssertEqual(motion.nextMissing(after: 0, in: 0...8), 3)
        XCTAssertEqual(motion.nextMissing(after: 3.2, in: 0...8) ?? 0, 4.5, accuracy: 0.001)
        XCTAssertNil(motion.nextMissing(after: 5, in: 0...8))
        XCTAssertEqual(motion.previousMissing(before: 3.2, in: 0...8), 3, "Inside a gap, back goes to its start")
        XCTAssertEqual(motion.previousMissing(before: 3.0, in: 0...8), 0)
        XCTAssertEqual(motion.previousMissing(before: 6, in: 0...8) ?? 0, 4.5, accuracy: 0.001)
        XCTAssertEqual(PlayerMotion(samples: []).missingIntervals(in: 1...2), [1...2])
    }

    // MARK: Library integration and storage

    func testLegacyMotionsAndPlayersDecodeWithoutRosterFields() throws {
        var motion = PlayerMotion(samples: [.init(time: 0, box: box(x: 0.1))])
        motion.anchors = [0]; motion.gapBridging = 2; motion.inferred = [.init(time: 0.5, box: box(x: 0.1))]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(motion)) as? [String: Any])
        for key in ["anchors", "gapBridging", "inferred"] { object.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(PlayerMotion.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.gapBridging); XCTAssertNil(legacy.anchors); XCTAssertNil(legacy.inferred)
        XCTAssertEqual(legacy.bridgeHorizon, 0.4); XCTAssertEqual(legacy.holdSeconds, 0)
        XCTAssertEqual(motion, try JSONDecoder().decode(PlayerMotion.self, from: JSONEncoder().encode(motion)))
        var player = AnalysisTrackingLibrary.Player(id: UUID(), name: "Seven", motion: motion, identity: memory(blue))
        player.identity?.number.counts = ["7": 3]
        let decoded = try JSONDecoder().decode(AnalysisTrackingLibrary.Player.self, from: JSONEncoder().encode(player))
        XCTAssertEqual(decoded, player); XCTAssertEqual(decoded.number, "7"); XCTAssertNotNil(decoded.kitColor)
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(player)) as? [String: Any])
        stored.removeValue(forKey: "identity")
        XCTAssertNil(try JSONDecoder().decode(AnalysisTrackingLibrary.Player.self, from: JSONSerialization.data(withJSONObject: stored)).identity)
    }

    func testMergingARosterKeepsNamesRefreshesDrawingsAndAllowsRemovingUnusedPlayers() throws {
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 6)
        let saved = UUID()
        var old = PlayerMotion(samples: (0..<30).map { .init(time: Double($0) * 0.1, box: box(x: 0.2)) }); old.trackID = saved
        clip.storePlayerTrack(old)
        clip.trackingLibrary?.players[0].name = "Captain"
        var ring = AnalysisAnnotation(tool: .player, points: [box(x: 0.2).origin, .init(x: 0.3, y: 0.7)], start: 0, end: 6)
        ring.playerMotion = old.bound(at: 1)
        clip.annotations = [ring]
        var fresh = PlayerMotion(samples: (0..<50).map { .init(time: Double($0) * 0.1, box: box(x: 0.25)) })
        fresh.gaps = [2.05...2.95]; fresh.gapBridging = PlayerMotion.defaultGapBridging
        var short = PlayerMotion(samples: [.init(time: 0, box: box(x: 0.6)), .init(time: 0.1, box: box(x: 0.6))])
        short.gapBridging = PlayerMotion.defaultGapBridging
        let discovered = UUID()
        let result = PlayerRosterResult(entries: [
            .init(id: saved, motion: fresh, memory: memory(blue), isNew: false),
            .init(id: discovered, motion: short, memory: memory(white), isNew: true),
        ])
        let merged = clip.mergeRoster(result)
        XCTAssertEqual(merged.tracked, 2); XCTAssertEqual(merged.new, 1)
        let players = try XCTUnwrap(clip.trackingLibrary?.players)
        XCTAssertEqual(players.count, 2)
        XCTAssertEqual(players[0].name, "Captain"); XCTAssertEqual(players[0].identity, memory(blue))
        XCTAssertEqual(players[0].motion.samples.count, 50)
        XCTAssertNotNil(players[0].motion.inferred, "Stored tracks carry bridged positions for their gaps")
        XCTAssertEqual(players[1].name, "Player 2")
        XCTAssertEqual(clip.annotations[0].playerMotion?.samples.count, 50, "Drawings follow the refreshed shared track")
        XCTAssertNil(clip.annotations[0].playerMotion?.box(at: 2.5), "New passes hide uncertainty even when refreshing an older effect")
        XCTAssertFalse(clip.canRemovePlayerTrack(saved)); XCTAssertFalse(clip.removePlayerTrack(saved))
        XCTAssertTrue(clip.canRemovePlayerTrack(discovered)); XCTAssertTrue(clip.removePlayerTrack(discovered))
        XCTAssertEqual(clip.trackingLibrary?.players.count, 1)
        // A pass that saw far less than the saved track keeps the saved motion.
        let sparse = PlayerRosterResult(entries: [.init(id: saved, motion: short, memory: memory(red), isNew: false)])
        _ = clip.mergeRoster(sparse)
        XCTAssertEqual(clip.trackingLibrary?.players[0].motion.samples.count, 50)
        XCTAssertEqual(clip.trackingLibrary?.players[0].identity, memory(red))
        XCTAssertTrue(clip.placePlayerSample(trackID: saved, box: box(x: 0.3), at: 5.5))
        XCTAssertEqual(clip.trackingLibrary?.players[0].motion.anchors, [5.5])
        XCTAssertNotNil(clip.annotations[0].playerMotion?.box(at: 5.5))
        clip.setGapBridging(0, layerID: ring.id)
        XCTAssertNil(clip.annotations[0].playerMotion?.box(at: 2.5))
        XCTAssertEqual(clip.trackingLibrary?.players[0].motion.gapBridging, PlayerMotion.defaultGapBridging, "Per-drawing limits leave the source track alone")
    }

    // MARK: Helpers

    func testRosterRerunReusesSavedPositionsAtLateEntryWithoutRecognizingByKitAlone() throws {
        let id = UUID()
        let motion = PlayerMotion(samples: (0..<20).map { .init(time: 5 + Double($0) / 15, box: box(x: 0.3)) })
        var roster = RosterState(start: 0, priors: [.init(id: id, motion: motion, memory: memory(blue))])
        for frame in 0..<100 {
            let t = Double(frame) / 15
            _ = roster.step(time: t, camera: nil, absolute: nil, observations: t >= 5 ? [observation(x: 0.3, color: blue)] : [])
        }
        XCTAssertEqual(roster.finish().map(\.id), [id], "Late saved observations must not produce new identities on each rerun")
        XCTAssertFalse(try XCTUnwrap(roster.finish().first).isNew)
        var wrongKit = RosterState(start: 0, priors: [.init(id: id, motion: motion, memory: memory(blue))])
        for frame in 75..<90 {
            _ = wrongKit.step(time: Double(frame) / 15, camera: nil, absolute: nil, observations: [observation(x: 0.3, color: white)])
        }
        XCTAssertTrue(wrongKit.identities.first { $0.id == id }!.samples.isEmpty, "A saved location cannot override incompatible identity")
    }

    func testHistoricalTracksDoNotExhaustTheActiveRosterBudget() {
        let old = PlayerMotion(samples: [.init(time: 0, box: box(x: 0.2)), .init(time: 1, box: box(x: 0.2))])
        let priors = (0..<48).map { _ in PlayerRosterPrior(id: UUID(), motion: old, memory: memory(blue)) }
        var roster = RosterState(start: 5, priors: priors)
        for frame in 0..<15 {
            _ = roster.step(time: 5 + Double(frame) / 15, camera: nil, absolute: nil, observations: [observation(x: 0.2, color: white)])
        }
        XCTAssertEqual(roster.finish().filter(\.isNew).count, 1, "Historical fragments cannot block a new entrant")
    }

    func testLinkingKeepsTheSourceManualPickOverAnAutomaticDuplicate() throws {
        let automatic = PlayerMotion(samples: [.init(time: 0, box: box(x: 0.2)), .init(time: 1, box: box(x: 0.2))])
        var manual = automatic
        manual.place(box(x: 0.21), at: 1)
        let linked = automatic.linkingObservations(from: manual)
        XCTAssertEqual(linked.samples.last?.box, box(x: 0.21))
        XCTAssertEqual(linked.anchors, [1])
    }

    func testTeamAssignmentsRoundTripAndSurviveRosterRefreshAndRedo() throws {
        for team in PlayerTrackingTeam.allCases {
            let id = UUID()
            var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 6)
            var motion = PlayerMotion(samples: [.init(time: 0, box: box(x: 0.2)), .init(time: 2, box: box(x: 0.2))]); motion.trackID = id
            clip.storePlayerTrack(motion, identity: memory(blue))
            clip.assignPlayerTeam(team, to: id)
            let data = try JSONEncoder().encode(clip.trackingLibrary!)
            let saved = try JSONDecoder().decode(AnalysisTrackingLibrary.self, from: data)
            XCTAssertEqual(saved.players[0].assignedTeam, team)
            _ = clip.mergeRoster(.init(entries: [.init(id: id, motion: motion, memory: memory(blue), isNew: false)]))
            clip.storePlayerTrack(motion.clearingTracking(in: 0...1))
            XCTAssertEqual(clip.trackingLibrary?.players[0].assignedTeam, team)
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var players = legacy["players"] as! [[String: Any]]
            players[0].removeValue(forKey: "team"); legacy["players"] = players
            let decoded = try JSONDecoder().decode(AnalysisTrackingLibrary.self, from: JSONSerialization.data(withJSONObject: legacy))
            XCTAssertEqual(decoded.players[0].assignedTeam, .unassigned)
        }
    }

    func testLinkingPlayerFragmentsPreservesGapsTeamsAndEffectBindings() throws {
        let firstID = UUID(), secondID = UUID()
        var early = PlayerMotion(samples: [.init(time: 0, box: box(x: 0.2)), .init(time: 1, box: box(x: 0.3))])
        early.trackID = firstID; early.lostAt = 1.01; early.anchors = [0]
        var late = PlayerMotion(samples: [.init(time: 3, box: box(x: 0.5)), .init(time: 4, box: box(x: 0.6))])
        late.trackID = secondID; late.anchors = [3]
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 5)
        clip.storePlayerTrack(early, identity: memory(blue)); clip.storePlayerTrack(late, identity: memory(blue))
        clip.assignPlayerTeam(.teamA, to: secondID)
        clip.trackingLibrary?.players[0].name = "Captain"
        var ring = AnalysisAnnotation(tool: .player, points: [.zero, .init(x: 1, y: 1)], start: 3, end: 5)
        ring.playerMotion = late.bound(at: 3); clip.annotations = [ring]
        XCTAssertTrue(clip.linkPlayerTrack(secondID, to: firstID))
        let player = try XCTUnwrap(clip.trackingLibrary?.players.first)
        XCTAssertEqual(clip.trackingLibrary?.players.count, 1)
        XCTAssertEqual(player.id, firstID); XCTAssertEqual(player.name, "Captain"); XCTAssertEqual(player.assignedTeam, .teamA)
        XCTAssertNotNil(player.motion.box(at: 0.5)); XCTAssertNotNil(player.motion.box(at: 3.5))
        XCTAssertNil(player.motion.box(at: 2), "Linking identities does not invent motion across a hidden gap")
        XCTAssertEqual(player.motion.anchors, [0, 3])
        XCTAssertEqual(clip.annotations[0].playerMotion?.trackID, firstID)
        XCTAssertNotNil(clip.annotations[0].playerMotion?.box(at: 3.5))
    }

    func testLinkingRejectsSimultaneouslyVisibleTeammatesAndDifferentTeams() {
        let first = AnalysisTrackingLibrary.Player(id: UUID(), name: "One", motion: .init(samples: [.init(time: 0, box: box(x: 0.2)), .init(time: 1, box: box(x: 0.2))]))
        var second = AnalysisTrackingLibrary.Player(id: UUID(), name: "Two", motion: .init(samples: [.init(time: 0, box: box(x: 0.7)), .init(time: 1, box: box(x: 0.7))]))
        XCTAssertFalse(AnalysisTrackingLibrary(players: [first, second]).canLinkPlayer(first.id, to: second.id))
        second.motion = first.motion
        XCTAssertTrue(AnalysisTrackingLibrary(players: [first, second]).canLinkPlayer(first.id, to: second.id), "Duplicate observations can be linked explicitly")
        var assigned = first; assigned.team = .teamA; second.team = .teamB
        XCTAssertFalse(AnalysisTrackingLibrary(players: [assigned, second]).canLinkPlayer(first.id, to: second.id))
    }

    private func signature(_ color: SIMD3<Float>) -> PlayerJerseySignature {
        PlayerJerseySignature(colors: Array(repeating: color, count: 120))
    }

    private func memory(_ color: SIMD3<Float>) -> PlayerIdentityMemory {
        var memory = PlayerIdentityMemory()
        memory.learn(observation(x: 0.3, color: color), clear: true)
        memory.learn(observation(x: 0.3, color: color), clear: true)
        return memory
    }

    private func observation(x: Double, color: SIMD3<Float>, crowded: Bool = false) -> PlayerObservation {
        PlayerObservation(box: box(x: x), jersey: signature(color), shorts: signature(color), kitColor: color, number: nil, crowded: crowded)
    }

    private func expectation(_ id: UUID, x: Double, color: SIMD3<Float>, recovering: Bool = false, age: Double = 0) -> PlayerRosterAssociation.Expectation {
        .init(id: id, box: box(x: x), memory: memory(color), recovering: recovering, recoveryAge: age)
    }

    private func box(x: Double) -> CGRect { CGRect(x: x, y: 0.5, width: 0.1, height: 0.2) }
}

extension PlayerRosterTests {
    func testConfirmedViewsRejectSameKitWrongAppearanceAndSurviveAutomaticLearning() throws {
        let body = CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.3)
        let blue = PlayerJerseySignature(colors: [SIMD3<Float>(0.1, 0.2, 0.8)])
        var front = PlayerObservation(box: body, jersey: blue, print: [1, 0, 0], time: 1)
        var back = front; back.print = [0, 1, 0]; back.time = 2
        var memory = PlayerIdentityMemory()
        memory.confirm(front, view: .front); memory.confirm(back, view: .back)
        XCTAssertGreaterThan(memory.similarity(to: front) ?? 0, 0.9)
        XCTAssertGreaterThan(memory.similarity(to: back) ?? 0, 0.9)
        var teammate = front; teammate.print = [0, 0, 1]
        XCTAssertEqual(memory.similarity(to: teammate), 0, "The loose automatic bank cannot bypass confirmed appearance")
        let references = memory.confirmedViews
        for _ in 0..<20 { memory.learn(teammate, clear: true) }
        XCTAssertEqual(memory.confirmedViews, references)
        front.time = 3; memory.confirm(front, view: .front)
        XCTAssertEqual(memory.confirmedViews?.count, 2)
        XCTAssertEqual(memory.confirmedViews?.first { $0.view == .front }?.observation.time, 3)
        let data = try JSONEncoder().encode(memory)
        XCTAssertEqual(try JSONDecoder().decode(PlayerIdentityMemory.self, from: data), memory)
    }

    func testManualCorrectionReplacesContaminatedAutomaticKitWithoutLosingConfirmedViews() {
        let box = CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.3)
        let blue = PlayerObservation(box: box, jersey: PlayerJerseySignature(colors: [SIMD3<Float>(0.05, 0.1, 0.8)]))
        let white = PlayerObservation(box: box, jersey: PlayerJerseySignature(colors: [SIMD3<Float>(0.95, 0.95, 0.95)]))
        var memory = PlayerIdentityMemory()
        memory.learn(white, clear: true); memory.learn(white, clear: true)
        XCTAssertLessThan(memory.similarity(to: blue) ?? 0, 0.5)
        memory.confirm(blue, view: .front)
        XCTAssertGreaterThan(memory.similarity(to: blue) ?? 0, 0.9)
        XCTAssertLessThan(memory.similarity(to: white) ?? 1, 0.5)
        for t in 1...20 {
            var observation = blue; observation.time = Double(t)
            memory.confirm(observation)
        }
        XCTAssertEqual(memory.confirmedViews?.count, 12)
        XCTAssertTrue(memory.confirmedViews?.contains { $0.view == .front } == true)
    }

    func testManualNumberSurvivesProvisionalMemoryAndNoisyOCR() {
        var memory = PlayerIdentityMemory(); memory.number.manual = "9"
        for _ in 0..<20 { memory.number.vote("3") }
        XCTAssertEqual(memory.number.confirmed, "9")
        XCTAssertEqual(PlayerIdentityMemory.resuming(memory, jersey: nil).number.confirmed, "9")
        memory.number.manual = nil
        XCTAssertEqual(memory.number.confirmed, "3")
    }

    func testPartialAndCrowdedPicksDoNotTeachIdentity() {
        let jersey = PlayerJerseySignature(colors: [SIMD3<Float>(0.1, 0.2, 0.8)])
        var memory = PlayerIdentityMemory()
        var observation = PlayerObservation(box: CGRect(x: -0.03, y: 0.3, width: 0.1, height: 0.3), jersey: jersey)
        memory.confirm(observation, view: .front)
        XCTAssertNil(memory.confirmedViews)
        observation.box.origin.x = 0.2; observation.crowded = true
        memory.confirm(observation, view: .back)
        XCTAssertNil(memory.confirmedViews)
    }
}


extension PlayerRosterTests {
    func testReadableHairAndSkinRefineSameKitEvenWhenAutomaticCuesMatch() {
        let shirt = PlayerJerseySignature(colors: [SIMD3<Float>(0.1, 0.2, 0.8)])
        let dark = PlayerJerseySignature(colors: [SIMD3<Float>(0.02, 0.02, 0.02)])
        let light = PlayerJerseySignature(colors: [SIMD3<Float>(0.95, 0.95, 0.95)])
        let body = CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.3)
        let reference = PlayerObservation(box: body, jersey: shirt, hair: dark, skin: dark)
        var memory = PlayerIdentityMemory(); memory.confirm(reference, view: .front)
        var other = reference; other.hair = light; other.skin = light
        XCTAssertLessThan(memory.similarity(to: other) ?? 1, 0.74)
        XCTAssertGreaterThan(memory.similarity(to: reference) ?? 0, 0.9)
        other.hair = nil; other.skin = nil
        XCTAssertGreaterThan(memory.similarity(to: other) ?? 0, 0.9, "Invisible parts must not reject a turned or distant player")
    }
}
