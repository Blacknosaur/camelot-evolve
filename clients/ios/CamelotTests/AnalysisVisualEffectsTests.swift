@preconcurrency import AVFoundation
import CoreGraphics
import UIKit
import XCTest
@testable import Camelot

/// Visual-effect coverage uses a real user recording as pixels, but all motion
/// is synthetic and authored from known source-frame foot positions. It does
/// not invoke Vision tracking or write a project/SwiftData record.
final class AnalysisVisualEffectsTests: XCTestCase {
    @MainActor
    func testLoupeFollowsActualTrackedPlayerWithoutRetrackingForAnotherEffect() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Stress-test recording unavailable")
        let detections = try await AnalysisEngine.analyze(url: url, range: 3...3.1) { _ in }
        let seed = try XCTUnwrap(detections.frames.first?.detections.first {
            $0.rect.contains(CGPoint(x: 0.394, y: 0.586))
        }?.rect)
        var motion = try await SelectedPlayerTracking.track(url: url, seed: seed, from: 3, to: 5.2) { _ in }
        motion.trackID = UUID()
        let box = try XCTUnwrap(motion.box(at: 5))
        XCTAssertEqual(box.midX, 1040.0 / 1920, accuracy: 0.035)
        var ring = AnalysisAnnotation(tool: .player, points: [seed.origin, CGPoint(x: seed.maxX, y: seed.maxY)], start: 3, end: 5.2)
        ring.playerMotion = motion.bound(at: 3)
        var loupe = AnalysisAnnotation(tool: .loupe, points: [CGPoint(x: seed.midX, y: seed.midY)], start: 3, end: 5.2)
        loupe.playerMotion = ring.playerMotion
        loupe.loupeStyle = .init(magnification: 3, diameter: 0.22, offset: .init(x: 0, y: -0.20))
        XCTAssertEqual(loupe.playerMotion?.trackID, ring.playerMotion?.trackID)
        XCTAssertEqual(loupe.playerMotion?.samples, ring.playerMotion?.samples)
        XCTAssertEqual(loupe.points(at: 5)[0].x, box.midX, accuracy: 0.02)
        let recording = Recording(projectID: UUID(), localPath: url.lastPathComponent, duration: 33)
        var clip = CompositionClip(recordingID: recording.id, startSeconds: 3, endSeconds: 5.2)
        clip.annotations = [ring, loupe]
        let asset = try await CompositionRenderer.makeAsset(clips: [clip], recordings: [recording])
        let composition = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: [clip], recordings: [recording], aspectRatio: "original")
        let generator = AVAssetImageGenerator(asset: asset); generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for time in [0.0, 1.0, 2.0] {
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "Actual tracked player loupe at source \(time + 3)s"
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    @MainActor
    func testAerialDashedLineAndTimedLoupeFollowSharedSyntheticMotionInPreviewAndExport() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Run on the fixture phone")
        #else
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Stress-test recording unavailable")

        let recording = Recording(projectID: UUID(), localPath: url.lastPathComponent, duration: 33)
        var samples: [PlayerMotionSample] = []
        for index in 0...20 {
            // Linear, known feet path used only to make the saved effect move.
            let fraction = CGFloat(index) / 20
            let feet = CGPoint(x: (755 + fraction * 285) / 1920, y: (674 + fraction * 62) / 1080)
            samples.append(.init(time: 3 + Double(index) * 0.1, box: CGRect(x: feet.x - 0.025, y: feet.y - 0.10, width: 0.05, height: 0.10)))
        }
        let sharedPlayerMotion = PlayerMotion(samples: samples, smoothing: 0)
        let initialBox = try XCTUnwrap(sharedPlayerMotion.box(at: 3))

        var aerial = AnalysisAnnotation(tool: .zone,
                                        points: [CGPoint(x: 0.30, y: 0.55), CGPoint(x: 0.58, y: 0.55),
                                                 CGPoint(x: 0.62, y: 0.78), CGPoint(x: 0.27, y: 0.78)],
                                        start: 3, end: 5.1)
        aerial.effect = .aerial
        aerial.areaFill = 0.22
        aerial.wallHeight = 0.2

        var line = AnalysisAnnotation(tool: .line,
                                      points: [CGPoint(x: 0.30, y: 0.82), CGPoint(x: 0.62, y: 0.82)],
                                      width: 0.004, start: 3, end: 5.1)
        line.lineStyle = AnnotationLineStyle(pattern: .dashed, start: .point, end: .arrow)

        var loupe = AnalysisAnnotation(tool: .loupe, points: [CGPoint(x: initialBox.midX, y: initialBox.midY)], start: 3, end: 5.1)
        loupe.playerMotion = sharedPlayerMotion
        loupe.loupeStyle = AnnotationLoupeStyle(magnification: 3, diameter: 0.24, offset: CGPoint(x: 0, y: -0.18))

        var clip = CompositionClip(recordingID: recording.id, startSeconds: 3, endSeconds: 5.1)
        clip.annotations = [aerial, line, loupe]
        clip = try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip))
        XCTAssertEqual(clip.annotations[1].lineStyle, line.lineStyle)
        XCTAssertEqual(clip.annotations[2].loupeStyle, loupe.loupeStyle)
        XCTAssertEqual(clip.annotations[0].effect, .aerial)
        XCTAssertEqual(clip.annotations.map(\.tool), [.zone, .line, .loupe], "Layer order must survive Codable")
        XCTAssertGreaterThan(clip.annotations[2].points(at: 5)[0].x, clip.annotations[2].points(at: 3)[0].x)

        let asset = try await CompositionRenderer.makeAsset(clips: [clip], recordings: [recording])
        let composition = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: [clip], recordings: [recording], aspectRatio: "original")
        let exported = try await CompositionRenderer.export(asset: asset, id: UUID(), videoComposition: composition) { _ in }
        defer { try? FileManager.default.removeItem(at: exported) }

        let preview = AVAssetImageGenerator(asset: asset); preview.videoComposition = composition
        let encoded = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        for (name, generator) in [("Preview", preview), ("Export", encoded)] {
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            for (sourceTime, timelineTime) in [(3.0, 0.0), (5.0, 2.0)] {
                let image = try await generator.image(at: CMTime(seconds: timelineTime, preferredTimescale: 600)).image
                XCTAssertGreaterThan(image.width, 0)
                let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                let geometry = try XCTUnwrap(AnnotationLoupeGeometry.make(mark: clip.annotations[2], time: sourceTime, frame: frame, bounds: frame))
                XCTAssertGreaterThan(geometry.radius, 0)
                let attachment = XCTAttachment(image: UIImage(cgImage: image))
                attachment.name = "\(name) source-time \(sourceTime)s — synthetic player follow"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        #endif
    }
}
