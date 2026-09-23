@preconcurrency import AVFoundation
import CoreImage
import Vision
import XCTest
@testable import Camelot

/// On-device profile of the selected-player tracking pass. Reads real footage
/// from Documents/Recordings read-only and prints per-stage milliseconds and
/// end-to-end frames of video per second. Skips everywhere Vision cannot run.
final class PlayerTrackingBenchmark: XCTestCase {
    private struct Frame { let buffer: CVPixelBuffer; let sample: CMSampleBuffer; let time: Double }

    private func recordings() -> [URL] {
        let folder = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 }
    }

    private func recording() throws -> URL {
        let all = recordings()
        try XCTSkipIf(all.isEmpty, "No recordings in Documents/Recordings")
        if let name = ProcessInfo.processInfo.environment["CAMELOT_TRACK_RECORDING"],
           let match = all.first(where: { $0.lastPathComponent.hasPrefix(name) }) { return match }
        return all[0]
    }

    /// Decode a window at a chosen long side, keeping the sample buffers alive.
    private func read(_ url: URL, longSide: Int, from start: Double, frames wanted: Int, stride: Int = 1)
        async throws -> (frames: [Frame], size: CGSize, fps: Double, decodeMilliseconds: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw XCTSkip("no video track") }
        let natural = try await track.load(.naturalSize)
        let fps = Double(try await track.load(.nominalFrameRate))
        let scale = min(1, Double(longSide) / max(natural.width, natural.height))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: max(2, Int(natural.width * scale / 2) * 2),
            kCVPixelBufferHeightKey as String: max(2, Int(natural.height * scale / 2) * 2)
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        var frames: [Frame] = []
        var index = 0
        var decoded = 0
        let began = CFAbsoluteTimeGetCurrent()
        while frames.count < wanted, let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            decoded += 1
            guard index % stride == 0, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append(Frame(buffer: buffer, sample: sample, time: CMSampleBufferGetPresentationTimeStamp(sample).seconds))
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - began) * 1000
        reader.cancelReading()
        let size = frames.first.map { CGSize(width: CVPixelBufferGetWidth($0.buffer), height: CVPixelBufferGetHeight($0.buffer)) } ?? natural
        return (frames, size, fps.isFinite && fps > 0 ? fps : 30, elapsed / Double(max(1, decoded)))
    }

    private func time(_ label: String, frames: [Frame], into report: inout [String], _ body: (Frame) throws -> Void) rethrows {
        let began = CFAbsoluteTimeGetCurrent()
        for frame in frames { try body(frame) }
        let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000 / Double(max(1, frames.count))
        report.append(String(format: "    %-26@ %7.2f ms/frame", label, ms))
    }

    // MARK: - Per-stage profile

    func testTrackingStageProfile() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision models cannot create an inference context on the simulator")
        #endif
        let url = try recording()
        var report: [String] = ["", "=== PLAYER TRACKING STAGE PROFILE — \(url.lastPathComponent) ==="]
        let detector = try SportsPlayerDetector()
        let printer = PlayerAppearancePrinter()
        let numbers = ShirtNumberReader()
        let context = CIContext(options: [.cacheIntermediates: false])

        for longSide in [1280, 960, 720] {
            let (frames, size, fps, decodeMs) = try await read(url, longSide: longSide, from: 5, frames: 40)
            guard frames.count >= 8 else { continue }
            report.append(String(format: "  -- long side %d → %dx%d, source %.2f fps, %d frames", longSide, Int(size.width), Int(size.height), fps, frames.count))
            report.append(String(format: "    %-26@ %7.2f ms/frame", "decode", decodeMs))

            // Seed from the biggest detection on the first frame.
            let seeds = try detector.playerBoxes(in: frames[0].buffer, orientation: .up)
            let seed = seeds.max { $0.height < $1.height } ?? CGRect(x: 0.45, y: 0.4, width: 0.06, height: 0.16)
            report.append(String(format: "    detections on frame 0: %d, seed %.3f×%.3f", seeds.count, seed.width, seed.height))

            let tracker = VisionPlayerTracker(seed: CGRect(x: seed.minX, y: 1 - seed.maxY, width: seed.width, height: seed.height))
            try time("VNTrackObject", frames: frames, into: &report) { _ = try tracker.track($0.buffer, orientation: .up) }
            tracker.finish()

            var boxes: [CGRect] = seeds
            try time("detector (2 crops)", frames: frames, into: &report) { boxes = try detector.playerBoxes(in: $0.buffer, orientation: .up) }
            if let region = PlayerTrackingSearch.region(around: seed) {
                try time("detector focused retry", frames: frames, into: &report) { _ = try detector.playerBoxes(in: $0.buffer, orientation: .up, region: region) }
            }
            let sample = boxes.isEmpty ? [seed] : boxes
            time("observe × \(sample.count) boxes", frames: frames, into: &report) { frame in
                for box in sample { _ = PlayerObservation.observe(frame.buffer, box: box, orientation: .up, among: sample) }
            }
            time("jersey signature ×1", frames: frames, into: &report) { _ = PlayerJerseySignature.sample($0.buffer, box: seed, orientation: .up) }
            time("feature print ×4", frames: frames, into: &report) { frame in
                for box in sample.prefix(4) { _ = printer.print(frame.buffer, box: box, orientation: .up) }
            }
            time("shirt number ×1", frames: frames, into: &report) { _ = numbers.read($0.buffer, box: seed, orientation: .up) }
            var previous = frames[0].buffer
            time("camera register", frames: frames, into: &report) { frame in
                _ = try? CameraMotionTracking.register(previous: previous, current: frame.buffer, orientation: .up, context: context)
                previous = frame.buffer
            }
        }
        report.append("=== END STAGE PROFILE ===")
        Swift.print(report.joined(separator: "\n"))
    }

    // MARK: - Decode cost versus source resolution

    /// Does a lower-resolution proxy help? Compare decode throughput of every
    /// recording on the phone at three decode sizes plus native.
    func testDecodeCostAcrossResolutions() async throws {
        let all = recordings()
        try XCTSkipIf(all.isEmpty, "No recordings in Documents/Recordings")
        var report: [String] = ["", "=== DECODE COST VS DECODE SIZE ==="]
        for url in all.prefix(5) {
            var line: [String] = []
            var header = url.lastPathComponent
            for longSide in [10_000, 1280, 960, 720] {
                let (frames, size, fps, ms) = try await read(url, longSide: longSide, from: 2, frames: 60)
                guard !frames.isEmpty else { continue }
                if longSide == 10_000 { header = String(format: "%@  native %dx%d @ %.2f fps", url.lastPathComponent, Int(size.width), Int(size.height), fps) }
                line.append(String(format: "%@=%.2fms", longSide == 10_000 ? "native" : "\(longSide)", ms))
            }
            report.append("  " + header)
            report.append("    " + line.joined(separator: "  "))
        }
        report.append("=== END DECODE COST ===")
        Swift.print(report.joined(separator: "\n"))
    }

    // MARK: - End-to-end throughput of the current pass

    /// Wall-clock cost of one forward pass over a fixed range, reported as
    /// frames of video per wall second so before/after are comparable.
    private func throughput(url: URL, seedAt point: CGPoint, from start: Double, seconds: Double, label: String) async throws {
        let (frames, size, fps, _) = try await read(url, longSide: 1280, from: start, frames: 1)
        guard let first = frames.first else { throw XCTSkip("no frames") }
        let detector = try SportsPlayerDetector()
        let found = try detector.playerBoxes(in: first.buffer, orientation: .up)
        guard let seed = found.first(where: { $0.contains(point) }) ?? found.max(by: { $0.height < $1.height }) else {
            throw XCTSkip("no player detected at the seed frame")
        }
        let began = CFAbsoluteTimeGetCurrent()
        let motion = try await SelectedPlayerTracking.track(url: url, seed: seed, from: first.time, to: first.time + seconds) { _ in }
        let elapsed = CFAbsoluteTimeGetCurrent() - began
        let tracked = (motion.samples.last?.time ?? first.time) - first.time
        Swift.print(String(format: """

        === FORWARD THROUGHPUT [%@] — %@ ===
          source %dx%d @ %.2f fps, requested %.1f s from %.2f s
          wall clock            %.2f s
          requested video/wall  %.2fx real time   (%.1f source frames per wall second)
          confirmed to          %.2f s of video (%.2f s of the range)
          samples               %d
          lost at               %@   gaps %d   recoveries %d
          projected 5 min clip  %.1f min of wall clock
        === END THROUGHPUT ===
        """, label, url.lastPathComponent, Int(size.width), Int(size.height), fps, seconds, first.time,
        elapsed, seconds / max(0.001, elapsed), seconds * fps / max(0.001, elapsed),
        motion.samples.last?.time ?? first.time, tracked, motion.samples.count,
        motion.lostAt.map { String(format: "%.2f", $0) } ?? "—", motion.gaps?.count ?? 0, motion.recoveryCount ?? 0,
        300 * (elapsed / max(0.001, seconds)) / 60))
        XCTAssertGreaterThan(motion.samples.count, 1)
    }

    /// The healthy case: the stress runner, who the pass follows successfully.
    func testForwardThroughputOnTrackedRunner() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision models cannot create an inference context on the simulator")
        #endif
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Run on the fixture phone")
        try await throughput(url: url, seedAt: CGPoint(x: 0.394, y: 0.586), from: 3, seconds: 25, label: "tracking")
    }

    /// The long-clip case the user hit: the 5½-minute 480p recording.
    func testForwardThroughputOnLongRecording() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision models cannot create an inference context on the simulator")
        #endif
        let url = try recording()
        let seconds = Double(ProcessInfo.processInfo.environment["CAMELOT_TRACK_SECONDS"] ?? "30") ?? 30
        let start = Double(ProcessInfo.processInfo.environment["CAMELOT_TRACK_START"] ?? "5") ?? 5
        try await throughput(url: url, seedAt: CGPoint(x: 0.5, y: 0.5), from: start, seconds: seconds, label: "long clip")
    }

    /// The sampling-rate win, measured on the same footage in one thermal state:
    /// a 60 fps clip tracked at 60 Hz and at the 30 Hz cap, interleaved so a
    /// warming phone cannot fake the difference.
    func testSamplingRateOnHighFrameRateFootage() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision models cannot create an inference context on the simulator")
        #endif
        let candidates = recordings()
        guard let url = try await firstHighFrameRate(candidates) else { throw XCTSkip("No source above 30 fps on this phone") }
        let detector = try SportsPlayerDetector()
        let span = 10.0
        // A seed the pass actually follows: decode-only dormant recovery would
        // hide the Vision work this cap is meant to halve.
        var chosen: (time: Double, box: CGRect, held: Double)?
        var size = CGSize.zero, fps = 0.0
        for start in stride(from: 5.0, through: 245.0, by: 30.0) {
            let (frames, dimensions, rate, _) = try await read(url, longSide: 1280, from: start, frames: 1)
            guard let first = frames.first else { continue }
            size = dimensions; fps = rate
            guard let box = try detector.playerBoxes(in: first.buffer, orientation: .up).max(by: { $0.height < $1.height }) else { continue }
            let probe = try await SelectedPlayerTracking.track(url: url, seed: box, from: first.time, to: first.time + 3, checkpoint: { _ in })
            let held = (probe.motion.lostAt ?? probe.motion.samples.last?.time ?? first.time) - first.time
            if held > (chosen?.held ?? 0) { chosen = (first.time, box, held) }
            if held >= 2.9 { break }
        }
        guard let picked = chosen, picked.held > 1 else { throw XCTSkip("No seed on this clip is followed long enough to time") }
        let first = (time: picked.time, box: picked.box)
        let seed = picked.box
        Swift.print(String(format: "  seed at %.2f s holds %.2f s", picked.time, picked.held))
        defer { PlayerTrackingLimits.maximumSampleRate = 30 }
        var results: [Double: (wall: Double, samples: Int)] = [:]
        for pass in 0..<2 {
            for rate in [60.0, 30.0] {
                PlayerTrackingLimits.maximumSampleRate = rate
                let began = CFAbsoluteTimeGetCurrent()
                let outcome = try await SelectedPlayerTracking.track(url: url, seed: seed, from: first.time, to: first.time + span, checkpoint: { _ in })
                let elapsed = CFAbsoluteTimeGetCurrent() - began
                if pass == 1 || results[rate] == nil {
                    let best = results[rate].map { min($0.wall, elapsed) } ?? elapsed
                    results[rate] = (best, outcome.motion.samples.count)
                }
            }
        }
        let fast = results[60] ?? (0, 0), capped = results[30] ?? (0, 0)
        Swift.print(String(format: """

        === SAMPLING RATE — %@ (%dx%d @ %.2f fps) ===
          %.0f s of video, best of two interleaved passes
          60 Hz   %.2f s wall, %d samples
          30 Hz   %.2f s wall, %d samples   (%.2fx faster)
        === END SAMPLING RATE ===
        """, url.lastPathComponent, Int(size.width), Int(size.height), fps, span,
        fast.wall, fast.samples, capped.wall, capped.samples, fast.wall / max(0.001, capped.wall)))
        XCTAssertLessThan(capped.samples, fast.samples, "The cap really halves the sampled frames")
    }

    private func firstHighFrameRate(_ urls: [URL]) async throws -> URL? {
        for url in urls {
            guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { continue }
            if Double(try await track.load(.nominalFrameRate)) > 31 { return url }
        }
        return nil
    }

    /// Backward tracking re-opens a reader every half second; measure what that costs.
    func testBackwardThroughput() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision models cannot create an inference context on the simulator")
        #endif
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Run on the fixture phone")
        let (frames, _, fps, _) = try await read(url, longSide: 1280, from: 12, frames: 1)
        guard let first = frames.first else { throw XCTSkip("no frames") }
        let detector = try SportsPlayerDetector()
        guard let seed = try detector.playerBoxes(in: first.buffer, orientation: .up).max(by: { $0.height < $1.height }) else {
            throw XCTSkip("no player at the seed frame")
        }
        let span = 8.0
        let began = CFAbsoluteTimeGetCurrent()
        let motion = try await SelectedPlayerTracking.trackBackward(url: url, seed: seed, from: first.time, to: first.time - span) { _ in }
        let elapsed = CFAbsoluteTimeGetCurrent() - began
        Swift.print(String(format: """

        === BACKWARD THROUGHPUT — %@ ===
          %.1f s of video backwards from %.2f s at %.2f fps
          wall clock            %.2f s
          video/wall            %.2fx real time  (%.1f source frames per wall second)
          samples               %d, reaching back to %.2f s
          projected 5 min       %.1f min of wall clock
        === END BACKWARD ===
        """, url.lastPathComponent, span, first.time, fps, elapsed,
        span / max(0.001, elapsed), span * fps / max(0.001, elapsed),
        motion.samples.count, motion.samples.first?.time ?? .nan, 300 * (elapsed / span) / 60))
        XCTAssertGreaterThan(motion.samples.count, 1)
    }

    /// Reproduce the user's failure: one forward pass over five minutes, with
    /// memory and thermal sampled while it runs. Opt in with CAMELOT_TRACK_LONG=1.
    func testFiveMinuteReproduction() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision models cannot create an inference context on the simulator")
        #endif
        try XCTSkipIf(ProcessInfo.processInfo.environment["CAMELOT_TRACK_LONG"] != "1", "Opt in with CAMELOT_TRACK_LONG=1")
        let url = try recording()
        let seconds = Double(ProcessInfo.processInfo.environment["CAMELOT_TRACK_SECONDS"] ?? "300") ?? 300
        let start = Double(ProcessInfo.processInfo.environment["CAMELOT_TRACK_START"] ?? "5") ?? 5
        let (frames, size, fps, _) = try await read(url, longSide: 1280, from: start, frames: 1)
        guard let first = frames.first else { throw XCTSkip("no frames") }
        let detector = try SportsPlayerDetector()
        guard let seed = try detector.playerBoxes(in: first.buffer, orientation: .up).max(by: { $0.height < $1.height }) else {
            throw XCTSkip("no player at the seed frame")
        }
        let began = CFAbsoluteTimeGetCurrent()
        let sampler = Task.detached {
            var lines: [String] = []
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                lines.append(String(format: "    +%5.0fs  memory %6.1f MB  thermal %d",
                                    CFAbsoluteTimeGetCurrent() - began, Self.footprintMegabytes(),
                                    ProcessInfo.processInfo.thermalState.rawValue))
                Swift.print(lines.last!)
            }
        }
        var failure: String?
        var motion = PlayerMotion(samples: [])
        do {
            motion = try await SelectedPlayerTracking.track(url: url, seed: seed, from: first.time, to: first.time + seconds) { fraction in
                if Int(fraction * 100) % 10 == 0 { Swift.print(String(format: "    progress %.0f%%", fraction * 100)) }
            }
        } catch { failure = "\(error)" }
        sampler.cancel()
        let elapsed = CFAbsoluteTimeGetCurrent() - began
        Swift.print(String(format: """

        === FIVE MINUTE REPRODUCTION — %@ ===
          source %dx%d @ %.2f fps, %.0f s requested from %.2f s
          wall clock            %.1f s (%.1f min), %.2fx real time
          outcome               %@
          samples               %d, confirmed to %.2f s
          lost at               %@   gaps %d   recoveries %d
          peak memory           %.1f MB, thermal %d
        === END REPRODUCTION ===
        """, url.lastPathComponent, Int(size.width), Int(size.height), fps, seconds, first.time,
        elapsed, elapsed / 60, seconds / max(0.001, elapsed), failure ?? "completed",
        motion.samples.count, motion.samples.last?.time ?? .nan,
        motion.lostAt.map { String(format: "%.2f", $0) } ?? "—", motion.gaps?.count ?? 0, motion.recoveryCount ?? 0,
        Self.footprintMegabytes(), ProcessInfo.processInfo.thermalState.rawValue))
    }

    static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
