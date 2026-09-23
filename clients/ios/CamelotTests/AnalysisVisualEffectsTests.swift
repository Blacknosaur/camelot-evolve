@preconcurrency import AVFoundation
import CoreGraphics
import UIKit
import XCTest
@testable import Camelot

/// Real-footage and explicitly labelled synthetic-motion checks. These never
/// write a project or SwiftData record.
final class AnalysisVisualEffectsTests: XCTestCase {
    @MainActor
    func testDistantPlayerTrackingOnStressFootage() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Run on fixture phone")
        let detections = try await AnalysisEngine.analyze(url: url, range: 3...3.1) { _ in }
        for point in [CGPoint(x: 0.148, y: 0.46), CGPoint(x: 0.497, y: 0.448)] {
            let seed = try XCTUnwrap(detections.frames.first?.detections.first { $0.rect.contains(point) }?.rect)
            let motion = try await SelectedPlayerTracking.track(url: url, seed: seed, from: 3, to: 14) { _ in }
            print("DISTANT_PLAYER seed=\(seed) last=\(String(describing: motion.samples.last?.time)) lost=\(String(describing: motion.lostAt)) gaps=\(motion.gaps ?? []) confirmed=\(motion.jerseyProfile?.isConfirmed == true)")
            for time in [3.0, 5, 7, 9, 12.6, 13.5] { print("DISTANT_POSITION seedX=\(point.x) t=\(time) box=\(String(describing: motion.box(at: time)))") }
            XCTAssertNil(motion.lostAt)
            XCTAssertGreaterThan(try XCTUnwrap(motion.samples.last?.time), 13.9)
            let returned = try XCTUnwrap(motion.box(at: 12.6))
            XCTAssertEqual(returned.midX, point.x < 0.2 ? 0.335 : 0.647, accuracy: 0.02)
            XCTAssertEqual(returned.maxY, point.x < 0.2 ? 0.465 : 0.52, accuracy: 0.015)
            XCTAssertEqual(try XCTUnwrap(motion.box(at: 13.5)).midX, point.x < 0.2 ? 0.214 : 0.553, accuracy: 0.02)
            XCTAssertNil(motion.box(at: 9.8), "Blur/absence remains hidden, not a predicted ring")
            if point.x > 0.2 { XCTAssertNil(motion.box(at: 10.8), "Defender is outside the camera here") }
            var ring = AnalysisAnnotation(tool: .player, points: [seed.origin, .init(x: seed.maxX, y: seed.maxY)], start: 3, end: 14)
            ring.playerMotion = motion.bound(at: 3); ring.effect = .neon
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            for time in [9.0, 10.8, 12.6, 13.5] {
                let source = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
                let size = CGSize(width: source.width, height: source.height), frame = CGRect(x: 0, y: 0, width: source.width, height: source.height)
                let rendered = UIGraphicsImageRenderer(size: size).image { renderer in
                    UIImage(cgImage: source).draw(in: frame)
                    AnnotationRenderer.draw([ring], time: time, in: renderer.cgContext, frame: frame)
                }
                let attachment = XCTAttachment(image: rendered); attachment.name = "Distant player \(point.x) before and after pan at \(time)s"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    @MainActor
    func testTwoActualPlayerTracksStayConnectedAcrossControlledThirdPlayerLoss() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Run on fixture phone")
        let detections = try await AnalysisEngine.analyze(url: url, range: 3...3.1) { _ in }
        var tracks: [PlayerMotion] = []
        for point in [CGPoint(x: 0.394, y: 0.586), CGPoint(x: 0.685, y: 0.53)] {
            let seed = try XCTUnwrap(detections.frames.first?.detections.first { $0.rect.contains(point) }?.rect)
            var motion = try await SelectedPlayerTracking.track(url: url, seed: seed, from: 3, to: 5.2) { _ in }
            motion.trackID = UUID(); tracks.append(motion)
        }
        // Controlled missing endpoint, not a claim of automatic occlusion
        // detection. Both surviving endpoints use actual independently tracked footage.
        let missingBox = CGRect(x: 0.8, y: 0.4, width: 0.04, height: 0.1)
        let missing = PlayerMotion(samples: [.init(time: 3, box: missingBox), .init(time: 5.2, box: missingBox)],
                                   gaps: [3.5...4.5], trackID: UUID())
        let endpoints = [tracks[0], missing, tracks[1]]
        var line = AnalysisAnnotation(tool: .connection,
            points: endpoints.map { .init(x: $0.reference!.midX, y: $0.reference!.maxY) }, start: 3, end: 5.2)
        line.linkedPlayers = endpoints
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for time in [3.25, 4.0, 5.0] {
            XCTAssertTrue(line.hasMotion(at: time))
            let points = line.renderedPoints(at: time)
            XCTAssertEqual(points.count, time == 4 ? 2 : 3)
            XCTAssertEqual(points.first!.x, try XCTUnwrap(tracks[0].box(at: time)).midX, accuracy: 0.001)
            XCTAssertEqual(points.last!.x, try XCTUnwrap(tracks[1].box(at: time)).midX, accuracy: 0.001)
            let source = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let size = CGSize(width: source.width, height: source.height)
            let rendered = UIGraphicsImageRenderer(size: size).image { renderer in
                let frame = CGRect(origin: .zero, size: size)
                UIImage(cgImage: source).draw(in: frame)
                AnnotationRenderer.draw([line], time: time, in: renderer.cgContext, frame: frame)
            }
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "Actual surviving players with controlled third-player gap at \(time)s"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(line.linkedPlayers, endpoints)
    }

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
