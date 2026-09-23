@preconcurrency import AVFoundation
import UIKit
import XCTest
import simd
@testable import Camelot

final class GroundedEffectTests: XCTestCase {
    func testPartialSeedUsesLaterFullBodyWithoutBorrowingAcrossIdentityGaps() throws {
        let clipped = CGRect(x: 0, y: 0.4, width: 0.025, height: 0.2)
        let complete = CGRect(x: 0.1, y: 0.4, width: 0.08, height: 0.2)
        var motion = PlayerMotion(samples: [.init(time: 0, box: clipped), .init(time: 0.1, box: clipped),
                                            .init(time: 0.2, box: complete)], smoothing: 0)
        let body = try XCTUnwrap(motion.effectBodyBox(at: 0))
        XCTAssertEqual(body.width, complete.width, accuracy: 0.001)
        XCTAssertLessThan(body.minX, 0)
        XCTAssertEqual(body.maxX, clipped.maxX, accuracy: 0.001)
        motion.gaps = [0.05...0.15]
        XCTAssertNil(motion.effectBodyBox(at: 0))
        motion.gaps = nil; motion.correctionTimes = [0.2]
        XCTAssertNil(motion.effectBodyBox(at: 0))
    }

    private func camera(_ point: SIMD3<Float>, roll: Float = 0) -> CGPoint {
        let tilt: Float = 0.45
        let x = point.x - 10, y = point.y + 20
        let cameraY = 8 * cos(tilt) - y * sin(tilt) - point.z * cos(tilt)
        let depth = 8 * sin(tilt) + y * cos(tilt) - point.z * sin(tilt)
        let rx = cos(roll) * x - sin(roll) * cameraY
        let ry = sin(roll) * x + cos(roll) * cameraY
        return .init(x: Double(rx / depth) / (16.0 / 9) + 0.5, y: Double(ry / depth) + 0.5)
    }

    func testWallUsesMetricDepthAndCameraRoll() throws {
        for roll: Float in [0, 0.18] {
            let corners = [SIMD3<Float>(0, 0, 0), .init(20, 0, 0), .init(20, 40, 0), .init(0, 40, 0)]
            let ground = GroundCalibration(mode: .plane, points: corners.map { camera($0, roll: roll) }, lengthMeters: 20, widthMeters: 40, referenceTime: 0, imageAspectRatio: 16.0 / 9, fixedCamera: true)
            let projection = try XCTUnwrap(GroundEffectProjection(ground: ground, at: 0))
            var heights: [Double] = []
            for depth: Float in [0, 40] {
                let feet = camera(.init(10, depth, 0), roll: roll)
                let top = try XCTUnwrap(projection.raised(feet, meters: 2))
                let expected = camera(.init(10, depth, 2), roll: roll)
                XCTAssertEqual(top.x, expected.x, accuracy: 0.003)
                XCTAssertEqual(top.y, expected.y, accuracy: 0.003)
                heights.append(hypot(top.x - feet.x, top.y - feet.y))
            }
            XCTAssertGreaterThan(heights[0], heights[1] * 2)
        }
    }

    func testSavedCameraWarpMovesWallBaseAndTopTogether() throws {
        let corners = [SIMD3<Float>(0, 0, 0), .init(20, 0, 0), .init(20, 40, 0), .init(0, 40, 0)]
        let warp = CameraTransform(values: [1.1, -0.08, 0.1, 0.08, 1.1, -0.12, 0.015, -0.02, 1])
        let motion = AnnotationCameraMotion(samples: [.init(time: 0, transform: .identity), .init(time: 2, transform: warp)])
        let ground = GroundCalibration(mode: .plane, points: corners.map { camera($0) }, lengthMeters: 20, widthMeters: 40, referenceTime: 0, imageAspectRatio: 16.0 / 9, cameraMotion: motion)
        let start = try XCTUnwrap(GroundEffectProjection(ground: ground, at: 0))
        let end = try XCTUnwrap(GroundEffectProjection(ground: ground, at: 2))
        let base = camera(.init(10, 15, 0))
        let expected = try XCTUnwrap(warp.point(try XCTUnwrap(start.raised(base, meters: 3))))
        let actual = try XCTUnwrap(end.raised(try XCTUnwrap(warp.point(base)), meters: 3))
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.0001)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.0001)
    }

    func testClippedFeetNeverSnapToImageBottomAndWidthKeepsBodyScale() throws {
        var motion = PlayerMotion(samples: (0...60).map { i in
            let t = Double(i) / 30, top = 0.72 + t * 0.12
            return .init(time: t, box: .init(x: 0.3, y: top, width: 0.05, height: min(0.18, 1 - top)))
        }, smoothing: 0)
        let full = try XCTUnwrap(motion.effectBodyBox(at: 0.5))
        let clipped = try XCTUnwrap(motion.effectBodyBox(at: 1.5))
        XCTAssertEqual(full.height, clipped.height, accuracy: 0.001)
        XCTAssertEqual(full.width, clipped.width, accuracy: 0.001)
        XCTAssertGreaterThan(try XCTUnwrap(motion.groundPoint(at: 1.5)).y, 1.05)
        motion.gaps = [1...1.2]
        XCTAssertNil(motion.effectBodyBox(at: 1.5), "Do not infer a floor position across lost identity")
    }

    func testClippedEffectResizeRoundTripKeepsTheVisiblePoseAndRawTracking() throws {
        let seed = CGRect(x: 0.3, y: 0.72, width: 0.05, height: 0.18)
        let motion = PlayerMotion(samples: (0...60).map { i in
            let time = Double(i) / 30, top = 0.72 + time * 0.12
            return .init(time: time, box: .init(x: 0.3, y: top, width: 0.05, height: min(0.18, 1 - top)))
        }, smoothing: 0)
        var mark = AnalysisAnnotation(tool: .player, points: [seed.origin, .init(x: seed.maxX, y: seed.maxY)], start: 0, end: 3)
        mark.playerMotion = motion
        let pose = mark.points(at: 1.5).map { CGPoint(x: $0.x + 0.01, y: $0.y - 0.01) }
        mark.moveDrawing(to: pose, at: 1.5)
        for (expected, actual) in zip(pose, mark.points(at: 1.5)) {
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.0001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.0001)
        }
        XCTAssertEqual(mark.playerMotion, motion)
        XCTAssertGreaterThan(mark.editHandles(at: 1.5)[2].y, 1)
    }

    func testMissingCameraCoverageNeverUsesAStaleGroundProjection() {
        let corners = [SIMD3<Float>(0, 0, 0), .init(20, 0, 0), .init(20, 40, 0), .init(0, 40, 0)]
        let ground = GroundCalibration(mode: .plane, points: corners.map { camera($0) }, lengthMeters: 20, widthMeters: 40, referenceTime: 0, imageAspectRatio: 16.0 / 9)
        XCTAssertNotNil(GroundEffectProjection(ground: ground, at: 0))
        XCTAssertNil(GroundEffectProjection(ground: ground, at: 2))
    }

    func testGroundingAndMetricHeightRoundTripWithoutChangingLegacyChoice() throws {
        var wall = AnalysisAnnotation(tool: .line, points: [.zero, .init(x: 1, y: 1)], start: 0, end: 3)
        XCTAssertFalse(wall.isGrounded(hasField: true))
        wall.effect = .wall; wall.grounded = true; wall.wallHeightMeters = 2.4
        let restored = try JSONDecoder().decode(AnalysisAnnotation.self, from: JSONEncoder().encode(wall))
        XCTAssertEqual(restored, wall)
        XCTAssertTrue(restored.isGrounded(hasField: true))
    }

    @MainActor
    func testActualPlayerLeavingBottomEdgeRetainsFullBodyExtent() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Run on fixture phone")
        let result = try await AnalysisEngine.analyze(url: url, range: 0...0.1) { _ in }
        let seed = try XCTUnwrap(result.frames.first?.detections.first { $0.rect.contains(.init(x: 0.329, y: 0.84)) }?.rect)
        let motion = try await SelectedPlayerTracking.track(url: url, seed: seed, from: 0, to: 3.2) { _ in }
        XCTAssertNotNil(motion.box(at: 1.5))
        let body = try XCTUnwrap(motion.effectBodyBox(at: 2))
        XCTAssertGreaterThan(body.maxY, 1)
        XCTAssertGreaterThan(body.height, seed.height * 0.85)
        var ring = AnalysisAnnotation(tool: .player, points: [seed.origin, .init(x: seed.maxX, y: seed.maxY)], start: 0, end: 3.2)
        ring.playerMotion = motion; ring.effect = .radar
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for time in [0.0, 1, 1.5, 2, 2.5, 3] {
            print("EDGE_BODY time=\(time) raw=\(String(describing: motion.box(at: time))) effect=\(String(describing: motion.effectBodyBox(at: time)))")
            let source = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let frame = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            let rendered = UIGraphicsImageRenderer(size: frame.size).image { renderer in
                UIImage(cgImage: source).draw(in: frame)
                AnnotationRenderer.draw([ring], time: time, in: renderer.cgContext, frame: frame)
            }
            let attachment = XCTAttachment(image: rendered); attachment.name = "Player leaving lower edge at \(time)s"; attachment.lifetime = .keepAlways; add(attachment)
        }
        if let feet = motion.groundPoint(at: 2.5) { XCTAssertGreaterThan(feet.y, 1, "Hidden feet cannot be placed on the visible crop edge") }
        // Reproduce an already-saved clipped box even if today's tracker stops
        // conservatively before this frame. Head position read from the footage;
        // synthetic box extent deliberately ends at the crop boundary.
        var saved = motion
        saved.samples = motion.samples.filter { $0.time < 1.3 }
        saved.samples.append(.init(time: 2.5, box: .init(x: 0.092, y: 0.905, width: 0.03, height: 0.095)))
        saved.lostAt = nil; saved.gaps = nil
        XCTAssertGreaterThan(try XCTUnwrap(saved.groundPoint(at: 2.5)).y, 1)
        ring.playerMotion = saved
        let source = try await generator.image(at: CMTime(seconds: 2.5, preferredTimescale: 600)).image
        let frame = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let image = UIGraphicsImageRenderer(size: frame.size).image { renderer in
            UIImage(cgImage: source).draw(in: frame)
            AnnotationRenderer.draw([ring], time: 2.5, in: renderer.cgContext, frame: frame)
        }
        let attachment = XCTAttachment(image: image); attachment.name = "Controlled legacy clipped box on real 2.5s frame, feet remain offscreen"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testGroundedWallAndAerialDepthOnFootageInPreviewAndExport() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Run on fixture phone")
        // Deliberately manual approximate plane: test projection/rendering, not
        // an automatic claim of correct pitch calibration on this recording.
        let ground = GroundCalibration(mode: .plane, points: [.init(x: 0.2, y: 0.52), .init(x: 0.7, y: 0.50), .init(x: 0.9, y: 0.90), .init(x: 0.1, y: 0.90)], lengthMeters: 30, widthMeters: 25, referenceTime: 0, imageAspectRatio: 16.0 / 9, fixedCamera: true)
        let projection = try XCTUnwrap(GroundEffectProjection(ground: ground, at: 0))
        let near = CGPoint(x: 0.25, y: 0.85), far = CGPoint(x: 0.45, y: 0.55)
        let nearTop = try XCTUnwrap(projection.raised(near, meters: 3)), farTop = try XCTUnwrap(projection.raised(far, meters: 3))
        XCTAssertGreaterThan(near.y - nearTop.y, far.y - farTop.y)
        var wall = AnalysisAnnotation(tool: .line, points: [near, far], start: 0, end: 0.8)
        wall.effect = .wall; wall.grounded = true; wall.wallHeightMeters = 3
        var roof = AnalysisAnnotation(tool: .zone, points: [.init(x: 0.5, y: 0.85), .init(x: 0.5, y: 0.55), .init(x: 0.65, y: 0.55), .init(x: 0.75, y: 0.85)], start: 0, end: 0.8)
        roof.effect = .aerial; roof.grounded = true; roof.wallHeightMeters = 3
        let recording = Recording(projectID: UUID(), localPath: url.lastPathComponent, duration: 33)
        var clip = CompositionClip(recordingID: recording.id, startSeconds: 0, endSeconds: 0.8)
        var rectangle = AnalysisAnnotation(tool: .rectangle, points: [.init(x: 0.24, y: 0.55), .init(x: 0.42, y: 0.77)], start: 0, end: 0.8)
        rectangle.grounded = true
        var ellipse = AnalysisAnnotation(tool: .ellipse, points: [.init(x: 0.55, y: 0.6), .init(x: 0.75, y: 0.8)], start: 0, end: 0.8)
        ellipse.grounded = true
        var arrow = AnalysisAnnotation(tool: .arrow, points: [.init(x: 0.3, y: 0.9), .init(x: 0.3, y: 0.6)], start: 0, end: 0.8)
        arrow.grounded = true; arrow.lineStyle = .init(pattern: .dashed, start: .circle, end: .arrow)
        clip.annotations = [wall, roof, rectangle, ellipse, arrow]; clip.groundCalibration = ground
        clip = try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip))
        let asset = try await CompositionRenderer.makeAsset(clips: [clip], recordings: [recording])
        let composition = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: [clip], recordings: [recording], aspectRatio: "original")
        let output = try await CompositionRenderer.export(asset: asset, id: UUID(), videoComposition: composition) { _ in }
        defer { try? FileManager.default.removeItem(at: output) }
        let preview = AVAssetImageGenerator(asset: asset); preview.videoComposition = composition
        let export = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        for (name, generator) in [("Preview", preview), ("Export", export)] {
            let image = try await generator.image(at: .zero).image
            let attachment = XCTAttachment(image: UIImage(cgImage: image)); attachment.name = "\(name) grounded wall and roof with manual approximate field plane"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
