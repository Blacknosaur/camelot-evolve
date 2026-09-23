import XCTest
@preconcurrency import AVFoundation
import UIKit
@testable import Camelot

final class FieldFrameSelectionTests: XCTestCase {
    func testCircleAndActualCenterRecoverSharpPerspectiveWithoutFourManualCorners() throws {
        let h = CameraTransform(values: [0.25,0.7,0.08, 0.8,-0.05,0.12, 0.7,0.25,1])
        let outline = try (0..<180).map { index in
            let angle = Double(index)*2*Double.pi/180
            return try XCTUnwrap(h.point(.init(x: 0.5+0.5*cos(angle), y: 0.5+0.5*sin(angle))))
        }
        let halfway = try [CGPoint(x: 0,y: 0.5),.init(x: 1,y: 0.5)].map { try XCTUnwrap(h.point($0)) }
        var reference = try XCTUnwrap(GroundCircleReference.fit(outline: outline, halfway: halfway, imageSize: .init(width: 1920,height: 1080)))
        let realCenter = try XCTUnwrap(h.point(.init(x: 0.5,y: 0.5)))
        XCTAssertGreaterThan(hypot(reference.center.x-realCenter.x,reference.center.y-realCenter.y),0.01,
                             "The ellipse centre is not the actual centre spot")
        reference.center = realCenter
        let anchors = try XCTUnwrap(reference.anchors)
        let corners = GroundFieldOverlay.calibrationCorners(anchors: anchors, landmark: .centreCircle)
        for (actual, point) in zip(corners,GroundFieldOverlay.rectangle) {
            let expected = try XCTUnwrap(h.point(point))
            XCTAssertEqual(actual.x,expected.x,accuracy: 0.0001)
            XCTAssertEqual(actual.y,expected.y,accuracy: 0.0001)
        }
        let pan = CameraTransform(values: [1,0.08,-0.12, 0,1,0.03, 0.1,0,1])
        let moved = try XCTUnwrap(reference.transformed(by: pan))
        for (actual, original) in zip(try XCTUnwrap(moved.anchors),anchors) {
            let expected = try XCTUnwrap(pan.point(original))
            XCTAssertEqual(actual.x,expected.x,accuracy: 0.0001)
            XCTAssertEqual(actual.y,expected.y,accuracy: 0.0001)
        }
        XCTAssertEqual(reference,try JSONDecoder().decode(GroundCircleReference.self,from: JSONEncoder().encode(reference)))
        reference.center = .init(x: -1,y: -1)
        XCTAssertNil(reference.anchors)
    }

    func testFarTouchlineRecoversCenterAndPerspectiveWithoutVisibleSpot() throws {
        let h = CameraTransform(values: [0.25,0.7,0.08, 0.8,-0.05,0.12, 0.7,0.25,1])
        let outline = try (0..<180).map { index in
            let angle = Double(index)*2*Double.pi/180
            return try XCTUnwrap(h.point(.init(x: 0.5+0.5*cos(angle), y: 0.5+0.5*sin(angle))))
        }
        let halfway = try [CGPoint(x: 0,y: 0.5),.init(x: 1,y: 0.5)].map { try XCTUnwrap(h.point($0)) }
        var reference = try XCTUnwrap(GroundCircleReference.fit(outline: outline,halfway: halfway,imageSize: .init(width: 1920,height: 1080)))
        let far = 0.5-68/(2*18.3)
        reference.farTouchline = try [CGPoint(x: far,y: 0.2),.init(x: far,y: 0.8)].map { try XCTUnwrap(h.point($0)) }
        reference.center = try XCTUnwrap(reference.centerFromTouchline(pitchWidth: 68,diameter: 18.3))
        let expected = try XCTUnwrap(h.point(.init(x: 0.5,y: 0.5)))
        XCTAssertEqual(reference.center.x,expected.x,accuracy: 0.0001)
        XCTAssertEqual(reference.center.y,expected.y,accuracy: 0.0001)
        let corners = GroundFieldOverlay.calibrationCorners(anchors: try XCTUnwrap(reference.anchors),landmark: .centreCircle)
        for (actual, point) in zip(corners,GroundFieldOverlay.rectangle) {
            let projected = try XCTUnwrap(h.point(point))
            XCTAssertEqual(actual.x,projected.x,accuracy: 0.0001)
            XCTAssertEqual(actual.y,projected.y,accuracy: 0.0001)
        }
        let pan = CameraTransform(values: [1,0.08,-0.12, 0,1,0.03, 0.1,0,1])
        let moved = try XCTUnwrap(reference.transformed(by: pan))
        let recovered = try XCTUnwrap(moved.centerFromTouchline(pitchWidth: 68,diameter: 18.3))
        XCTAssertEqual(recovered.x,moved.center.x,accuracy: 0.0001)
        XCTAssertEqual(recovered.y,moved.center.y,accuracy: 0.0001)
        XCTAssertEqual(reference,try JSONDecoder().decode(GroundCircleReference.self,from: JSONEncoder().encode(reference)))
        XCTAssertNil(reference.centerFromTouchline(pitchWidth: 0,diameter: 18.3))
        reference.farTouchline = halfway
        XCTAssertNil(reference.centerFromTouchline(pitchWidth: 68,diameter: 18.3))
        reference.farTouchline = try [CGPoint(x: 0.5,y: 0.2),.init(x: 0.5,y: 0.8)].map { try XCTUnwrap(h.point($0)) }
        XCTAssertNil(reference.centerFromTouchline(pitchWidth: 68,diameter: 18.3))
    }

    func testCircleFitRejectsShortOrCollinearEvidence() {
        XCTAssertNil(GroundCircleReference.fit(outline: Array(repeating: .zero,count: 60),halfway: [.zero,.init(x: 1,y: 1)],imageSize: .init(width: 1920,height: 1080)))
        XCTAssertNil(GroundCircleReference.fit(outline: [.zero,.init(x: 1,y: 1)],halfway: [.zero,.init(x: 1,y: 1)],imageSize: .init(width: 1920,height: 1080)))
    }

    func testVisibleLineSegmentsFitWithoutTheirIntersectionsOnscreen() throws {
        func project(_ x: Double, _ y: Double) -> CGPoint {
            let d = 1 + 0.4 * x + 0.2 * y
            return .init(x: (0.1 + 0.3 * x + 0.7 * y) / d, y: (0.15 + 0.8 * x - 0.1 * y) / d)
        }
        let kinds: [GroundPitchLine] = [.leftGoal, .leftBoxFront, .leftBoxFar, .leftBoxNear]
        let lines = kinds.map { kind -> GroundLineObservation in
            let k = kind.coordinate(length: 105, width: 68)
            return .init(kind: kind, points: kind.across ? [project(0.3, k), project(0.7, k)] : [project(k, 0.03), project(k, 0.14)])
        }
        let fit = try XCTUnwrap(GroundLineAlignment.fit(lines, length: 105, width: 68, time: 3, aspect: 16/9, fixed: true))
        for (actual, reference) in zip(fit.calibration.points, GroundFieldOverlay.rectangle) {
            let expected = project(reference.x, reference.y)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.0001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.0001)
        }
        XCTAssertEqual(fit.calibration.lineReferences, lines)
        XCTAssertEqual(try JSONDecoder().decode(GroundCalibration.self, from: JSONEncoder().encode(fit.calibration)), fit.calibration)
        XCTAssertNil(GroundLineAlignment.fit(Array(lines.prefix(3)), length: 105, width: 68, time: 3, aspect: 16/9, fixed: true))
        XCTAssertNil(GroundLineAlignment.fit(lines + [lines[0]], length: 105, width: 68, time: 3, aspect: 16/9, fixed: true))
    }

    @MainActor
    func testOnDevicePitchProposalOnActualStressFootage() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Fixture phone only")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: CMTime(seconds: 10, preferredTimescale: 600)).image
        let start = Date()
        let proposals = try await Task.detached { try PitchRegionDetection.detect(in: frame) }.value
        let elapsed = Date().timeIntervalSince(start)
        let circle = try XCTUnwrap(proposals.first { $0.landmark == .centreCircle })
        let reference = try XCTUnwrap(circle.circle)
        XCTAssertLessThan(reference.outlineErrorPixels,4)
        let half = reference.halfway
        let crossingX = half[0].x + (0.55-half[0].y)*(half[1].x-half[0].x)/(half[1].y-half[0].y)
        XCTAssertEqual(crossingX,0.5005,accuracy: 0.005,"Refined halfway line must follow the actual white marking, not pass through the ellipse centroid")
        print("REFINED_CIRCLE residual75px=\(reference.outlineErrorPixels) sensitivity=\(String(describing: reference.pixelSensitivity(imageSize: .init(width: frame.width,height: frame.height))))")
        XCTAssertEqual(circle.corners.count, 4)
        XCTAssertLessThan(elapsed, 15, "Single-frame proposal must stay interactive")
        let size = CGSize(width: frame.width, height: frame.height)
        let preview = UIGraphicsImageRenderer(size: size).image { renderer in
            UIImage(cgImage: frame).draw(in: CGRect(origin: .zero, size: size))
            let context = renderer.cgContext
            context.setStrokeColor(UIColor.cyan.cgColor); context.setLineWidth(5)
            context.addLines(between: circle.corners.map { .init(x: $0.x * size.width, y: $0.y * size.height) }); context.closePath(); context.strokePath()
        }
        let image = XCTAttachment(image: preview); image.name = "Reviewable centre circle proposal on phone (\(elapsed)s)"; image.lifetime = .keepAlways; add(image)
        // Two manually observed points on this fixture's far touchline. The
        // venue width is assumed here: this checks visual fit, not metric truth.
        var touchlineReference = reference
        touchlineReference.farTouchline = [.init(x: 0.15,y: 0.455),.init(x: 0.85,y: 0.422)]
        touchlineReference.center = try XCTUnwrap(touchlineReference.centerFromTouchline(pitchWidth: 68,diameter: 18.3))
        let corners = GroundFieldOverlay.calibrationCorners(anchors: try XCTUnwrap(touchlineReference.anchors),landmark: .centreCircle)
        var calibration = GroundCalibration(mode: .plane,points: corners,lengthMeters: 18.3,widthMeters: 18.3,
                                            referenceTime: 10,imageAspectRatio: 16.0/9,fixedCamera: true)
        calibration.fieldReference = .init(landmark: .centreCircle,pitchLength: 105,pitchWidth: 68)
        let overlay = UIGraphicsImageRenderer(size: size).image { renderer in
            UIImage(cgImage: frame).draw(in: CGRect(origin: .zero,size: size))
            let context = renderer.cgContext
            context.addPath(GroundFieldOverlay.path(calibration: calibration,frame: CGRect(origin: .zero,size: size)))
            context.setStrokeColor(UIColor.cyan.cgColor); context.setLineWidth(2); context.strokePath()
        }
        let field = XCTAttachment(image: overlay); field.name = "Full field from circle and far touchline; assumed 68m width"; field.lifetime = .keepAlways; add(field)
        // Every proposal is now snapped to the painted markings. Report the
        // best one and attach it so the fit can be inspected on real footage.
        let best = try XCTUnwrap(proposals.first)
        print("SNAPPED_PROPOSALS " + proposals.map { "\($0.landmark.rawValue)=\($0.registration.map { $0.quality.summary + " coverage=" + String(format: "%.2f", $0.quality.coverage) } ?? "unsnapped")" }.joined(separator: " | "))
        if let registration = best.registration {
            XCTAssertTrue(registration.calibration.valid)
            let snapped = UIGraphicsImageRenderer(size: size).image { renderer in
                UIImage(cgImage: frame).draw(in: CGRect(origin: .zero,size: size))
                let context = renderer.cgContext
                context.addPath(GroundFieldOverlay.path(calibration: registration.calibration,frame: CGRect(origin: .zero,size: size)))
                context.setStrokeColor(UIColor.cyan.cgColor); context.setLineWidth(2); context.strokePath()
            }
            let attachment = XCTAttachment(image: snapped); attachment.name = "Best proposal snapped to markings (\(registration.quality.summary))"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    @MainActor
    func testFindClearerReferenceFrameOnStressFootage() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Fixture phone only")
        let result = try await Task.detached { try await PitchRegionDetection.findReference(url: url,range: 0...32.9,preferred: 2) }.value
        let reference = try XCTUnwrap(result)
        XCTAssertTrue(reference.proposal.circle != nil || reference.proposal.registration != nil)
        print("CLEAR_FIELD_FRAME time=\(reference.time) score=\(reference.score) quality=\(reference.proposal.registration?.quality.summary ?? "unsnapped")")
    }

    func testChangingReferenceFrameReprojectsDraftUsingSharedCamera() throws {
        let camera = AnnotationCameraMotion(samples: [.init(time: 0, transform: .identity),
            .init(time: 10, transform: .init(values: [1, 0, 0.1, 0, 1, -0.05, 0, 0, 1]))], trackID: UUID())
        let request = GroundCalibrationRequest(sourceTime: 0, annotationTime: 0, sourceRange: 0...10, cameraMotion: camera)
        let original = GroundCalibration(mode: .plane,
            points: [.init(x: 0.2, y: 0.3), .init(x: 0.8, y: 0.3), .init(x: 0.9, y: 0.9), .init(x: 0.1, y: 0.9)],
            lengthMeters: 68, widthMeters: 105, referenceTime: 0, imageAspectRatio: 16.0 / 9)
        let moved = try XCTUnwrap(request.relocating(original, to: 10))
        XCTAssertEqual(moved.referenceTime, 10)
        XCTAssertEqual(moved.cameraMotion?.trackID, camera.trackID)
        XCTAssertFalse(moved.fixedCamera)
        for (before, after) in zip(original.points, moved.points) {
            XCTAssertEqual(after.x, before.x + 0.1, accuracy: 0.00001)
            XCTAssertEqual(after.y, before.y - 0.05, accuracy: 0.00001)
        }
        let back = try XCTUnwrap(request.relocating(moved, to: 0))
        for (before, after) in zip(original.points, back.points) {
            XCTAssertEqual(after.x, before.x, accuracy: 0.00001)
            XCTAssertEqual(after.y, before.y, accuracy: 0.00001)
        }
    }

    func testMissingCameraNeverInventsAlignmentAtAnotherTime() {
        let request = GroundCalibrationRequest(sourceTime: 0, annotationTime: 0)
        let draft = GroundCalibration(mode: .localScale, points: [.zero, .init(x: 1, y: 0)], lengthMeters: 10, referenceTime: 0, imageAspectRatio: 1)
        XCTAssertNil(request.relocating(draft, to: 5))
        XCTAssertEqual(request.referenceTime(at: 5), 5)
    }

    func testStillKeepsAnnotationTimeSeparateFromSourceFrame() {
        let request = GroundCalibrationRequest(sourceTime: 5, annotationTime: 8, isStill: true)
        XCTAssertEqual(request.referenceTime(at: 5), 8)
    }
}
