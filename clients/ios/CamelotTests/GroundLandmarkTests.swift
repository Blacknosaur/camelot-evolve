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

    func testCircleAndGoalWidthAreTwoPointApproximateReferences() {
        XCTAssertEqual(GroundLandmark.centreCircle.mode, .localScale)
        XCTAssertEqual(GroundLandmark.centreCircle.pointCount, 2)
        XCTAssertTrue(GroundLandmark.centreCircle.isApproximate)
        XCTAssertTrue(GroundLandmark.centreCircle.guidance.localizedCaseInsensitiveContains("no ground-plane homography"))
        XCTAssertEqual(GroundLandmark.goalWidth.pointCount, 2)
        XCTAssertTrue(GroundLandmark.goalWidth.guidance.localizedCaseInsensitiveContains("vertical goal face"))
    }
}
