import AVFoundation
import Vision
import XCTest
@testable import Camelot

final class AnalysisPerfTests: XCTestCase {
    func testDetectorThroughput() throws {
        guard ProcessInfo.processInfo.environment["CVMAC_PERF"] != nil else {
            throw XCTSkip("Set CVMAC_PERF=1 to run the analysis performance benchmark.")
        }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sequence-test.mp4")
        let asset = AVURLAsset(url: fixture)
        guard let track = asset.tracks(withMediaType: .video).first else { throw XCTSkip("no track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        reader.startReading()
        guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw XCTSkip("no frame")
        }

        let detector = try SportsPlayerDetector()
        _ = try? detector.playerBoxes(in: buffer, orientation: .up)

        let iterations = 20
        var start = Date()
        for _ in 0..<iterations { _ = try? detector.playerBoxes(in: buffer, orientation: .up) }
        print("PERF coreml-detector ms/frame = \(Date().timeIntervalSince(start) / Double(iterations) * 1000)")

        start = Date()
        for _ in 0..<iterations {
            let request = VNDetectHumanRectanglesRequest()
            try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
        }
        print("PERF human-rectangles ms/frame = \(Date().timeIntervalSince(start) / Double(iterations) * 1000)")

        let pose = VNDetectHumanBodyPoseRequest()
        start = Date()
        for _ in 0..<iterations {
            try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([pose])
        }
        print("PERF body-pose ms/frame = \(Date().timeIntervalSince(start) / Double(iterations) * 1000)")
    }
}