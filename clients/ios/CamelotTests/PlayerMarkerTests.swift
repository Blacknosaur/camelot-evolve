@preconcurrency import AVFoundation
import UIKit
import XCTest
@testable import Camelot

final class PlayerMarkerTests: XCTestCase {
    func testHeightNoiseDoesNotBounceArrowOrDelayPosition() throws {
        let samples: [PlayerMotionSample] = (0...120).map { i in
            let height = 0.15 + (i.isMultiple(of: 2) ? 0.025 : -0.025)
            return .init(time: Double(i) / 30, box: .init(x: 0.2 + Double(i) / 1000, y: 0.7 - height, width: 0.06, height: height))
        }
        let motion = PlayerMotion(samples: samples, smoothing: 0)
        var mark = AnalysisAnnotation(tool: .player, points: [], start: 0, end: 4)
        mark.playerMotion = motion; mark.effect = .neon
        var heights: [CGFloat] = []
        for i in 30...90 {
            let time = Double(i) / 30, body = try XCTUnwrap(motion.effectBodyBox(at: time))
            let path = GameAnnotationEffects.playerMarker(rect: body, mark: mark, time: time)
            heights.append(path.boundingBox.maxY)
            XCTAssertEqual(path.boundingBox.midX, body.midX, accuracy: 0.00001, "Height averaging never delays player position")
        }
        XCTAssertLessThan(try XCTUnwrap(heights.max()) - XCTUnwrap(heights.min()), 0.001)
        XCTAssertEqual(motion.samples, samples, "Rendering does not rewrite tracking")
    }

    func testHeightFollowsGradualPerspectiveAndDoesNotBlendAcrossAbsence() throws {
        var motion = PlayerMotion(samples: (0...120).map { i in
            let height = 0.1 + Double(i) / 1200
            return .init(time: Double(i) / 30, box: .init(x: 0.4, y: 0.7 - height, width: 0.05, height: height))
        })
        XCTAssertEqual(try XCTUnwrap(motion.overheadHeight(at: 1)), 0.125, accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(motion.overheadHeight(at: 3)), 0.175, accuracy: 0.002)
        motion.gaps = [1...2.5]
        XCTAssertNil(motion.overheadHeight(at: 2))
        motion.samples = [.init(time: 0.9, box: .init(x: 0.4, y: 0.4, width: 0.1, height: 0.3)),
                          .init(time: 2.6, box: .init(x: 0.4, y: 0.6, width: 0.04, height: 0.1))]
        XCTAssertEqual(try XCTUnwrap(motion.overheadHeight(at: 2.6)), 0.1, accuracy: 0.00001)
    }

    func testStaticArrowHasNoBobbingAnimation() {
        var mark = AnalysisAnnotation(tool: .player, points: [], start: 0, end: 4); mark.effect = .neon
        let rect = CGRect(x: 100, y: 100, width: 30, height: 90)
        XCTAssertEqual(GameAnnotationEffects.playerMarker(rect: rect, mark: mark, time: 0).boundingBox,
                       GameAnnotationEffects.playerMarker(rect: rect, mark: mark, time: 1).boundingBox)
    }

    @MainActor
    func testAveragedArrowOnActualTrackedFootageInPreviewAndExport() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Requires fixture phone")
        let detections = try await AnalysisEngine.analyze(url: url, range: 3...3.1) { _ in }
        let seed = try XCTUnwrap(detections.frames.first?.detections.first { $0.rect.contains(.init(x: 0.394, y: 0.586)) }?.rect)
        let motion = try await SelectedPlayerTracking.track(url: url, seed: seed, from: 3, to: 5.2) { _ in }
        var mark = AnalysisAnnotation(tool: .player, points: [seed.origin, .init(x: seed.maxX, y: seed.maxY)], start: 3, end: 5.2)
        mark.playerMotion = motion.bound(at: 3); mark.effect = .neon
        let recording = Recording(projectID: UUID(), localPath: url.lastPathComponent, duration: 33)
        var clip = CompositionClip(recordingID: recording.id, startSeconds: 3, endSeconds: 5.2); clip.annotations = [mark]
        let asset = try await CompositionRenderer.makeAsset(clips: [clip], recordings: [recording])
        let composition = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: [clip], recordings: [recording], aspectRatio: "original")
        let exported = try await CompositionRenderer.export(asset: asset, id: UUID(), videoComposition: composition) { _ in }
        defer { try? FileManager.default.removeItem(at: exported) }
        let movie = XCTAttachment(contentsOfFile: exported); movie.name = "Averaged player arrow actual motion"; movie.lifetime = .keepAlways; add(movie)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for time in [0.0, 0.5, 1, 1.5, 2] {
            XCTAssertNotNil(motion.overheadHeight(at: time + 3))
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let attachment = XCTAttachment(image: UIImage(cgImage: image)); attachment.name = "Averaged arrow at \(time + 3)s"
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
