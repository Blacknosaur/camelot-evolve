@preconcurrency import AVFoundation
import CoreGraphics
import XCTest
import UIKit
@testable import Camelot

/// The blue number 9 in the bottom-left of the May 11 stress recording.
///
/// He is visible from the first frame, leaves the picture as the camera pans
/// right, and comes back later. That makes him the concrete test for long-gap
/// re-identification: the question is not whether tracking survives the exit —
/// it should not — but whether the player is picked up again automatically when
/// he returns, without attaching to a team-mate in the same kit.
final class NumberNineReacquisitionTests: XCTestCase {
    /// Centre of the player on frame 0, read off the frame.
    private let tap = CGPoint(x: 0.332, y: 0.843)

    func testPartialNumberNineAtBottomLeft() async throws {
        let url = try recording()
        let found = try await seed(url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let orientation = AnalysisEngine.orientation(for: try await track.load(.preferredTransform))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: 9.9, preferredTimescale: 600),
                                      duration: CMTime(seconds: 0.1, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); reader.startReading()
        defer { reader.cancelReading() }
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        let detector = try SportsPlayerDetector()
        let full = try detector.playerBoxes(in: buffer, orientation: orientation)
        let focused = try detector.playerBoxes(in: buffer, orientation: orientation,
                                               region: CGRect(x: 0, y: 0.65, width: 0.3, height: 0.35),
                                               minimumConfidence: 0.12)
        print("PARTIAL_NINE full=\(full) focused=\(focused)")
        let visible = try XCTUnwrap((full + focused).first { $0.minX < 0.09 && $0.minY > 0.85 && $0.maxY > 0.98 },
                                   "Detect #9's visible upper body at the bottom-left at 9.9s")
        let body = PlayerBodyExtent.estimate(visible: visible, reference: found.box)
        XCTAssertGreaterThan(body.maxY, 1, "The estimated feet must remain below the image edge")
    }

    func testReacquiresPartialNumberNineAtTenSeconds() async throws {
        let url = try recording()
        let found = try await seed(url)
        PlayerTrackingLimits.trace = { line in
            if let time = Double(line.split(separator: " ").first ?? ""), time > 8 { print("PARTIAL_TRACE " + line) }
        }
        defer { PlayerTrackingLimits.trace = nil }
        let outcome = try await SelectedPlayerTracking.track(url: url, seed: found.box,
            from: 0, to: 10.5, direction: .forward, prior: nil, includeBodyMasks: false) { _ in }
        XCTAssertNil(outcome.motion.box(at: 7), "Do not follow a teammate while #9 is offscreen")
        var mark = AnalysisAnnotation(tool: .player,
            points: [found.box.origin, .init(x: found.box.maxX, y: found.box.maxY)], start: 0, end: 10.5)
        mark.playerMotion = outcome.motion; mark.effect = .radar
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for time in [9.9, 10.1, 10.4] {
            let source = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let frame = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            let rendered = UIGraphicsImageRenderer(size: frame.size).image { renderer in
                UIImage(cgImage: source).draw(in: frame)
                AnnotationRenderer.draw([mark], time: time, in: renderer.cgContext, frame: frame)
            }
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "Automatic number 9 return at \(time)s"; attachment.lifetime = .keepAlways; add(attachment)
        }
        // Allow the three-frame identity confirmation after the first partial
        // return; do not require an unconfirmed first-frame guess at 9.9s.
        let body = try XCTUnwrap(outcome.motion.box(at: 10.1), "Automatically reacquire #9 after confirming the partial return")
        XCTAssertTrue(body.contains(CGPoint(x: 0.075, y: 0.94)), "Must follow the bottom-left #9, not another blue shirt")
        let later = try XCTUnwrap(outcome.motion.box(at: 10.4), "Keep following after the initial return")
        XCTAssertTrue(later.contains(CGPoint(x: 0.11, y: 0.95)))
        XCTAssertNotNil(outcome.motion.effectBodyBox(at: 10.1), "A confirmed partial return must be visible in the app")
        XCTAssertNotNil(outcome.motion.effectBodyBox(at: 10.4), "Keep the marker visible after the return")
    }

    private func recording() throws -> URL {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Run on the fixture phone")
        return url
    }

    func testBothNumberNineReturnsWithoutManualSelection() async throws {
        let url = try recording()
        let found = try await seed(url)
        PlayerTrackingLimits.trace = { print("RETURN_TRACE " + $0) }
        defer { PlayerTrackingLimits.trace = nil }
        let outcome = try await SelectedPlayerTracking.track(url: url, seed: found.box,
            from: 0, to: 26, direction: .forward, prior: nil, includeBodyMasks: false) { _ in }
        print("RETURN_GAPS \(outcome.motion.gaps ?? [])")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var mark = AnalysisAnnotation(tool: .player,
            points: [found.box.origin, .init(x: found.box.maxX, y: found.box.maxY)], start: 0, end: 26)
        mark.playerMotion = outcome.motion; mark.effect = .radar
        for time in [10.1, 10.4, 21.2, 21.4, 21.6, 23.0, 25.07] {
            print("RETURN_BOX \(time) \(String(describing: outcome.motion.box(at: time)))")
            let source = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let frame = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            let rendered = UIGraphicsImageRenderer(size: frame.size).image { renderer in
                UIImage(cgImage: source).draw(in: frame)
                AnnotationRenderer.draw([mark], time: time, in: renderer.cgContext, frame: frame)
            }
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "Both returns at \(time)s"; attachment.lifetime = .keepAlways; add(attachment)
        }
        for (time, point) in [(10.1, CGPoint(x: 0.075, y: 0.94)),
                              (10.4, CGPoint(x: 0.11, y: 0.95)),
                              (21.6, CGPoint(x: 0.096, y: 0.79)),
                              (23.0, CGPoint(x: 0.201, y: 0.75)),
                              (25.07, CGPoint(x: 0.213, y: 0.79))] {
            XCTAssertTrue(outcome.motion.box(at: time)?.contains(point) == true, "Track #9 at \(time), not a teammate")
            XCTAssertNotNil(outcome.motion.effectBodyBox(at: time), "Render the confirmed return at \(time)")
        }
        XCTAssertNil(outcome.motion.box(at: 7))
        XCTAssertNil(outcome.motion.box(at: 20.5), "Do not reacquire #3 on the opposite side before #9 returns")
    }

    private func seed(_ url: URL) async throws -> (box: CGRect, detections: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw XCTSkip("no video track") }
        let orientation = AnalysisEngine.orientation(for: try await track.load(.preferredTransform))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output); reader.startReading()
        guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw XCTSkip("no frame")
        }
        defer { reader.cancelReading() }
        let boxes = try SportsPlayerDetector().playerBoxes(in: buffer, orientation: orientation)
        guard let box = boxes.first(where: { $0.contains(tap) }) ?? boxes.min(by: {
            hypot($0.midX - tap.x, $0.midY - tap.y) < hypot($1.midX - tap.x, $1.midY - tap.y)
        }) else { throw XCTSkip("no detection near the tap") }
        return (box, boxes.count)
    }

    /// Reports which identity signals are available before the exit. The
    /// selected-player path now uses the automatic appearance gallery when OCR
    /// is unavailable, while the roster still keeps its stricter number rule.
    func testWhatTheSearchHasToWorkWith() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Core ML models cannot create an inference context on the simulator")
        #endif
        let url = try recording()
        let found = try await seed(url)
        // The trace hook is called from the tracking worker, so the sink has
        // to be safe to touch from another thread.
        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var lines: [String] = []
            func append(_ line: String) {
                lock.lock(); defer { lock.unlock() }
                if lines.count < 4000 { lines.append(line) }
            }
        }
        let sink = Sink()
        PlayerTrackingLimits.trace = { sink.append($0) }
        defer { PlayerTrackingLimits.trace = nil }
        let outcome = try await SelectedPlayerTracking.track(
            url: url, seed: found.box, from: 0, to: 33, direction: .forward,
            prior: nil, includeBodyMasks: false) { _ in }
        let motion = outcome.motion

        var report: [String] = ["", "=== WHAT THE SEARCH HAS ==="]
        report.append("jersey profile confirmed: \(motion.jerseyProfile?.isConfirmed ?? false) "
                      + "(examples \(motion.jerseyProfile?.examples.count ?? 0))")
        if let identity = motion.identity {
            report.append("identity confirmed: \(identity.isConfirmed)")
            report.append("chroma confirmed: \(identity.chroma?.isConfirmed ?? false)")
            report.append("shirt number confirmed: \(identity.number.confirmed ?? "none")")
            report.append("gallery ready: \(identity.gallery?.isReady ?? false) "
                          + "(prints \(identity.gallery?.prints.count ?? 0), gate \(identity.gallery?.gate ?? 0))")
        } else {
            report.append("NO IDENTITY MEMORY AT ALL")
        }
        let lines = sink.lines
        report.append("trace lines: \(lines.count)")
        var counts: [String: Int] = [:]
        for line in lines {
            let key = line.split(separator: " ").dropFirst().prefix(3).joined(separator: " ")
            counts[key, default: 0] += 1
        }
        for (key, value) in counts.sorted(by: { $0.value > $1.value }).prefix(10) {
            report.append(String(format: "  %5d  %@", value, key))
        }
        report.append("--- every present-anywhere line")
        for line in lines.filter({ $0.contains("present-anywhere") }).prefix(30) {
            report.append("  " + line)
        }
        report.append("=== END ===")
        let text = report.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "search-inputs"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Can the shirt number even be read on this player, at this resolution?
    func testShirtNumberIsLegible() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Core ML models cannot create an inference context on the simulator")
        #endif
        let url = try recording()
        let found = try await seed(url)
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw XCTSkip("no track") }
        let orientation = AnalysisEngine.orientation(for: try await track.load(.preferredTransform))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output); reader.startReading()

        let numbers = ShirtNumberReader()
        let detector = try SportsPlayerDetector()
        var report: [String] = ["", "=== IS THE NUMBER LEGIBLE? ==="]
        var box = found.box
        var reads: [String: Int] = [:]
        var attempts = 0, index = 0
        while index < 75, let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            guard index % 5 == 0 else { continue }
            // Follow him with the detector so the crop stays on the player.
            let boxes = try detector.playerBoxes(in: buffer, orientation: orientation)
            if let nearest = boxes.min(by: { PlayerTracker.overlap($0, box) > PlayerTracker.overlap($1, box) ? false : true }),
               PlayerTracker.overlap(nearest, box) > 0.2 { box = nearest }
            attempts += 1
            let text = numbers.read(buffer, box: box, orientation: orientation)
            reads[text ?? "nil", default: 0] += 1
        }
        reader.cancelReading()
        report.append("attempts: \(attempts) over the first 2.5s")
        for (text, count) in reads.sorted(by: { $0.value > $1.value }) {
            report.append(String(format: "  %4d  %@", count, text))
        }
        report.append("PlayerNumberVotes needs \(PlayerNumberVotes.minimumVotes) agreeing reads and 60% of the total.")
        report.append("=== END ===")
        let text = report.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "number-legibility"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Does the roster pass — which follows every player at once and enforces
    /// exclusivity — recover him where the single-player search cannot?
    ///
    /// The single-player search has to pick him out of ten identical shirts with
    /// nothing to rule them out. Tracking the whole team turns that into
    /// identification by elimination: the blue body that appears while every
    /// other blue player is already claimed can only be him.
    func testRosterPassRecoversHimByElimination() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Core ML models cannot create an inference context on the simulator")
        #endif
        let url = try recording()
        let found = try await seed(url)
        // The roster pass can only recognise a player it already knows: it
        // skips any prior whose identity memory is unconfirmed. So do what the
        // app does — follow the tap first to learn the kit, tone and
        // embeddings, then hand that identity to the roster.
        let followed = try await SelectedPlayerTracking.track(
            url: url, seed: found.box, from: 0, to: 33, direction: .forward,
            prior: nil, includeBodyMasks: false) { _ in }
        var motion = followed.motion
        let id = motion.trackID ?? UUID()
        motion.trackID = id
        let prior = PlayerRosterPrior(id: id, motion: motion, memory: motion.identity)

        let started = CFAbsoluteTimeGetCurrent()
        let result = try await PlayerRosterTracking.track(
            url: url, from: 0, to: 33, priors: [prior], camera: nil) { _ in }
        let seconds = CFAbsoluteTimeGetCurrent() - started

        var report: [String] = ["", "=== ROSTER PASS ON THE MAY 11 CLIP ==="]
        report.append("prior identity confirmed: \(motion.identity?.isConfirmed ?? false)")
        report.append(String(format: "single-player pass: samples=%d lostAt=%@",
                             motion.samples.count, motion.lostAt.map { String(format: "%.2f", $0) } ?? "none"))
        report.append(String(format: "players found: %d, detection frames: %d, %.0fs",
                             result.entries.count, result.detectionFrames, seconds))
        guard let his = result.entries.first(where: { $0.id == prior.id }) else {
            report.append("THE SEEDED PLAYER IS NOT IN THE RESULT")
            print(report.joined(separator: "\n"))
            XCTFail("roster pass dropped the seeded player")
            return
        }
        let samples = his.motion.samples
        report.append(String(format: "his track: samples=%d span=%.1f-%.1fs lostAt=%@ number=%@",
                             samples.count, samples.first?.time ?? 0, samples.last?.time ?? 0,
                             his.motion.lostAt.map { String(format: "%.2f", $0) } ?? "none",
                             his.memory.number.confirmed ?? "none"))
        for gap in (his.motion.gaps ?? []).prefix(10) {
            report.append(String(format: "   gap %.2f - %.2fs (%.2fs)", gap.lowerBound, gap.upperBound,
                                 gap.upperBound - gap.lowerBound))
        }
        // Did he come back at all after the exit?
        let afterExit = samples.filter { $0.time > 4 }
        report.append("samples after 4s: \(afterExit.count)")
        if let firstReturn = afterExit.first {
            report.append(String(format: "first sample back at %.2fs", firstReturn.time))
        }
        // Boxes after the return, so the pixels can be checked by eye: the
        // only way to know whether this is really him or a team-mate.
        report.append("--- boxes after the return (for visual check)")
        for target in [21.6, 23.0, 25.0, 27.0, 29.0, 31.0, 32.5] {
            guard let sample = samples.min(by: { abs($0.time - target) < abs($1.time - target) }),
                  abs(sample.time - target) < 0.5 else { continue }
            report.append(String(format: "CROP %.2f %.4f %.4f %.4f %.4f", sample.time,
                                 sample.box.minX, sample.box.minY, sample.box.width, sample.box.height))
        }
        report.append("=== END ===")
        let text = report.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "roster-pass"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The one-tap flow: after he is lost, does the search put him in front of
    /// the user, and how far down the list?
    func testSearchOffersHimForConfirmation() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Core ML models cannot create an inference context on the simulator")
        #endif
        let url = try recording()
        let found = try await seed(url)
        let followed = try await SelectedPlayerTracking.track(
            url: url, seed: found.box, from: 0, to: 33, direction: .forward,
            prior: nil, includeBodyMasks: false) { _ in }
        let identity = try XCTUnwrap(followed.motion.identity, "the follow pass must learn an identity")
        let lost = followed.motion.lostAt
            ?? followed.motion.gaps?.first?.lowerBound
            ?? followed.motion.samples.last?.time
            ?? 0

        var report: [String] = ["", "=== ONE-TAP SEARCH ==="]
        report.append(String(format: "lost at %.2fs; searching %.2f-33s", lost, lost + 0.2))
        let started = CFAbsoluteTimeGetCurrent()
        let candidates = try await PlayerReacquisitionSearch.candidates(
            url: url, from: lost + 0.2, to: 33, memory: identity)
        report.append(String(format: "%d candidates in %.0fs", candidates.count, CFAbsoluteTimeGetCurrent() - started))
        for (index, candidate) in candidates.enumerated() {
            report.append(String(format: "CAND %d %.2f %.4f %.4f %.4f %.4f score=%.3f",
                                 index, candidate.time, candidate.box.minX, candidate.box.minY,
                                 candidate.box.width, candidate.box.height, candidate.score))
        }
        report.append("=== END ===")
        let text = report.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "one-tap-search"; attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(candidates.isEmpty, "the search must offer something to confirm")
        // Source-frame review: number 9, with short dark hair and yellow boots,
        // is walking in the lower-left part of the frame at 25.07 and 26.67
        // seconds. Search sampling starts after loss, so accept either verified
        // sighting rather than requiring one exact sampling phase.
        // A non-empty list alone could contain only his same-kit teammates.
        XCTAssertTrue(candidates.contains { candidate in
            [(25.07, CGPoint(x: 0.213, y: 0.79)), (26.67, CGPoint(x: 0.261, y: 0.80))].contains { time, point in
                abs(candidate.time - time) < 0.45 && candidate.box.contains(point)
            }
        }, "Offer the actual returning player, not just similar blue shirts")
        if identity.number.confirmed == nil {
            XCTAssertNil(followed.motion.box(at: 25.07), "An unconfirmed return must await the user's choice")
            XCTAssertNotNil(followed.motion.box(at: 25.4),
                            "Automatic appearance recovery should resume after temporal confirmation")
        }
    }

    func testFollowsNumberNineThroughHisAbsence() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Core ML models cannot create an inference context on the simulator")
        #endif
        let url = try recording()
        let found = try await seed(url)
        var report: [String] = ["", "=== NUMBER 9, MAY 11 CLIP ==="]
        report.append(String(format: "frame 0: %d detections; seed x=%.3f y=%.3f w=%.3f h=%.3f (%.0f px tall)",
                             found.detections, found.box.minX, found.box.minY,
                             found.box.width, found.box.height, found.box.height * 1080))

        for engine in PlayerTrackingEngine.allCases {
            let started = CFAbsoluteTimeGetCurrent()
            let outcome = try await SelectedPlayerTracking.track(
                url: url, seed: found.box, from: 0, to: 33, direction: .forward,
                prior: nil, includeBodyMasks: engine == .v2) { _ in }
            let seconds = CFAbsoluteTimeGetCurrent() - started
            let motion = outcome.motion
            let first = motion.samples.first?.time ?? 0
            let last = motion.samples.last?.time ?? 0
            report.append(String(format: "%@: samples=%d span=%.1f-%.1fs lostAt=%@ recoveries=%d  (%.0fs)",
                                 engine.rawValue, motion.samples.count, first, last,
                                 motion.lostAt.map { String(format: "%.2f", $0) } ?? "none",
                                 motion.recoveryCount ?? 0, seconds))
            for gap in (motion.gaps ?? []).prefix(8) {
                report.append(String(format: "     gap %.2f - %.2fs  (%.2fs hidden)",
                                     gap.lowerBound, gap.upperBound, gap.upperBound - gap.lowerBound))
            }
            if (motion.gaps ?? []).count > 8 {
                report.append("     ... \((motion.gaps ?? []).count - 8) more gaps")
            }
            let returnSamples = motion.samples.filter { $0.time > 25 }
            XCTAssertFalse(returnSamples.isEmpty,
                           "\(engine.rawValue) must automatically reacquire #9 after his return")
            XCTAssertTrue(returnSamples.contains { sample in
                sample.box.contains(CGPoint(x: 0.213, y: 0.79)) ||
                sample.box.contains(CGPoint(x: 0.261, y: 0.80))
            }, "\(engine.rawValue) must reacquire the returning #9, not a same-kit body")
            for target in [27.0, 29.0, 31.0] {
                if let sample = returnSamples.min(by: { abs($0.time - target) < abs($1.time - target) }) {
                    report.append(String(format: "%@: return %.2f %.4f %.4f %.4f %.4f",
                                         engine.rawValue, sample.time, sample.box.minX, sample.box.minY,
                                         sample.box.width, sample.box.height))
                }
            }
        }
        report.append("=== END ===")
        let text = report.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "number-nine"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Reproduces a saved-player whole-clip rerun from the clip start after a
    /// previous pass has left contaminated automatic appearance memory.
    func testSavedPlayerWholeClipRerunReacquiresNumberNine() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Core ML models cannot create an inference context on the simulator")
        #endif
        let url = try recording()
        let found = try await seed(url)
        let initial = try await SelectedPlayerTracking.track(
            url: url, seed: found.box, from: 0, to: 33, direction: .forward,
            prior: nil, includeBodyMasks: false) { _ in }
        var saved = initial.motion
        saved.jerseyProfile = nil
        if let identity = saved.identity {
            saved.identity = identity.restartingAutomaticLearning()
        }
        let forward = try await SelectedPlayerTracking.track(
            url: url, seed: found.box, from: 0, to: 33, direction: .forward,
            prior: saved, includeBodyMasks: false) { _ in }
        let rerun = saved.continuing(with: forward.motion, from: 0)
        let returning = rerun.samples.filter { $0.time > 25 }

        XCTAssertTrue(returning.contains { sample in
            sample.box.contains(CGPoint(x: 0.213, y: 0.79)) ||
            sample.box.contains(CGPoint(x: 0.261, y: 0.80))
        }, "the saved-player whole-clip rerun must reacquire #9")
    }
}
