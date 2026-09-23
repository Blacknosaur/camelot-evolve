@preconcurrency import AVFoundation
import CoreGraphics
import XCTest
@testable import Camelot

/// Does EdgeTAM actually segment a football player on this phone, and how fast?
///
/// This is the question Apple's built-in requests failed outright: on the same
/// footage `VNGenerateForegroundInstanceMaskRequest` found no instances and
/// `VNGeneratePersonSegmentationRequest` marked under 0.3% of the frame as
/// person. EdgeTAM is promptable, so it should segment whatever box it is given.
final class EdgeTAMSegmenterTests: XCTestCase {
    private func stressRecording() throws -> URL {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Run on the fixture phone")
        return url
    }

    private struct Frame { let buffer: CVPixelBuffer; let time: Double }

    private func frames(_ url: URL, from seconds: Double, count: Int, stride: Int = 1)
    async throws -> (frames: [Frame], orientation: CGImagePropertyOrientation, aspect: CGFloat) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw XCTSkip("no video track") }
        let size = try await track.load(.naturalSize)
        let orientation = AnalysisEngine.orientation(for: try await track.load(.preferredTransform))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600), duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        var collected: [Frame] = []
        var index = 0
        while collected.count < count, let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard index % stride == 0, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            collected.append(Frame(buffer: buffer, time: CMSampleBufferGetPresentationTimeStamp(sample).seconds))
        }
        reader.cancelReading()
        return (collected, orientation, size.width / max(1, size.height))
    }

    func testSegmentsARealPlayerAndReportsTiming() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Core ML models cannot create an inference context on the simulator")
        #endif
        let url = try stressRecording()
        let (decoded, orientation, aspect) = try await frames(url, from: 3, count: 12, stride: 2)
        try XCTSkipIf(decoded.isEmpty, "no frames decoded")

        let detector = try SportsPlayerDetector()
        let boxes = try detector.playerBoxes(in: decoded[0].buffer, orientation: orientation)
        // The seed the tracking benchmark already uses on this fixture.
        let point = CGPoint(x: 0.394, y: 0.586)
        guard let seed = boxes.first(where: { $0.contains(point) }) ?? boxes.min(by: {
            hypot($0.midX - point.x, $0.midY - point.y) < hypot($1.midX - point.x, $1.midY - point.y)
        }) else { throw XCTSkip("no seed detection") }

        let segmenter = try EdgeTAMSegmenter()
        var report: [String] = ["", "=== EDGETAM ON MATCH FOOTAGE ==="]
        report.append("temporal memory: \(segmenter.carriesTemporalMemory)")
        report.append(String(format: "seed box x=%.3f y=%.3f w=%.3f h=%.3f (%.0f px tall)",
                             seed.minX, seed.minY, seed.width, seed.height, seed.height * 1080))

        var roi = PlayerROI.around(seed, aspect: aspect)
        let started = CFAbsoluteTimeGetCurrent()
        guard let first = try segmenter.begin(frame: decoded[0].buffer, orientation: orientation,
                                              roi: roi, prompt: seed) else {
            report.append("NO MASK ON THE SEED FRAME")
            print(report.joined(separator: "\n"))
            XCTFail("EdgeTAM produced no mask for a detected player")
            return
        }
        let firstMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        report.append(String(format: "seed: confidence=%.3f box w=%.3f h=%.3f points=%d  %.0f ms",
                             first.confidence, first.box.width, first.box.height,
                             first.silhouette?.points.count ?? 0, firstMs))

        // The mask should land on the player the detector found, not elsewhere.
        let agreement = PlayerTracker.overlap(first.box, seed)
        report.append(String(format: "mask/detector box overlap: %.3f", agreement))

        var previous = first
        var elapsed: [Double] = []
        for frame in decoded.dropFirst() {
            let tick = CFAbsoluteTimeGetCurrent()
            let step: PlayerSegmentation?
            if roi.comfortablyContains(previous.box) {
                step = try segmenter.next(frame: frame.buffer, orientation: orientation, roi: roi)
            } else {
                roi = PlayerROI.around(previous.box, aspect: aspect)
                step = try segmenter.begin(frame: frame.buffer, orientation: orientation, roi: roi, prompt: previous.box)
            }
            guard let step else { continue }
            elapsed.append((CFAbsoluteTimeGetCurrent() - tick) * 1000)
            previous = step
        }
        if !elapsed.isEmpty {
            let mean = elapsed.reduce(0, +) / Double(elapsed.count)
            report.append(String(format: "follow-on frames: %d, mean %.0f ms (%.1f fps)", elapsed.count, mean, 1000 / mean))
            report.append(String(format: "last: confidence=%.3f box w=%.3f h=%.3f",
                                 previous.confidence, previous.box.width, previous.box.height))
        }
        report.append("=== END ===")
        let text = report.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "edgetam-on-footage"; attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThan(agreement, 0.2, "the mask must land on the player it was prompted with")
        XCTAssertGreaterThan(first.confidence, 0.3, "a clearly visible player should not be a low-confidence mask")
        XCTAssertFalse(elapsed.isEmpty, "The temporal path must run, not just the initial prompt")
    }
}
