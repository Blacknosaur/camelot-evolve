@preconcurrency import AVFoundation
import XCTest
import UIKit
@testable import Camelot

/// Real stress footage on the fixture phone: the shared roster pass must keep
/// the blue runner's identity across the pan that hides it, agree with the
/// single-player tracker where both see the player, and stay usable
/// in wall-clock time for a whole clip.
final class PlayerRosterFootageTests: XCTestCase {
    private let fixture = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")

    @MainActor
    func testFullSquadCountAndRepeatPassOnSoccerFootage() async throws {
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path), "Run on fixture phone")
        let camera = try await CameraMotionTracking.track(url: fixture, from: 0, to: 32.5) { _ in }
        let result = try await PlayerRosterTracking.track(url: fixture, from: 0, to: 32.5, priors: [], camera: camera) { _ in }
        let peak = stride(from: 0.0, through: 32.4, by: 0.1).map { t in
            result.entries.filter { !$0.motion.isMissing(at: t) && $0.motion.box(at: t) != nil }.count
        }.max() ?? 0
        print("SQUAD_RESULT tracks=\(result.entries.count) peakVisible=\(peak) elapsed=\(result.elapsed)")
        for (index, entry) in result.entries.enumerated() {
            print("SQUAD_TRACK \(index + 1) first=\(entry.motion.samples.first!.time) last=\(entry.motion.samples.last!.time) samples=\(entry.motion.samples.count) gaps=\(entry.motion.gaps?.count ?? 0)")
        }
        let carrier = try XCTUnwrap(result.entries.filter { ($0.motion.samples.first?.time ?? 1) < 0.01 }
            .min { a, b in
                func distance(_ entry: PlayerRosterResult.Entry) -> Double {
                    let box = entry.motion.samples[0].box
                    return hypot(box.midX - 0.328, box.maxY - 0.546)
                }
                return distance(a) < distance(b)
            })
        // Source-frame checks of one identity, not just a lower fragment count.
        // The rejected pending-hint experiment hid this runner at 12 s and
        // restarted him under a different ID, despite a lower aggregate count.
        for (t, x) in [(6.5, 0.666), (9.8, 0.614), (12.0, 0.504), (18.0, 0.570)] {
            let body = try XCTUnwrap(carrier.motion.box(at: t), "Preserve the original blue runner at \(t)s")
            XCTAssertEqual(body.midX, x, accuracy: 0.03, "Original blue runner at \(t)s, not a teammate or white opponent")
        }
        let source = FieldFrameSource(url: fixture)
        for times in [[0.7, 3.0, 6.5, 9.8], [12.0, 18.0, 25.5, 30.0]] {
            var frames: [(Double, CGImage)] = []
            for t in times { frames.append((t, try await source.image(at: t, maximumSize: 960))) }
            let sheet = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 540 * frames.count)).image { context in
                for (row, frame) in frames.enumerated() {
                    let y = CGFloat(row * 540)
                    UIImage(cgImage: frame.1).draw(in: CGRect(x: 0, y: y, width: 960, height: 540))
                    for (index, entry) in result.entries.enumerated() {
                        guard !entry.motion.isMissing(at: frame.0), let box = entry.motion.box(at: frame.0) else { continue }
                        let rect = CGRect(x: box.minX * 960, y: y + box.minY * 540, width: box.width * 960, height: box.height * 540)
                        context.cgContext.setStrokeColor(UIColor.systemYellow.cgColor); context.cgContext.setLineWidth(2)
                        context.cgContext.stroke(rect)
                        ("\(index + 1)" as NSString).draw(at: CGPoint(x: rect.minX, y: rect.minY - 15), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 14), .foregroundColor: UIColor.yellow, .backgroundColor: UIColor.black])
                    }
                    ("Squad · \(frame.0)s" as NSString).draw(at: CGPoint(x: 12, y: y + 12), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.white])
                }
            }
            let attachment = XCTAttachment(image: sheet); attachment.name = "Full squad \(times[0])"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let priors = result.entries.map { PlayerRosterPrior(id: $0.id, motion: $0.motion, memory: $0.memory) }
        let again = try await PlayerRosterTracking.track(url: fixture, from: 0, to: 8, priors: priors, camera: camera) { _ in }
        print("SQUAD_REPEAT recognized=\(again.entries.filter { !$0.isNew }.count) new=\(again.entries.filter(\.isNew).count)")
        XCTAssertEqual(again.entries.filter(\.isNew).count, 0, "Rerunning this covered section must not add duplicate identities")
        XCTAssertLessThan(result.elapsed, 65, "Keep the complete squad pass below twice the clip duration on the fixture phone")
        XCTAssertGreaterThan(peak, 5)
    }

    @MainActor
    func testRosterPassFollowsTheStressRunnerAndAgreesWithSingleTracking() async throws {
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path), "Run on fixture phone")
        let detections = try await AnalysisEngine.analyze(url: fixture, range: 3...3.1) { _ in }
        let seed = try XCTUnwrap(detections.frames.first?.detections.first { $0.rect.contains(.init(x: 0.394, y: 0.586)) }?.rect)
        PlayerTrackingLimits.trace = { line in
            let parts = line.split(separator: " ")
            if let t = Double(parts.first ?? ""), t >= 8.0, t <= 10.5 { print("  RTRACE \(line)") }
        }
        defer { PlayerTrackingLimits.trace = nil }
        let single = try await SelectedPlayerTracking.track(url: fixture, seed: seed, from: 3, to: 12.7) { _ in }
        if !single.isMissing(at: 9.8), let body = single.box(at: 9.8) {
            XCTAssertEqual(body.midX, 0.614, accuracy: 0.03,
                           "Source-frame review: blue ball carrier, not the white defender at x=0.564")
        }
        let camera = try await CameraMotionTracking.track(url: fixture, from: 3, to: 12.7) { _ in }
        print("Camera track: \(camera.samples.count) samples, lost=\(String(describing: camera.lostAt))")
        let result = try await PlayerRosterTracking.track(url: fixture, from: 3, to: 12.7, priors: [], camera: camera) { _ in }
        let span = 9.7
        print("Roster pass: \(result.entries.count) players, \(result.detectionFrames) detection frames, \(String(format: "%.2f", result.elapsed)) s for \(span) s of footage")
        for entry in result.entries {
            let motion = entry.motion
            print("  \(entry.id.uuidString.prefix(8)) samples=\(motion.samples.count) gaps=\(motion.gaps?.count ?? 0) lost=\(motion.lostAt.map { String(format: "%.2f", $0) } ?? "-") number=\(entry.memory.number.confirmed ?? "-")")
        }
        XCTAssertLessThan(result.elapsed, span * 4, "A whole-clip pass must remain practical on the phone")
        XCTAssertGreaterThanOrEqual(result.entries.count, 2)
        func agreement(_ motion: PlayerMotion) -> (agreed: Int, compared: Int) {
            var agreed = 0, compared = 0
            // Compare shared coverage before the separately source-checked tackle.
            for time in stride(from: 3.0, through: 9.4, by: 0.2) {
                guard let reference = single.box(at: time), let box = motion.box(at: time), !motion.isMissing(at: time) else { continue }
                compared += 1
                if PlayerTracker.overlap(reference, box) > 0.4 { agreed += 1 }
            }
            return (agreed, compared)
        }
        for entry in result.entries {
            let first = entry.motion.samples.first!, score = agreement(entry.motion)
            print("  \(entry.id.uuidString.prefix(8)) from=\(String(format: "%.2f", first.time)) to=\(String(format: "%.2f", entry.motion.samples.last!.time)) at=\(String(format: "%.3f,%.3f", first.box.midX, first.box.maxY)) agree=\(score.agreed)/\(score.compared)")
        }
        for entry in result.entries {
            let anchor = entry.memory.jersey.examples.first
            let kit = entry.memory.kitColor.flatMap { $0.count == 3 ? SIMD3<Float>($0[0], $0[1], $0[2]) : nil }
            let kin = result.entries.filter { other in
                other.id != entry.id && anchor.map { (other.memory.similarity(to: PlayerObservation(box: .zero, jersey: $0, kitColor: kit)) ?? 0) >= 0.8 } == true
            }.count
            let rgb = entry.memory.kitColor.map { String(format: "%.2f,%.2f,%.2f", $0[0], $0[1], $0[2]) } ?? "-"
            print("  kit \(entry.id.uuidString.prefix(8)) rgb=\(rgb) sameKit=\(kin)")
        }
        let runner = try XCTUnwrap(result.entries.max { agreement($0.motion).agreed < agreement($1.motion).agreed },
                                   "The seeded runner must be one of the discovered players")
        let (agreed, compared) = agreement(runner.motion)
        print("  RUNNER gaps=\(runner.motion.gaps ?? []) recoveries=\(runner.motion.recoveryCount ?? 0)")
        for sample in runner.motion.samples where sample.time >= 8.3 && sample.time <= 9.0 {
            print(String(format: "  RUNNERBOX t=%.3f x=%.3f feet=%.3f w=%.3f", sample.time, sample.box.midX, sample.box.maxY, sample.box.width))
        }
        for time in stride(from: 3.0, through: 9.4, by: 0.2) {
            guard let reference = single.box(at: time), let box = runner.motion.box(at: time), PlayerTracker.overlap(reference, box) <= 0.4 else { continue }
            print(String(format: "  DISAGREE t=%.1f single=%.3f,%.3f w%.3f h%.3f roster=%.3f,%.3f w%.3f h%.3f missing=%d", time, reference.midX, reference.maxY, reference.width, reference.height, box.midX, box.maxY, box.width, box.height, runner.motion.isMissing(at: time) ? 1 : 0))
        }
        for time in stride(from: 9.0, through: 12.6, by: 0.2) {
            let a = single.box(at: time), b = runner.motion.box(at: time)
            print(String(format: "  t=%.1f single=%@ roster=%@ missing=%d", time, a.map { String(format: "%.3f,%.3f h%.3f", $0.midX, $0.maxY, $0.height) } ?? "-", b.map { String(format: "%.3f,%.3f h%.3f", $0.midX, $0.maxY, $0.height) } ?? "-", runner.motion.isMissing(at: time) ? 1 : 0))
        }
        print("  runner \(runner.id.uuidString.prefix(8)) agreement with single tracking: \(agreed)/\(compared)")
        XCTAssertGreaterThan(compared, 20)
        XCTAssertGreaterThan(Double(agreed) / Double(max(1, compared)), 0.9, "The roster identity must follow the same body as single-player tracking")
        // A fixed team-size cap used to reward forced same-kit merges. Keep
        // reporting fragment count, but reject the actual observed ID switch:
        // source-frame review places the blue carrier at x≈0.614 at 9.8 s;
        // the white defender at x≈0.564 must not inherit this saved identity.
        if !runner.motion.isMissing(at: 9.8), let body = runner.motion.box(at: 9.8) {
            XCTAssertEqual(body.midX, 0.614, accuracy: 0.03,
                           "The blurred pan must not switch this identity to the white defender")
        }
        for time in [5.0, 9.0] {
            XCTAssertNotNil(runner.motion.bridged(camera: camera).box(at: time), "Runner should be followed or bridged at \(time)s")
        }
        // Coverage must reach the pan. The source-frame checks above evaluate
        // the later tackle independently; agreement between two trackers alone
        // cannot prove that either one still follows the selected player.
        XCTAssertGreaterThan(runner.motion.samples.last?.time ?? 0, 9.3)
        XCTAssertEqual(Set(result.entries.map(\.id)).count, result.entries.count)
        // A second pass with the first roster as priors keeps the same ids.
        let priors = result.entries.map { PlayerRosterPrior(id: $0.id, motion: $0.motion, memory: $0.memory) }
        let again = try await PlayerRosterTracking.track(url: fixture, from: 3, to: 6, priors: priors, camera: camera) { _ in }
        let recognised = again.entries.filter { !$0.isNew }
        print("  second pass recognised \(recognised.count) of \(priors.count) saved players, \(again.entries.count - recognised.count) new")
        XCTAssertTrue(again.entries.contains { $0.id == runner.id }, "A saved player is recognised again by its kit, not re-created")
    }

    @MainActor
    func testBackwardTrackingAgreesWithForwardTrackingOnTheStressRunner() async throws {
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path), "Run on fixture phone")
        let detections = try await AnalysisEngine.analyze(url: fixture, range: 3...3.1) { _ in }
        let seed = try XCTUnwrap(detections.frames.first?.detections.first { $0.rect.contains(.init(x: 0.394, y: 0.586)) }?.rect)
        let forward = try await SelectedPlayerTracking.track(url: fixture, seed: seed, from: 3, to: 9) { _ in }
        let seedTime = 8.0
        let late = try XCTUnwrap(forward.box(at: seedTime))
        let began = Date()
        let backward = try await SelectedPlayerTracking.trackBackward(url: fixture, seed: late, from: seedTime, to: 3) { _ in }
        print("Backward pass: \(backward.samples.count) samples in \(String(format: "%.2f", Date().timeIntervalSince(began))) s, first=\(backward.samples.first?.time ?? -1) gaps=\(backward.gaps ?? [])")
        XCTAssertNil(backward.lostAt)
        XCTAssertEqual(backward.samples.last?.time ?? 0, seedTime, accuracy: 0.05)
        XCTAssertTrue(zip(backward.samples, backward.samples.dropFirst()).allSatisfy { $0.time < $1.time }, "Samples are in source-time order")
        var agreed = 0, compared = 0
        for time in stride(from: 3.2, through: 7.8, by: 0.2) {
            guard let a = forward.box(at: time), let b = backward.box(at: time) else { continue }
            compared += 1
            if PlayerTracker.overlap(a, b) > 0.4 { agreed += 1 }
        }
        print("  backward agreement with forward: \(agreed)/\(compared)")
        XCTAssertGreaterThan(compared, 15)
        XCTAssertGreaterThan(Double(agreed) / Double(max(1, compared)), 0.85)
        let whole = PlayerMotion(samples: forward.samples.filter { $0.time >= seedTime }).prepending(backward, seed: seedTime)
        XCTAssertEqual(whole.samples.first?.time ?? 0, backward.samples.first?.time ?? -1, accuracy: 0.001)
        XCTAssertNotNil(whole.box(at: 5)); XCTAssertNotNil(whole.box(at: 8.5))
    }

    /// Saved stress project, 15 September 2026: the blue player tracked as
    /// "Player 2" jumped onto the white player running past behind him at
    /// 13.07 s. Under the floodlights the hue histogram read both kits as
    /// neutral; chromaticity must keep the track on the blue shirt.
    @MainActor
    func testBlueRunnerStaysBlueWhenAWhitePlayerCrossesBehindHim() async throws {
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path), "Run on fixture phone")
        let seed = CGRect(x: 0.430, y: 0.774, width: 0.028, height: 0.119)
        let motion = try await SelectedPlayerTracking.track(url: fixture, seed: seed, from: 12.8, to: 15.5, confirmedSeed: true) { _ in }
        for time in stride(from: 12.9, through: 15.4, by: 0.1) {
            let box = motion.box(at: time)
            print(String(format: "  t=%.1f box=%@", time, box.map { String(format: "%.3f,%.3f w%.3f h%.3f feet=%.3f", $0.minX, $0.minY, $0.width, $0.height, $0.maxY) } ?? "-"))
        }
        // Saved (wrong) track at 13.07: x 0.430, y 0.686, w 0.053, h 0.145 (the white player).
        // The blue player at 13.03: x 0.415, y 0.750, w 0.030, h 0.137, feet 0.887.
        for time in [13.1, 13.2, 13.3, 13.8, 13.9, 14.0] {
            guard let box = motion.box(at: time) else { continue }
            XCTAssertLessThan(box.width, 0.040, "At \(time)s the tracked body is the narrower blue player, not the white one")
            XCTAssertGreaterThan(box.maxY, 0.82, "At \(time)s the feet stay near the blue player's line, not the white player's")
        }
        XCTAssertNotNil(motion.box(at: 14.0), "The blue player is picked up again after the overlap")
        XCTAssertTrue(motion.identity?.chroma?.isConfirmed == true)
    }

    /// Saved stress project, 15 September 2026, "Player 3": the blue ball
    /// carrier tackled by a white defender at 9.3–9.9 s; the saved track went
    /// blue → white → blue. From a clean seed on the blue player at 8.5 s the
    /// track must stay on a blue body or hide, never sit on the white defender.
    @MainActor
    func testBlueBallCarrierIsNotHandedToTheWhiteDefenderInATackle() async throws {
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path), "Run on fixture phone")
        // Seeded on a clean frame a second before the tackle, as a user would.
        let seed = CGRect(x: 0.579, y: 0.653, width: 0.034, height: 0.101)
        PlayerTrackingLimits.trace = { line in print("  TRACE \(line)") }
        defer { PlayerTrackingLimits.trace = nil }
        let motion = try await SelectedPlayerTracking.track(url: fixture, seed: seed, from: 7.5, to: 10.8, confirmedSeed: true) { _ in }
        for time in stride(from: 7.6, through: 10.7, by: 0.1) {
            let box = motion.box(at: time)
            print(String(format: "  TACKLE t=%.1f box=%@", time, box.map { String(format: "%.3f,%.3f w%.3f h%.3f", $0.minX, $0.minY, $0.width, $0.height) } ?? "-"))
        }
        print("  gallery references: \(motion.identity?.gallery?.prints.count ?? 0), gate \(motion.identity?.gallery?.gate ?? 0), lost=\(String(describing: motion.lostAt)) samples=\(motion.samples.count) gaps=\(motion.gaps ?? [])")
        XCTAssertGreaterThan(motion.samples.count, 40)
        // Through the tackle the two bodies overlap; what matters is who the
        // track leaves with. The blue carrier runs right (x ≈ 0.60–0.66 by
        // 10.0–10.2 s); the white defender stays around x 0.53.
        for time in [10.0, 10.1, 10.2] {
            let box = try XCTUnwrap(motion.box(at: time), "Tracked at \(time)s")
            XCTAssertGreaterThan(box.minX, 0.58, "At \(time)s the track left the tackle with the blue carrier")
            XCTAssertLessThan(box.width, 0.06)
        }
    }


    /// Miguel's saved project, 15 September 2026 21:41: a blue player seeded on
    /// the first frame at 11 × 50 px (1280 wide) was lost at 5.63 s and never
    /// recovered, because every recovery gate scaled with the body width and
    /// two widths were 22 px. With a minimum gate size the track continues
    /// through the recovery at 6 s and the tackle at 9.5 s, staying blue.
    @MainActor
    func testDistantBluePlayerSeededOnTheFirstFrameIsTrackedThroughRecoveryAndTackle() async throws {
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path), "Run on fixture phone")
        let seed = CGRect(x: 0.322, y: 0.496, width: 0.011, height: 0.050)
        let motion = try await SelectedPlayerTracking.track(url: fixture, seed: seed, from: 0, to: 14, confirmedSeed: true) { _ in }
        print("  DISTANT last=\(motion.samples.last?.time ?? -1) lost=\(String(describing: motion.lostAt)) gaps=\(motion.gaps ?? []) samples=\(motion.samples.count)")
        XCTAssertNil(motion.lostAt)
        XCTAssertNil(motion.identity?.confirmedViews?.first?.observation.print, "Tiny reference bodies must not become unreliable appearance gates")
        XCTAssertGreaterThan(motion.samples.count, 300)
        let mid = try XCTUnwrap(motion.box(at: 6.5))
        XCTAssertEqual(mid.midX, 0.666, accuracy: 0.03); XCTAssertEqual(mid.maxY, 0.736, accuracy: 0.03)
        let late = try XCTUnwrap(motion.box(at: 13.9))
        XCTAssertLessThan(late.width, 0.06)
        XCTAssertLessThanOrEqual((motion.gaps ?? []).map { $0.upperBound - $0.lowerBound }.max() ?? 0, 1.0, "No long hidden section")
    }

    /// Miguel's saved project, 15 September 2026 23:08: a white player runs
    /// across in front of the tracked blue player at 25.8 s and the track went
    /// with the white one. Seeded on the blue player alone at 24.0 s.
    @MainActor
    func testBluePlayerStaysBlueWhenAWhitePlayerRunsAcrossInFront() async throws {
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path), "Run on fixture phone")
        // Same flow as the saved project: the first-frame seed over the clip.
        let seed = CGRect(x: 0.322, y: 0.496, width: 0.011, height: 0.050)
        PlayerTrackingLimits.trace = { line in if line.hasPrefix("5.") || line.hasPrefix("6.") { print("DISTANT_TRACE \(line)") } }; defer { PlayerTrackingLimits.trace = nil }
        PlayerTrackingLimits.trace = { line in
            if let t = Double(line.split(separator: " ").first ?? ""), t >= 25.0, t <= 27.6 { print("  FRONT_TRACE \(line)") }
        }
        defer { PlayerTrackingLimits.trace = nil }
        let motion = try await SelectedPlayerTracking.track(url: fixture, seed: seed, from: 0, to: 28.5) { _ in }
        for time in stride(from: 25.4, through: 28.4, by: 0.1) {
            let box = motion.box(at: time)
            print(String(format: "  FRONT t=%.1f box=%@ missing=%d", time, box.map { String(format: "%.3f,%.3f w%.3f h%.3f", $0.midX, $0.maxY, $0.width, $0.height) } ?? "-", motion.isMissing(at: time) ? 1 : 0))
        }
        print("  FRONT_RESULT lost=\(String(describing: motion.lostAt)) gaps=\(motion.gaps ?? [])")
        // The white player at 27.5 s in the saved track: x 0.801, w 0.026; the blue player is left of him.
        for time in [27.0, 27.5, 28.0] {
            let box = try XCTUnwrap(motion.box(at: time), "Recover the blue carrier after the crossing")
            XCTAssertEqual(box.midX, 0.740, accuracy: 0.025, "At \(time)s keep the original carrier, not the white defender or right-wing teammate")
            XCTAssertLessThan(box.maxY, 0.635)
        }
    }
}

extension PlayerRosterFootageTests {
    @MainActor
    func testConfirmedFixOnSoccerVideoReplacesWrongKitAndRunsPastOldRejoin() async throws {
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path), "Run on fixture phone")
        let detections = try await AnalysisEngine.analyze(url: fixture, range: 3...3.1) { _ in }
        let seed = try XCTUnwrap(detections.frames.first?.detections.first { $0.rect.contains(.init(x: 0.394, y: 0.586)) }?.rect)
        let original = try await SelectedPlayerTracking.track(url: fixture, seed: seed, from: 3, to: 9) { _ in }
        var wrongMemory = PlayerIdentityMemory()
        // Full observed kit cues matter under floodlights: hue alone merges
        // pale blue and white, while chromaticity keeps them separate.
        let white = PlayerObservation(box: seed, jersey: PlayerJerseySignature(colors: [SIMD3<Float>(0.95, 0.95, 0.95)]),
                                      chroma: PlayerJerseySignature(chromaOf: [SIMD3<Float>(0.95, 0.95, 0.95)]))
        wrongMemory.learn(white, clear: true); wrongMemory.learn(white, clear: true)
        var prior = original; prior.identity = wrongMemory; prior.jerseyProfile = wrongMemory.jersey
        PlayerTrackingLimits.trace = { line in
            if let t = Double(line.split(separator: " ").first ?? ""), t >= 5.7, t <= 7 { print("REPAIR_TRACE \(line)") }
        }
        defer { PlayerTrackingLimits.trace = nil }
        let start = CFAbsoluteTimeGetCurrent()
        let repaired = try await SelectedPlayerTracking.track(url: fixture, seed: seed, from: 3, to: 9,
            prior: prior, confirmedSeed: true, checkpoint: { _ in })
        print("Confirmed soccer repair: \(CFAbsoluteTimeGetCurrent() - start)s, \(repaired.motion.samples.count) frames")
        XCTAssertGreaterThan(repaired.motion.samples.last?.time ?? 0, 8.5, "A forward pass must not stop after briefly rejoining old motion")
        XCTAssertEqual(repaired.motion.identity?.confirmedViews?.count, 1)
        for t in [4.0, 5, 6, 7] {
            let expected = try XCTUnwrap(original.box(at: t))
            let actual = try XCTUnwrap(repaired.motion.box(at: t), "Lost the manually confirmed blue player at \(t)")
            XCTAssertGreaterThan(PlayerTracker.overlap(expected, actual), 0.5)
        }
        let whiteBox = try XCTUnwrap(detections.frames.first?.detections.first { $0.rect.contains(.init(x: 0.115, y: 0.788)) }?.rect)
        let observedWhite = try await PlayerAppearancePrinter.reference(url: fixture, box: whiteBox, at: 3)
        var remembered = try XCTUnwrap(repaired.motion.identity)
        let before = remembered
        XCTAssertLessThan(remembered.similarity(to: observedWhite) ?? 1, 0.74, "The source-checked white opponent must not qualify for learning")
        remembered.learn(observedWhite, clear: true)
        XCTAssertEqual(remembered, before, "The white opponent cannot contaminate the corrected memory")
        let source = FieldFrameSource(url: fixture)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 720, height: 405 * 4))
        var frames: [(Double, CGImage)] = []
        for t in [3.0, 5, 6.5, 8] { frames.append((t, try await source.image(at: t, maximumSize: 720))) }
        let sheet = renderer.image { context in
            for (index, frame) in frames.enumerated() {
                let origin = CGFloat(index) * 405
                UIImage(cgImage: frame.1).draw(in: CGRect(x: 0, y: origin, width: 720, height: 405))
                if let body = repaired.motion.box(at: frame.0) {
                    context.cgContext.setStrokeColor(UIColor.green.cgColor); context.cgContext.setLineWidth(2)
                    context.cgContext.stroke(CGRect(x: body.minX * 720, y: origin + body.minY * 405, width: body.width * 720, height: body.height * 405))
                }
                ("Confirmed repair · \(frame.0)s" as NSString).draw(at: CGPoint(x: 12, y: origin + 12),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18), .foregroundColor: UIColor.white])
            }
        }
        let attachment = XCTAttachment(image: sheet); attachment.name = "Confirmed blue player repair on soccer footage"
        attachment.lifetime = .keepAlways; add(attachment)
    }
}

extension PlayerRosterFootageTests {
    @MainActor
    func testManuallySelectedWhitePlayerKeepsItsMotionIdentityAmongWhiteTeammates() async throws {
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path), "Run on fixture phone")
        // Source-checked foreground white player: detection 3 at 0 s, 2 at 1 s.
        let seed = CGRect(x: 0.0784149, y: 0.582428, width: 0.0212952, height: 0.0831909)
        let result = try await SelectedPlayerTracking.track(url: fixture, seed: seed, from: 0, to: 1.3,
                                                            confirmedSeed: true) { _ in }
        let actual = try XCTUnwrap(result.box(at: 1))
        let expected = CGRect(x: 0.103848, y: 0.626251, width: 0.0257996, height: 0.090271)
        XCTAssertGreaterThan(PlayerTracker.overlap(actual, expected), 0.5)
        XCTAssertEqual(actual.midX, expected.midX, accuracy: 0.012)
    }
}


extension PlayerRosterFootageTests {
    @MainActor
    func testTemporalContinuityAcrossTheFullSoccerClip() async throws {
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path), "Run on fixture phone")
        PlayerTrackingLimits.trace = { line in
            if let t = Double(line.split(separator: " ").first ?? ""), t >= 21.5 { print("TEMPORAL_TRACE \(line)") }
        }
        defer { PlayerTrackingLimits.trace = nil }
        let started = CFAbsoluteTimeGetCurrent()
        let motion = try await SelectedPlayerTracking.track(url: fixture,
            seed: CGRect(x: 0.322, y: 0.496, width: 0.011, height: 0.050),
            from: 0, to: 32.5, confirmedSeed: true) { _ in }
        print("TEMPORAL_RESULT elapsed=\(CFAbsoluteTimeGetCurrent() - started) last=\(motion.samples.last?.time ?? -1) lost=\(String(describing: motion.lostAt)) gaps=\(motion.gaps ?? [])")
        // Source-checked original carrier stops near x=.69 after 25 s. The
        // first implementation outran him and took the blue teammate at x=.98.
        // A later overlap must not hand him to the white defender at x=.78–.83.
        for (t, x) in [(25.5, 0.696), (27.0, 0.740), (28.0, 0.739), (30.0, 0.750)] {
            let body = try XCTUnwrap(motion.box(at: t), "Recover the original player at \(t)s")
            XCTAssertEqual(body.midX, x, accuracy: 0.025, "Stay with the original blue carrier at \(t)s")
        }
        let source = FieldFrameSource(url: fixture)
        let times = [21.5, 22, 22.5, 23, 23.5, 24, 24.5, 25, 26, 27, 28, 30]
        for start in stride(from: 0, to: times.count, by: 4) {
            var frames: [(Double, CGImage)] = []
            for t in times[start..<min(start + 4, times.count)] { frames.append((t, try await source.image(at: t, maximumSize: 960))) }
            let sheet = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 540 * frames.count)).image { context in
                for (index, frame) in frames.enumerated() {
                    let y = CGFloat(index * 540)
                    UIImage(cgImage: frame.1).draw(in: CGRect(x: 0, y: y, width: 960, height: 540))
                    if let box = motion.box(at: frame.0) {
                        context.cgContext.setStrokeColor(UIColor.green.cgColor); context.cgContext.setLineWidth(3)
                        context.cgContext.stroke(CGRect(x: box.minX * 960, y: y + box.minY * 540, width: box.width * 960, height: box.height * 540))
                    }
                    ("Temporal \(frame.0)s · \(motion.isMissing(at: frame.0) ? "missing" : "tracked")" as NSString).draw(at: CGPoint(x: 12, y: y + 12), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.white])
                }
            }
            let attachment = XCTAttachment(image: sheet); attachment.name = "Temporal continuity \(start)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
