@preconcurrency import AVFoundation
import CoreGraphics
import XCTest
import UIKit
@testable import Camelot

/// The engines as the app actually runs them, on real footage.
///
/// `SelectedPlayerTracking.track(includeBodyMasks:)` is what the Track buttons call, so
/// this exercises the whole pass rather than the segmenter alone: detector,
/// optical tracker, identity gates, state machine, EdgeTAM and the stabiliser.
@MainActor
final class PlayerTrackingEngineTests: XCTestCase {
    private func stressRecording() throws -> URL {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Run on the fixture phone")
        return url
    }

    private func seed(_ url: URL) async throws -> CGRect {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw XCTSkip("no video track") }
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
        defer { reader.cancelReading() }
        let boxes = try SportsPlayerDetector().playerBoxes(in: buffer, orientation: orientation)
        let point = CGPoint(x: 0.394, y: 0.586)
        guard let box = boxes.first(where: { $0.contains(point) }) ?? boxes.min(by: {
            hypot($0.midX - point.x, $0.midY - point.y) < hypot($1.midX - point.x, $1.midY - point.y)
        }) else { throw XCTSkip("no seed detection") }
        return box
    }

    @MainActor
    func testOneTrackerKeepsIdentityWithOptionalBodyMasks() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Core ML models cannot create an inference context on the simulator")
        #endif
        let url = try stressRecording()
        let box = try await seed(url)
        var report: [String] = ["", "=== TRACKING ENGINES END TO END ==="]
        var masksByEngine: [PlayerTrackingEngine: Int] = [:]
        var motions: [PlayerTrackingEngine: PlayerMotion] = [:]

        for engine in PlayerTrackingEngine.allCases {
            let started = CFAbsoluteTimeGetCurrent()
            let motion = try await SelectedPlayerTracking.track(url: url, seed: box, from: 3, to: 9,
                                                               includeBodyMasks: engine == .v2) { _ in }
            let seconds = CFAbsoluteTimeGetCurrent() - started
            let shaped = motion.samples.filter { $0.silhouette != nil }.count
            masksByEngine[engine] = shaped
            motions[engine] = motion
            print("MASK_OPTION \(engine.rawValue) gaps=\(motion.gaps ?? []) lost=\(String(describing: motion.lostAt))")
            let covered = (motion.samples.last?.time ?? 3) - (motion.samples.first?.time ?? 3)
            report.append(String(format: "%@: samples=%d masks=%d covered=%.1fs lost=%@ engine=%@ %.1fs",
                                 engine.rawValue, motion.samples.count, shaped, covered,
                                 motion.lostAt.map { String(format: "%.2f", $0) } ?? "no",
                                 motion.engine?.rawValue ?? "nil", seconds))
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            // Feet read from source pixels, independent of either tracker.
            for (time, x, y) in [(3.0, 755.0, 674.0), (5.0, 1040.0, 736.0), (7.0, 1210.0, 810.0), (9.0, 1017.0, 923.0)] {
                let body = try XCTUnwrap(motion.box(at: time))
                XCTAssertEqual(body.midX, x / 1920, accuracy: 0.035)
                XCTAssertEqual(body.maxY, y / 1080, accuracy: 0.045)
                let source = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
                let frame = CGRect(x: 0, y: 0, width: source.width, height: source.height)
                let image = UIGraphicsImageRenderer(size: frame.size).image { renderer in
                    UIImage(cgImage: source).draw(in: frame)
                    let context = renderer.cgContext
                    context.setStrokeColor(UIColor.cyan.cgColor); context.setLineWidth(3)
                    context.stroke(CGRect(x: body.minX * frame.width, y: body.minY * frame.height,
                                          width: body.width * frame.width, height: body.height * frame.height))
                    if let path = motion.silhouette(at: time)?.path(in: frame) {
                        context.setStrokeColor(UIColor.yellow.cgColor); context.addPath(path); context.strokePath()
                    }
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "\(engine.rawValue) body and mask at \(time)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        report.append("=== END ===")
        let text = report.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "tracking-engines"; attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(masksByEngine[.v1], 0, "v1 is box-only and must not produce masks")
        XCTAssertGreaterThan(masksByEngine[.v2] ?? 0, 0, "v2 must produce player masks through the real pass")
        for time in stride(from: 3.0, through: 8.9, by: 0.1) {
            let fast = motions[.v1]?.box(at: time), masked = motions[.v2]?.box(at: time)
            XCTAssertEqual(fast == nil, masked == nil, "Both modes must agree about uncertain frames")
            if let fast, let masked {
                XCTAssertGreaterThan(PlayerTracker.overlap(fast, masked), 0.95,
                                     "Enabling a visual mask must not move the tracked player")
            }
        }
    }
}
