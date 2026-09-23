@preconcurrency import AVFoundation
import CoreGraphics
import Vision
import XCTest
@testable import Camelot

/// Does body pose actually help on match footage, and does it cost anything?
final class PlayerPoseOnFootageTests: XCTestCase {
    private func recording() throws -> URL {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Run on the fixture phone")
        return url
    }

    /// How often a skeleton is available for a detected player, how far the foot
    /// line moves when it is, and what the pass costs.
    func testPoseAvailabilityAndFootCorrection() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision models cannot create an inference context on the simulator")
        #endif
        let url = try recording()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw XCTSkip("no track") }
        let orientation = AnalysisEngine.orientation(for: try await track.load(.preferredTransform))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: 3, preferredTimescale: 600), duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output); reader.startReading()

        let detector = try SportsPlayerDetector()
        let poseReader = PlayerPoseReader()
        var detections = 0, matched = 0, withTorso = 0, corrected = 0
        var rawPoses = 0, rawObservations = 0
        var bestConfidences: [Float] = []
        var shifts: [CGFloat] = []
        var byHeight: [(tall: Bool, matched: Bool)] = []
        var poseMs: [Double] = []
        var index = 0
        while index < 40, let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard index % 4 == 0, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let boxes = try detector.playerBoxes(in: buffer, orientation: orientation)
            let tick = CFAbsoluteTimeGetCurrent()
            let poses = poseReader.poses(in: buffer, orientation: orientation)
            poseMs.append((CFAbsoluteTimeGetCurrent() - tick) * 1000)
            // Separate "the model saw nobody" from "I failed to match it".
            rawPoses += poses.count
            let request = VNDetectHumanBodyPoseRequest()
            try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation).perform([request])
            rawObservations += request.results?.count ?? 0
            for observation in request.results ?? [] {
                if let points = try? observation.recognizedPoints(.all) {
                    bestConfidences.append(points.values.map(\.confidence).max() ?? 0)
                }
            }
            for box in boxes {
                detections += 1
                guard let pose = PlayerPoseReader.match(box, among: poses) else {
                    byHeight.append((box.height >= 0.1, false)); continue
                }
                matched += 1
                byHeight.append((box.height >= 0.1, true))
                if pose.torso != nil { withTorso += 1 }
                let grounded = pose.grounding(box)
                if grounded != box {
                    corrected += 1
                    shifts.append(abs(grounded.maxY - box.maxY))
                }
            }
        }
        reader.cancelReading()

        var report: [String] = ["", "=== POSE ON MATCH FOOTAGE ==="]
        report.append("raw pose observations: \(rawObservations); usable after filtering: \(rawPoses)")
        if !bestConfidences.isEmpty {
            let sorted = bestConfidences.sorted()
            report.append(String(format: "best joint confidence per observation: median %.2f, max %.2f",
                                 sorted[sorted.count / 2], sorted.last ?? 0))
        }
        report.append(String(format: "detections %d; skeleton matched %d (%.0f%%); torso band %d",
                             detections, matched, 100 * Double(matched) / Double(max(1, detections)), withTorso))
        let tall = byHeight.filter(\.tall), small = byHeight.filter { !$0.tall }
        report.append(String(format: "  players >= 10%% tall: %d matched of %d (%.0f%%)",
                             tall.filter(\.matched).count, tall.count,
                             100 * Double(tall.filter(\.matched).count) / Double(max(1, tall.count))))
        report.append(String(format: "  players <  10%% tall: %d matched of %d (%.0f%%)",
                             small.filter(\.matched).count, small.count,
                             100 * Double(small.filter(\.matched).count) / Double(max(1, small.count))))
        if !shifts.isEmpty {
            let mean = shifts.reduce(0, +) / CGFloat(shifts.count)
            report.append(String(format: "foot line corrected on %d boxes; mean %.1f px, max %.1f px (of 1080)",
                                 corrected, mean * 1080, (shifts.max() ?? 0) * 1080))
        } else {
            report.append("foot line never corrected")
        }
        if !poseMs.isEmpty {
            report.append(String(format: "pose cost: %.1f ms/frame over %d frames",
                                 poseMs.reduce(0, +) / Double(poseMs.count), poseMs.count))
        }
        report.append("=== END ===")
        let text = report.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "pose-on-footage"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Pose must not cost coverage: the runner is followed for the full range,
    /// exactly as before.
    func testTrackingCoverageIsUnchanged() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Core ML models cannot create an inference context on the simulator")
        #endif
        let url = try recording()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw XCTSkip("no track") }
        let orientation = AnalysisEngine.orientation(for: try await track.load(.preferredTransform))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: 3, preferredTimescale: 600), duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output); reader.startReading()
        guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw XCTSkip("no frame")
        }
        let boxes = try SportsPlayerDetector().playerBoxes(in: buffer, orientation: orientation)
        reader.cancelReading()
        let point = CGPoint(x: 0.394, y: 0.586)
        guard let seed = boxes.first(where: { $0.contains(point) }) ?? boxes.min(by: {
            hypot($0.midX - point.x, $0.midY - point.y) < hypot($1.midX - point.x, $1.midY - point.y)
        }) else { throw XCTSkip("no seed") }

        var report: [String] = ["", "=== COVERAGE WITH POSE ==="]
        for engine in PlayerTrackingEngine.allCases {
            let started = CFAbsoluteTimeGetCurrent()
            let motion = try await SelectedPlayerTracking.track(url: url, seed: seed, from: 3, to: 9,
                                                               includeBodyMasks: engine == .v2) { _ in }
            report.append(String(format: "%@: samples=%d covered=%.1fs lost=%@ (%.1fs)",
                                 engine.rawValue, motion.samples.count,
                                 (motion.samples.last?.time ?? 3) - (motion.samples.first?.time ?? 3),
                                 motion.lostAt.map { String(format: "%.2f", $0) } ?? "no",
                                 CFAbsoluteTimeGetCurrent() - started))
            XCTAssertNil(motion.lostAt, "\(engine.rawValue) must still follow the runner for the full range")
        }
        report.append("=== END ===")
        print(report.joined(separator: "\n"))
    }
}
