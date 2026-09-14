@preconcurrency import AVFoundation
import UIKit
import XCTest
@testable import Camelot

final class GameAnalysisTests: XCTestCase {
    func testKitAppearanceToleratesLightingButSeparatesBlueAndWhite() {
        let blue = SIMD3<Float>(0.1, 0.25, 0.6)
        func signature(_ color: SIMD3<Float>) -> PlayerJerseySignature { .init(colors: [color]) }
        XCTAssertGreaterThan(signature(blue).similarity(to: signature(blue * 0.5)), 0.95)
        XCTAssertGreaterThan(signature(.init(0.85, 0.9, 0.8)).similarity(to: signature(.init(0.55, 0.6, 0.53))), 0.70)
        XCTAssertLessThan(signature(blue).similarity(to: signature(.init(0.85, 0.9, 0.8))), 0.45)
    }

    func testPlayerAreaDoesNotSelfIntersectWhenPlayersExchangeOrder() {
        let hull = GameAnnotationEffects.convexHull([.zero, .init(x: 1, y: 1), .init(x: 1, y: 0), .init(x: 0, y: 1), .init(x: 0.5, y: 0.5)])
        XCTAssertEqual(hull, [.zero, .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])
    }
    @MainActor
    func testTrackingRecoveryBenchmarkOnStressPlayers() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Run on the fixture phone")
        #else
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Stress-test recording unavailable")
        let detections = try await AnalysisEngine.analyze(url: url, range: 3...3.1) { _ in }
        let seeds = Array((detections.frames.first?.detections ?? []).sorted { $0.rect.height > $1.rect.height }.prefix(6))
        XCTAssertEqual(seeds.count, 6)
        for (index, seed) in seeds.enumerated() {
            let baseline = try await SelectedPlayerTracking.track(url: url, seed: seed.rect, from: 3, to: 12, allowRecovery: false) { _ in }
            let began = Date()
            let recovered = try await SelectedPlayerTracking.track(url: url, seed: seed.rect, from: 3, to: 12) { _ in }
            print("RECOVERY_ABLATION player=\(index) seed=\(seed.rect) baseline=\(baseline.lostAt ?? 12) recovered=\(recovered.lostAt ?? 12) recoveries=\(recovered.recoveryCount ?? 0) processing=\(Date().timeIntervalSince(began))")
            print("RECOVERY_FINAL player=\(index) box=\(String(describing: recovered.samples.last))")
            // This measures coverage only, not identity accuracy. Known identity
            // cases are separately checked against manually read source positions.
            XCTAssertFalse(recovered.samples.isEmpty)
        }
        #endif
    }
    func testConnectedPlayersMoveIndependentlyAndHideMissingAnchors() throws {
        var mark = AnalysisAnnotation(tool: .connection, points: [.init(x: 0.2, y: 0.5), .init(x: 0.7, y: 0.5)], start: 0, end: 3)
        mark.linkedPlayers = [
            .init(samples: [.init(time: 0, box: .init(x: 0.15, y: 0.3, width: 0.1, height: 0.2)), .init(time: 2, box: .init(x: 0.25, y: 0.4, width: 0.1, height: 0.2))]),
            .init(samples: [.init(time: 0, box: .init(x: 0.65, y: 0.3, width: 0.1, height: 0.2)), .init(time: 2, box: .init(x: 0.55, y: 0.2, width: 0.1, height: 0.2))])
        ]
        XCTAssertEqual(mark.points(at: 1)[0].x, 0.25, accuracy: 0.001)
        XCTAssertEqual(mark.points(at: 1)[1].x, 0.65, accuracy: 0.001)
        XCTAssertEqual(mark.points(at: 1)[0].y, 0.55, accuracy: 0.001)
        XCTAssertEqual(mark.points(at: 1)[1].y, 0.45, accuracy: 0.001)
        let edited = [CGPoint(x: 0.28, y: 0.57), CGPoint(x: 0.65, y: 0.45)]
        mark.moveDrawing(to: edited, at: 1)
        XCTAssertEqual(mark.points(at: 1)[0].x, edited[0].x, accuracy: 0.001)
        let moved = mark.applying(.move(0.5), within: 0...4)
        XCTAssertEqual(moved.linkedPlayers, mark.linkedPlayers)
        mark.linkedPlayers?[1].gaps = [0.9...1.1]
        XCTAssertEqual(mark.opacity(at: 1), 0)
        XCTAssertFalse(mark.hasMotion(at: 1))
        XCTAssertEqual(mark, try JSONDecoder().decode(AnalysisAnnotation.self, from: JSONEncoder().encode(mark)))
    }

    func testCameraMotionRoundTripInterpolationAndEditing() throws {
        var mark = AnalysisAnnotation(tool: .zone, points: [.init(x: 0.1, y: 0.5), .init(x: 0.5, y: 0.5), .init(x: 0.5, y: 0.8)], start: 0, end: 3)
        mark.cameraMotion = .init(samples: [.init(time: 0, transform: .identity), .init(time: 2, transform: .init(values: [1, 0, 0.2, 0, 1, -0.1, 0, 0, 1]))])
        XCTAssertEqual(mark.points(at: 1)[0].x, 0.2, accuracy: 0.001)
        XCTAssertEqual(mark.points(at: 1)[0].y, 0.45, accuracy: 0.001)
        mark.moveDrawing(to: [.init(x: 0.3, y: 0.4), .init(x: 0.5, y: 0.5), .init(x: 0.6, y: 0.8)], at: 1)
        XCTAssertEqual(mark.points(at: 1)[0].x, 0.3, accuracy: 0.001)
        XCTAssertEqual(mark.opacity(at: 2.5), 0)
        XCTAssertEqual(mark, try JSONDecoder().decode(AnalysisAnnotation.self, from: JSONEncoder().encode(mark)))
        mark.enableKeyframes(at: 1)
        XCTAssertEqual(mark.motionMode, .keyframes)
        XCTAssertNil(mark.cameraMotion)
    }

    @MainActor
    func testCameraRegistrationRejectsAnUnrelatedShot() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision registration requires the physical device")
        #else
        func image(_ seed: Int) -> CGImage {
            UIGraphicsImageRenderer(size: .init(width: 640, height: 360)).image { renderer in
                UIColor.black.setFill(); renderer.fill(.init(x: 0, y: 0, width: 640, height: 360))
                for index in 0..<150 {
                    UIColor(hue: CGFloat((index * seed) % 17) / 17, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
                    renderer.fill(CGRect(x: (index * seed * 83) % 620, y: (index * seed * 47) % 340, width: 14 + index % 11, height: 12 + index % 19))
                }
            }.cgImage!
        }
        XCTAssertNil(try? CameraMotionTracking.register(previous: image(1), current: image(23)))
        XCTAssertNil(try? CameraMotionTracking.registerBackground(previous: image(1), current: image(23)))
        #endif
    }

    @MainActor
    func testCameraRegistrationMapsPreviousIntoCurrentNotInverse() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision registration requires the physical device")
        #else
        let size = CGSize(width: 640, height: 360)
        let source = UIGraphicsImageRenderer(size: size).image { renderer in
            UIColor.darkGray.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            for index in 0..<120 {
                UIColor(hue: CGFloat(index % 17) / 17, saturation: 0.6, brightness: 0.5 + CGFloat(index % 3) * 0.2, alpha: 1).setFill()
                renderer.fill(CGRect(x: (index * 83) % 620, y: (index * 47) % 340, width: 14 + index % 11, height: 12 + index % 19))
            }
        }
        let current = UIGraphicsImageRenderer(size: size).image { _ in source.draw(at: CGPoint(x: 12, y: -7)) }
        let transform = try XCTUnwrap(CameraMotionTracking.register(previous: try XCTUnwrap(source.cgImage), current: try XCTUnwrap(current.cgImage)))
        let point = try XCTUnwrap(transform.point(.init(x: 0.5, y: 0.5)))
        XCTAssertEqual(point.x, 0.5 + 12 / 640.0, accuracy: 0.004)
        XCTAssertEqual(point.y, 0.5 - 7 / 360.0, accuracy: 0.004)
        let background = try XCTUnwrap(CameraMotionTracking.registerBackground(previous: try XCTUnwrap(source.cgImage), current: try XCTUnwrap(current.cgImage)))
        let scenePoint = try XCTUnwrap(background.point(.init(x: 0.5, y: 0.5)))
        XCTAssertEqual(scenePoint.x, 0.5 + 12 / 640.0, accuracy: 0.004)
        XCTAssertEqual(scenePoint.y, 0.5 - 7 / 360.0, accuracy: 0.004)
        #endif
    }

    @MainActor
    func testEffectsAreDeterministicAnimatedAndSupportPolygonAreas() throws {
        let size = CGSize(width: 640, height: 360)
        var ring = AnalysisAnnotation(tool: .player, points: [.init(x: 0.45, y: 0.3), .init(x: 0.51, y: 0.6)], start: 0, end: 3)
        ring.effect = .radar
        var area = AnalysisAnnotation(tool: .zone, points: [.init(x: 0.1, y: 0.6), .init(x: 0.3, y: 0.55), .init(x: 0.4, y: 0.8), .init(x: 0.15, y: 0.9)], start: 0, end: 3)
        area.effect = .neon
        var connection = AnalysisAnnotation(tool: .connection, points: [.init(x: 0.3, y: 0.5), .init(x: 0.6, y: 0.6), .init(x: 0.8, y: 0.4)], start: 0, end: 3)
        connection.effect = .neon
        func render(_ time: Double) -> UIImage {
            UIGraphicsImageRenderer(size: size).image { renderer in
                UIColor.black.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
                AnnotationRenderer.draw([area, connection, ring], time: time, in: renderer.cgContext, frame: CGRect(origin: .zero, size: size))
            }
        }
        XCTAssertEqual(render(0.5).pngData(), render(0.5).pngData())
        XCTAssertNotEqual(render(0.5).pngData(), render(1).pngData())
        let attachment = XCTAttachment(image: render(0.5)); attachment.name = "Game-style markers, connected players and polygon area"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testCameraTrackingOnStressVideo() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Run on the fixture phone")
        #else
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Stress-test recording unavailable")
        let began = Date()
        let motion = try await CameraMotionTracking.track(url: url, from: 3, to: 6) { _ in }
        print("CAMERA_BENCHMARK seconds=\(Date().timeIntervalSince(began)) samples=\(motion.samples.count) lost=\(String(describing: motion.lostAt)) last=\(String(describing: motion.samples.last))")
        XCTAssertGreaterThan(motion.samples.count, 20)
        XCTAssertNil(motion.lostAt)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var mark = AnalysisAnnotation(tool: .zone, points: [.init(x: 0.1, y: 0.65), .init(x: 0.3, y: 0.65), .init(x: 0.4, y: 0.85), .init(x: 0.12, y: 0.85)], start: 3, end: 6)
        mark.effect = .neon; mark.cameraMotion = motion
        for time in [3.0, 5.8] {
            let source = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let size = CGSize(width: source.width, height: source.height)
            let image = UIGraphicsImageRenderer(size: size).image { renderer in
                UIImage(cgImage: source).draw(in: CGRect(origin: .zero, size: size))
                AnnotationRenderer.draw([mark], time: time, in: renderer.cgContext, frame: CGRect(origin: .zero, size: size))
            }
            let attachment = XCTAttachment(image: image); attachment.name = "Camera-locked area at \(time)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        #endif
    }
}
