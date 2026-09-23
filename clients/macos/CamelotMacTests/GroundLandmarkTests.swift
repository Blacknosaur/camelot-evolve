import XCTest
@testable import Camelot

final class GroundLandmarkTests: XCTestCase {
    func testFullSizeFootballPresetsUseIFABDimensions() {
        XCTAssertEqual(GroundLandmark.penaltyArea.defaultLengthMeters, 40.32, accuracy: 0.0001)
        XCTAssertEqual(GroundLandmark.penaltyArea.defaultWidthMeters, 16.5, accuracy: 0.0001)
        XCTAssertEqual(GroundLandmark.goalArea.defaultLengthMeters, 18.32, accuracy: 0.0001)
        XCTAssertEqual(GroundLandmark.goalArea.defaultWidthMeters, 5.5, accuracy: 0.0001)
        XCTAssertEqual(GroundLandmark.centreCircle.defaultLengthMeters, 18.3, accuracy: 0.0001)
        XCTAssertEqual(GroundLandmark.goalWidth.defaultLengthMeters, 7.32, accuracy: 0.0001)
    }

    func testRectanglesUseFourPointsAndPlaneMode() {
        XCTAssertEqual(GroundLandmark.penaltyArea.mode, .plane)
        XCTAssertEqual(GroundLandmark.penaltyArea.pointCount, 4)
        XCTAssertEqual(GroundLandmark.goalArea.pointCount, 4)
    }

    func testCircleUsesFourPlaneAnchorsWhileGoalWidthStaysApproximate() {
        XCTAssertEqual(GroundLandmark.centreCircle.mode, .plane)
        XCTAssertEqual(GroundLandmark.centreCircle.pointCount, 4)
        XCTAssertFalse(GroundLandmark.centreCircle.isApproximate)
        XCTAssertEqual(GroundLandmark.goalWidth.pointCount, 2)
        XCTAssertTrue(GroundLandmark.goalWidth.guidance.localizedCaseInsensitiveContains("vertical goal face"))
    }

    func testEveryFieldTemplateProjectsAndReopensWithoutChangingItsAnchors() throws {
        for landmark in GroundLandmark.allCases where landmark.mode == .plane {
            for right in [true, false] {
                let anchors = GroundFieldOverlay.seed(landmark, goalOnRight: right)
                let corners = GroundFieldOverlay.calibrationCorners(anchors: anchors, landmark: landmark)
                var model = GroundCalibration(mode: .plane, points: corners,
                    lengthMeters: landmark.defaultLengthMeters, widthMeters: landmark.defaultWidthMeters,
                    referenceTime: 2, imageAspectRatio: 16 / 9, fixedCamera: true)
                model.fieldReference = .init(landmark: landmark)
                XCTAssertTrue(model.valid, landmark.title)
                let decoded = try JSONDecoder().decode(GroundCalibration.self, from: JSONEncoder().encode(model))
                XCTAssertEqual(decoded, model)
                let reopened = GroundFieldOverlay.editingAnchors(decoded, landmark: landmark)
                XCTAssertEqual(reopened.count, 4)
                for (a, b) in zip(anchors, reopened) {
                    XCTAssertEqual(a.x, b.x, accuracy: 0.0001)
                    XCTAssertEqual(a.y, b.y, accuracy: 0.0001)
                }
                XCTAssertEqual(model.frozen(at: 4)?.fieldReference, model.fieldReference)
                let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
                let path = GroundFieldOverlay.path(calibration: model, frame: frame)
                XCTAssertFalse(path.isEmpty)
                model.points[2].x += 0.04
                XCTAssertNotEqual(path, GroundFieldOverlay.path(calibration: model, frame: frame))
            }
        }
    }

    func testFieldOverlayContainsRelatedMarkingsAndRejectsInvalidAlignment() {
        let lines = GroundFieldOverlay.worldLines(reference: .init(landmark: .penaltyArea), length: 40.32, depth: 16.5)
        XCTAssertTrue(lines.contains { $0.contains(CGPoint(x: 0, y: 0)) && $0.contains(CGPoint(x: 40.32, y: 16.5)) })
        XCTAssertGreaterThan(lines.count, 10, "The preview includes related pitch markings, not just its reference polygon")
        let model = GroundCalibration(mode: .plane,
            points: [.zero, .init(x: 1, y: 1), .init(x: 1, y: 0), .init(x: 0, y: 1)],
            lengthMeters: 40.32, widthMeters: 16.5, referenceTime: 0, imageAspectRatio: 1)
        XCTAssertFalse(model.valid)
        XCTAssertTrue(GroundFieldOverlay.path(calibration: model, frame: .init(x: 0, y: 0, width: 100, height: 100)).isEmpty)
    }
}
