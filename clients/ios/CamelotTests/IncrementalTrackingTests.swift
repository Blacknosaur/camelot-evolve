@preconcurrency import AVFoundation
import XCTest
@testable import Camelot

/// The incremental tracking pipeline: sampling rate, splicing a stopped pass
/// back into a saved track, and (on the phone) publication, stopping and
/// re-tracking a middle range on real footage.
final class IncrementalTrackingTests: XCTestCase {
    private let fixture = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")

    // MARK: - Pure logic (runs anywhere)

    func testSamplingIntervalCapsFastSourcesAndKeepsEveryFrameBelowTheCap() {
        // 60 fps footage costs twice as much for no extra accuracy.
        XCTAssertEqual(PlayerTrackingLimits.samplingInterval(sourceFrameRate: 59.94), 1 / 30, accuracy: 1e-9)
        XCTAssertEqual(PlayerTrackingLimits.samplingInterval(sourceFrameRate: 120), 1 / 30, accuracy: 1e-9)
        // At or below the cap every decoded frame is still tracked.
        XCTAssertEqual(PlayerTrackingLimits.samplingInterval(sourceFrameRate: 29.97), 1 / 29.97, accuracy: 1e-9)
        XCTAssertEqual(PlayerTrackingLimits.samplingInterval(sourceFrameRate: 25), 1 / 25, accuracy: 1e-9)
        // A source that reports nothing usable falls back to the cap.
        XCTAssertEqual(PlayerTrackingLimits.samplingInterval(sourceFrameRate: 0), 1 / 30, accuracy: 1e-9)
        XCTAssertEqual(PlayerTrackingLimits.samplingInterval(sourceFrameRate: .nan), 1 / 30, accuracy: 1e-9)
    }

    /// A 60 fps source must be sampled every other frame, so a stride over the
    /// real presentation times halves the work without dropping a beat.
    func testSixtyFramesPerSecondIsSampledEveryOtherFrame() {
        let interval = PlayerTrackingLimits.samplingInterval(sourceFrameRate: 59.94)
        var last: Double?
        var kept = 0
        for index in 0..<120 {
            let time = Double(index) / 59.94
            if let last, time - last < interval - 0.002 { continue }
            last = time; kept += 1
        }
        XCTAssertEqual(kept, 60, "Half the frames of a 60 fps clip")
    }

    private func motion(from: Double, to: Double, rate: Double = 30, x: Double = 0.2) -> PlayerMotion {
        var samples: [PlayerMotionSample] = []
        var time = from
        var index = 0.0
        while time <= to + 1e-9 {
            samples.append(.init(time: time, box: CGRect(x: x + index * 0.001, y: 0.4, width: 0.05, height: 0.15)))
            index += 1; time = from + index / rate
        }
        var result = PlayerMotion(samples: samples, correctionTimes: [from])
        result.trackID = UUID()
        result.gapBridging = PlayerMotion.defaultGapBridging
        return result
    }

    /// The whole point of "re-track from here and stop": the section the pass
    /// covered is replaced, everything before and after it survives.
    func testStoppingAMiddleRangeReplacesOnlyThatSectionAndKeepsTheRest() {
        let saved = motion(from: 0, to: 10, x: 0.2)
        let repaired = motion(from: 4, to: 6, x: 0.6)
        let combined = saved.continuing(with: repaired, from: 4)

        XCTAssertEqual(combined.samples.first?.time ?? .nan, 0, accuracy: 1e-6, "The saved past survives")
        XCTAssertEqual(combined.samples.last?.time ?? .nan, 10, accuracy: 1e-6, "The saved future survives")
        XCTAssertNil(combined.lostAt, "Stopping a middle range is not a loss")
        // Before the range: the original positions.
        XCTAssertEqual(combined.box(at: 2)?.midX ?? .nan, saved.box(at: 2)?.midX ?? .infinity, accuracy: 0.002)
        // Inside: the new pass.
        XCTAssertEqual(combined.box(at: 5)?.midX ?? .nan, repaired.box(at: 5)?.midX ?? .infinity, accuracy: 0.002)
        // After: the original positions again, with no hole at the seam.
        XCTAssertEqual(combined.box(at: 8)?.midX ?? .nan, saved.box(at: 8)?.midX ?? .infinity, accuracy: 0.002)
        XCTAssertFalse(combined.isMissing(at: 6.2), "The seam back into saved tracking is not a gap")
        XCTAssertEqual(combined.correctionTimes?.contains(4), true, "The re-track boundary is protected")
    }

    /// Stopping a forward pass that ran past the end of the saved track simply
    /// ends the track there — it is not recorded as a tracking failure.
    func testStoppingPastTheSavedEndExtendsTheTrackWithoutALoss() {
        let saved = motion(from: 0, to: 4)
        let extended = motion(from: 4, to: 7, x: 0.5)
        let combined = saved.continuing(with: extended, from: 4)
        XCTAssertEqual(combined.samples.last?.time ?? .nan, 7, accuracy: 1e-6)
        XCTAssertNil(combined.lostAt)
        XCTAssertFalse(combined.isMissing(at: 6))
    }

    /// A stopped backward pass joins in front and leaves the rest untouched.
    func testStoppingABackwardPassKeepsEverythingFromTheSeedOn() {
        let saved = motion(from: 5, to: 10, x: 0.2)
        var earlier = motion(from: 3, to: 5, x: 0.7)
        earlier.correctionTimes = [5]
        let combined = saved.prepending(earlier, seed: 5)
        XCTAssertEqual(combined.samples.first?.time ?? .nan, 3, accuracy: 1e-6)
        XCTAssertEqual(combined.samples.last?.time ?? .nan, 10, accuracy: 1e-6)
        XCTAssertEqual(combined.box(at: 4)?.midX ?? .nan, earlier.box(at: 4)?.midX ?? .infinity, accuracy: 0.002)
        XCTAssertEqual(combined.box(at: 8)?.midX ?? .nan, saved.box(at: 8)?.midX ?? .infinity, accuracy: 0.002)
        XCTAssertFalse(combined.isMissing(at: 5.1))
    }

    /// The stored format did not change, so every track saved by an older build
    /// still decodes and still round-trips through the library.
    func testTracksSavedBeforeIncrementalTrackingStillDecode() throws {
        let legacy = """
        {"samples":[{"time":1,"box":[[0.1,0.2],[0.05,0.15]]},{"time":1.1,"box":[[0.11,0.2],[0.05,0.15]]}],
         "lostAt":1.5,"gaps":[[1.2,1.3]],"trackID":"6B8B4567-0000-4000-8000-000000000001","smoothing":0.5}
        """
        let motion = try JSONDecoder().decode(PlayerMotion.self, from: Data(legacy.utf8))
        XCTAssertEqual(motion.samples.count, 2)
        XCTAssertEqual(motion.lostAt ?? .nan, 1.5, accuracy: 1e-9)
        XCTAssertEqual(motion.gaps?.count, 1)
        XCTAssertNil(motion.gapBridging, "An older track keeps the legacy bridge")
        XCTAssertNil(motion.identity)

        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 10)
        clip.storePlayerTrack(motion)
        let stored = try XCTUnwrap(clip.trackingLibrary?.players.first?.motion)
        XCTAssertEqual(stored.samples.map(\.time), motion.samples.map(\.time), "Raw samples are never rewritten")
        XCTAssertEqual(stored.lostAt ?? .nan, 1.5, accuracy: 1e-9)
        let round = try JSONDecoder().decode(PlayerMotion.self, from: JSONEncoder().encode(stored))
        XCTAssertEqual(round.samples, stored.samples)
    }

    // MARK: - Real footage (phone only)

    private func seed(at time: Double, containing point: CGPoint) async throws -> CGRect {
        let detections = try await AnalysisEngine.analyze(url: fixture, range: time...(time + 0.1)) { _ in }
        return try XCTUnwrap(detections.frames.first?.detections.first { $0.rect.contains(point) }?.rect,
                             "No player at the seed point")
    }

    /// Samples must arrive while the pass runs, not only at the end.
    func testTrackingPublishesSamplesWhileItRuns() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision models cannot create an inference context on the simulator")
        #endif
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path()), "Run on the fixture phone")
        let box = try await seed(at: 3, containing: CGPoint(x: 0.394, y: 0.586))
        let updates = Updates()
        let outcome = try await SelectedPlayerTracking.track(url: fixture, seed: box, from: 3, to: 8, checkpoint: { updates.append($0) })
        let published = updates.all
        XCTAssertGreaterThan(published.count, 4, "Progress is published repeatedly, not once at the end")
        let checkpoints = published.compactMap(\.motion)
        XCTAssertGreaterThan(checkpoints.count, 1, "Intermediate checkpoints carry usable motion")
        XCTAssertTrue(zip(checkpoints, checkpoints.dropFirst()).allSatisfy { $0.samples.count <= $1.samples.count },
                      "Each checkpoint only adds to the previous one")
        XCTAssertTrue(zip(published, published.dropFirst()).allSatisfy { $0.time <= $1.time + 1e-9 },
                      "The published frame time moves forward, so the playhead can follow it")
        XCTAssertFalse(outcome.stopped)
        let last = try XCTUnwrap(checkpoints.last)
        XCTAssertLessThanOrEqual(last.samples.count, outcome.motion.samples.count)
    }

    /// Stopping keeps everything tracked so far. This is the behaviour the old
    /// all-or-nothing pass could not offer.
    func testStoppingKeepsThePartialTrack() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision models cannot create an inference context on the simulator")
        #endif
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path()), "Run on the fixture phone")
        let box = try await seed(at: 3, containing: CGPoint(x: 0.394, y: 0.586))
        let updates = Updates()
        let url = fixture
        let worker = Task.detached(priority: .userInitiated) { () -> PlayerTrackingOutcome in
            try await SelectedPlayerTracking.track(url: url, seed: box, from: 3, to: 30, checkpoint: { updates.append($0) })
        }
        // Let it get going, then stop it the way the Stop button does.
        while updates.all.compactMap(\.motion).count < 2, !worker.isCancelled {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        worker.cancel()
        let outcome = try await worker.value
        XCTAssertTrue(outcome.stopped, "A stop is reported as a stop, not an error")
        XCTAssertGreaterThan(outcome.motion.samples.count, 2, "Everything confirmed before the stop is kept")
        let reached = try XCTUnwrap(outcome.motion.samples.last?.time)
        XCTAssertGreaterThan(reached, 3)
        XCTAssertLessThan(reached, 30, "It really did stop early")
        XCTAssertNil(outcome.motion.lostAt, "Stopping while the player is visible is not a loss")
        // The partial is a usable track: positions exist right up to the stop.
        XCTAssertNotNil(outcome.motion.box(at: reached - 0.2))
        XCTAssertFalse(outcome.motion.isMissing(at: reached - 0.2))
    }

    /// Re-tracking a middle range on real footage leaves the rest intact.
    func testRetrackingAMiddleRangeOnFootageKeepsTheRestOfTheTrack() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision models cannot create an inference context on the simulator")
        #endif
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path()), "Run on the fixture phone")
        let box = try await seed(at: 3, containing: CGPoint(x: 0.394, y: 0.586))
        var full = try await SelectedPlayerTracking.track(url: fixture, seed: box, from: 3, to: 9, checkpoint: { _ in }).motion
        full.trackID = UUID()
        let before = try XCTUnwrap(full.box(at: 3.5)), after = try XCTUnwrap(full.box(at: 8.5))
        let middleSeed = try XCTUnwrap(full.box(at: 5))

        let redone = try await SelectedPlayerTracking.track(url: fixture, seed: middleSeed, from: 5, to: 6.5, prior: full, checkpoint: { _ in })
        let combined = full.continuing(with: redone.motion, from: 5)

        XCTAssertEqual(combined.samples.first?.time ?? .nan, full.samples.first?.time ?? .infinity, accuracy: 1e-6)
        XCTAssertEqual(combined.box(at: 3.5)?.midX ?? .nan, before.midX, accuracy: 0.002, "The past is untouched")
        XCTAssertEqual(combined.box(at: 8.5)?.midX ?? .nan, after.midX, accuracy: 0.002, "The future is untouched")
        XCTAssertFalse(combined.isMissing(at: 5.7), "The re-tracked range is covered")
        XCTAssertFalse(combined.isMissing(at: 7), "There is no hole after the re-tracked range")
    }

    /// Backward and forward passes over the same span must agree.
    func testBackwardAgreesWithForwardOverTheSameSpan() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision models cannot create an inference context on the simulator")
        #endif
        try XCTSkipIf(!FileManager.default.fileExists(atPath: fixture.path()), "Run on the fixture phone")
        let box = try await seed(at: 3, containing: CGPoint(x: 0.394, y: 0.586))
        let forward = try await SelectedPlayerTracking.track(url: fixture, seed: box, from: 3, to: 8, checkpoint: { _ in }).motion
        let anchor = try XCTUnwrap(forward.box(at: 8))
        let backward = try await SelectedPlayerTracking.track(url: fixture, seed: anchor, from: 8, to: 3,
                                                              direction: .backward, checkpoint: { _ in }).motion
        var compared = 0, agreed = 0
        for time in stride(from: 3.2, through: 7.8, by: 0.2) {
            guard let a = forward.box(at: time), let b = backward.box(at: time),
                  !forward.isMissing(at: time), !backward.isMissing(at: time) else { continue }
            compared += 1
            if PlayerTracker.overlap(a, b) > 0.4 { agreed += 1 }
        }
        Swift.print("forward/backward agreement \(agreed)/\(compared)")
        XCTAssertGreaterThan(compared, 8, "Backward tracking reached most of the span")
        XCTAssertGreaterThanOrEqual(Double(agreed), Double(compared) * 0.8)
    }
}

/// Collects what a pass publishes, from whatever thread reports it.
private final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PlayerTrackingCheckpoint] = []
    func append(_ update: PlayerTrackingCheckpoint) { lock.lock(); storage.append(update); lock.unlock() }
    var all: [PlayerTrackingCheckpoint] { lock.lock(); defer { lock.unlock() }; return storage }
}
