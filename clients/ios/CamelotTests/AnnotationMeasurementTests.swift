@preconcurrency import AVFoundation
import CoreGraphics
import UIKit
import XCTest
@testable import Camelot

/// Isolated measurement tests. Calibration dimensions are synthetic fixtures;
/// they are not claims about real-world field measurements.
final class AnnotationMeasurementTests: XCTestCase {
    private func localCalibration() -> GroundCalibration {
        GroundCalibration(mode: .localScale,
                           points: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
                           lengthMeters: 10, referenceTime: 0,
                           imageAspectRatio: 1, fixedCamera: true)
    }

    private func planeCalibration() -> GroundCalibration {
        GroundCalibration(mode: .plane,
                           points: [.init(x: 0.1, y: 0.1), .init(x: 0.9, y: 0.1),
                                    .init(x: 0.85, y: 0.9), .init(x: 0.15, y: 0.9)],
                           lengthMeters: 80, widthMeters: 40, referenceTime: 0,
                           imageAspectRatio: 1, fixedCamera: true)
    }

    func testTextSpeedUsesSourceFrameTimeAndMissingCalibrationIsUnavailable() throws {
        let samples = stride(from: 0.0, through: 1.0, by: 0.1).map {
            PlayerMotionSample(time: $0, box: .init(x: 0.2 + $0 * 0.1, y: 0.2, width: 0.05, height: 0.1))
        }
        var mark = AnalysisAnnotation(tool: .text, points: [.init(x: 0.3, y: 0.2)],
                                      text: "Runner", start: 0, end: 2)
        mark.showsSpeed = true
        mark.playerMotion = PlayerMotion(samples: samples, smoothing: 0)

        XCTAssertEqual(AnnotationMeasurements.text(for: mark, at: 0.5, ground: localCalibration()),
                       "Runner\n≈ 3.6 km/h")
        XCTAssertEqual(AnnotationMeasurements.text(for: mark, at: 0.5, ground: nil),
                       "Runner\n— km/h", "An uncalibrated speed must never become a fake zero")
    }

    func testDistancesCoverLineConnectionAndPolygonEdgesWithApproximatePrefix() {
        let calibration = localCalibration()
        for tool in [AnalysisDrawingTool.line, .connection, .zone] {
            var mark = AnalysisAnnotation(tool: tool,
                                          points: tool == .zone
                                            ? [.init(x: 0, y: 0), .init(x: 0.5, y: 0), .init(x: 0.5, y: 0.5)]
                                            : [.init(x: 0, y: 0), .init(x: 0.5, y: 0)],
                                          start: 0, end: 2)
            mark.showsDistance = true
            let labels = AnnotationMeasurements.distances(for: mark, at: 0, ground: calibration)
            XCTAssertEqual(labels.count, tool == .zone ? 3 : 1)
            XCTAssertTrue(labels.allSatisfy { $0.text.hasPrefix("≈ ") && $0.text.hasSuffix(" m") })
        }
        var uncalibrated = AnalysisAnnotation(tool: .line, points: [.zero, .init(x: 0.5, y: 0)], start: 0, end: 1)
        uncalibrated.showsDistance = true
        XCTAssertEqual(AnnotationMeasurements.distances(for: uncalibrated, at: 0, ground: nil).first?.text, "— m")
    }

    func testCalibrationPersistsOnCompositionClip() throws {
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 2)
        clip.groundCalibration = planeCalibration()
        let restored = try JSONDecoder().decode(CompositionClip.self,
                                                 from: JSONEncoder().encode(clip))
        XCTAssertEqual(restored.groundCalibration, clip.groundCalibration)
        XCTAssertEqual(restored, clip)
    }

    func testSharedCameraCorrectionRefreshesOnlyMatchingCalibrationAndAnnotations() throws {
        let matchingID = UUID(), otherID = UUID()
        func camera(_ id: UUID, tx: Double) -> AnnotationCameraMotion {
            .init(samples: [.init(time: 0, transform: .identity),
                             .init(time: 1, transform: .init(values: [1, 0, tx, 0, 1, 0, 0, 0, 1]))],
                  trackID: id)
        }
        var clip = CompositionClip(recordingID: UUID(), startSeconds: 0, endSeconds: 2)
        let matching = camera(matchingID, tx: 0.01), other = camera(otherID, tx: 0.02)
        var first = AnalysisAnnotation(tool: .player, points: [.zero, .init(x: 0.1, y: 0.2)], start: 0, end: 2)
        first.cameraMotion = matching
        first.cameraMotion?.referenceTime = 0.25
        var second = AnalysisAnnotation(tool: .player, points: [.zero, .init(x: 0.1, y: 0.2)], start: 0, end: 2)
        second.cameraMotion = other
        clip.annotations = [first, second]
        var calibration = localCalibration(); calibration.cameraMotion = matching
        clip.groundCalibration = calibration
        clip.storeCameraTrack(matching)

        var refreshed = camera(matchingID, tx: 0.2)
        refreshed.referenceTime = 0.75
        clip.storeCameraTrack(refreshed)
        XCTAssertEqual(clip.annotations[0].cameraMotion?.samples, refreshed.samples)
        XCTAssertEqual(clip.annotations[1].cameraMotion?.samples, other.samples)
        XCTAssertEqual(clip.groundCalibration?.cameraMotion?.samples, refreshed.samples)
        XCTAssertEqual(clip.annotations[0].cameraMotion?.referenceTime, 0.25,
                       "Track refresh preserves each annotation's authored reference pose")
        XCTAssertNil(clip.annotations[1].cameraMotion?.referenceTime)
        XCTAssertEqual(clip.groundCalibration?.referenceTime, 0,
                       "Camera-track refresh must not move the metric calibration frame")
    }

    func testCameraPanKeepsStationaryGroundPlayerSpeedAtZero() throws {
        let camera = AnnotationCameraMotion(samples: [
            .init(time: 0, transform: .identity),
            .init(time: 1, transform: .init(values: [1, 0, 0.1, 0, 1, 0, 0, 0, 1]))
        ])
        let calibration = GroundCalibration(mode: .localScale,
                                             points: [.init(x: 0.2, y: 0.2), .init(x: 0.4, y: 0.2)],
                                             lengthMeters: 10, referenceTime: 0,
                                             imageAspectRatio: 1, cameraMotion: camera)
        let samples = stride(from: 0.0, through: 1.0, by: 0.1).map {
            PlayerMotionSample(time: $0, box: .init(x: 0.475 + $0 * 0.1, y: 0.3, width: 0.05, height: 0.2))
        }
        XCTAssertEqual(calibration.speed(of: PlayerMotion(samples: samples, smoothing: 0), at: 0.5) ?? -1,
                       0, accuracy: 0.001,
                       "A camera pan must not become player ground speed")
    }

    @MainActor
    func testGroundPlayerFootprintDiffersFromLegacyEllipseAndKeepsFootCenter() throws {
        let size = CGSize(width: 640, height: 360), frame = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func render(_ ground: GroundCalibration?) -> UIImage {
            UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                UIColor.black.setFill(); renderer.fill(frame)
                var mark = AnalysisAnnotation(tool: .player,
                                              points: [.init(x: 0.45, y: 0.35), .init(x: 0.55, y: 0.75)],
                                              start: 0, end: 2)
                mark.color = .init(red: 0.1, green: 0.9, blue: 1)
                AnnotationRenderer.draw([mark], time: 1, in: renderer.cgContext, frame: frame, ground: ground)
            }
        }
        let ground = planeCalibration()
        let projected = render(ground), legacy = render(nil)
        XCTAssertNotEqual(projected.pngData(), legacy.pngData())

        let feet = CGPoint(x: 0.5, y: 0.75)
        let ring = try XCTUnwrap(ground.circle(center: feet, radiusMeters: 0.6, at: 1))
        XCTAssertEqual(ring.count, 32)
        let worldFeet = try XCTUnwrap(ground.worldPoint(feet, at: 1))
        let projectedFeet = try XCTUnwrap(ground.imagePoint(worldFeet, at: 1))
        XCTAssertEqual(projectedFeet.x, feet.x, accuracy: 0.0001,
                       "The footprint is anchored at the player's ground feet")
        XCTAssertEqual(projectedFeet.y, feet.y, accuracy: 0.0001,
                       "The footprint is anchored at the player's ground feet")
        for (name, image) in [("Ground-plane footprint", projected), ("Legacy ellipse", legacy)] {
            let attachment = XCTAttachment(image: image); attachment.name = name
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    /// Phone-only integration coverage. The reference is deliberately synthetic
    /// (a known image-plane scale), so this verifies render/preview/export wiring,
    /// not a real-field metric claim.
    @MainActor
    func testStressFootagePreviewAndExportCarryMeasurements() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Run on the fixture phone")
        #else
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Stress-test recording unavailable")
        let recording = Recording(projectID: UUID(), localPath: url.lastPathComponent, duration: 33)

        // Seeded source-time motion: the source t=3 seed is approximately
        // (0.394, 0.586), while known source-frame feet at t=5 are
        // approximately (1040/1920, 736/1080). No Vision retracking or persistence.
        let samples = stride(from: 3.0, through: 9.0, by: 0.1).map {
            PlayerMotionSample(time: $0,
                               box: .init(x: 0.369 + ($0 - 3) * 0.0738333, y: 0.48148,
                                          width: 0.05, height: 0.20))
        }
        let motion = PlayerMotion(samples: samples, smoothing: 0)
        let boundMotion = try XCTUnwrap(motion.bound(at: 3))
        let calibration = GroundCalibration(mode: .plane,
                                            points: [.init(x: 0.1, y: 0.1), .init(x: 0.9, y: 0.1),
                                                     .init(x: 0.85, y: 0.9), .init(x: 0.15, y: 0.9)],
                                            lengthMeters: 80, widthMeters: 40, referenceTime: 5,
                                            imageAspectRatio: 1, fixedCamera: true)
        // Synthetic plane dimensions exercise the ground footprint path; they
        // are not a metric claim about this stress recording.

        var label = AnalysisAnnotation(tool: .text, points: [.init(x: 0.394, y: 0.54)],
                                       text: "SYNTHETIC FEET", start: 3, end: 9.1)
        label.showsSpeed = true; label.playerMotion = boundMotion
        label.textStyle = .init(alignment: .center, size: 0.024, weight: .bold, background: true)
        var line = AnalysisAnnotation(tool: .line,
                                      points: [.init(x: 0.492, y: 0.68148), .init(x: 0.592, y: 0.68148)],
                                      start: 3, end: 9.1)
        line.showsDistance = true
        var ring = AnalysisAnnotation(tool: .player,
                                      points: [.init(x: 0.369, y: 0.48148), .init(x: 0.419, y: 0.68148)],
                                      start: 3, end: 9.1)
        ring.playerMotion = boundMotion
        ring.effect = .clean

        var clip = CompositionClip(recordingID: recording.id, startSeconds: 3, endSeconds: 9.1)
        clip.annotations = [ring, label, line]
        clip.groundCalibration = calibration
        XCTAssertTrue(AnnotationMeasurements.text(for: label, at: 5, ground: calibration).contains("km/h"))
        XCTAssertTrue(AnnotationMeasurements.distances(for: line, at: 5, ground: calibration).first?.text.hasSuffix(" m") == true)
        // Exercise the same Codable boundary used by the editor before preview/export.
        clip = try JSONDecoder().decode(CompositionClip.self, from: JSONEncoder().encode(clip))
        let asset = try await CompositionRenderer.makeAsset(clips: [clip], recordings: [recording])
        let video = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: [clip], recordings: [recording], aspectRatio: "original")
        let exported = try await CompositionRenderer.export(asset: asset, id: UUID(), videoComposition: video) { _ in }
        defer { try? FileManager.default.removeItem(at: exported) }

        let preview = AVAssetImageGenerator(asset: asset); preview.videoComposition = video
        let encoded = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        let sourceGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        sourceGenerator.appliesPreferredTrackTransform = true
        sourceGenerator.requestedTimeToleranceBefore = .zero; sourceGenerator.requestedTimeToleranceAfter = .zero
        let source = try await sourceGenerator.image(at: CMTime(seconds: 5, preferredTimescale: 600)).image
        let direct = UIGraphicsImageRenderer(size: CGSize(width: source.width, height: source.height)).image { renderer in
            UIImage(cgImage: source).draw(in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            AnnotationRenderer.draw(clip.annotations, time: 5, in: renderer.cgContext,
                                    frame: CGRect(x: 0, y: 0, width: source.width, height: source.height),
                                    ground: clip.groundCalibration)
        }
        let directAttachment = XCTAttachment(image: direct); directAttachment.name = "Stress direct renderer measurements"
        directAttachment.lifetime = .keepAlways; add(directAttachment)
        for (name, generator) in [("Stress preview measurements", preview), ("Stress encoded measurements", encoded)] {
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: 2, preferredTimescale: 600)).image
            XCTAssertGreaterThan(image.width, 0)
            let attachment = XCTAttachment(image: UIImage(cgImage: image)); attachment.name = name
            attachment.lifetime = .keepAlways; add(attachment)
        }
        #endif
    }
}
