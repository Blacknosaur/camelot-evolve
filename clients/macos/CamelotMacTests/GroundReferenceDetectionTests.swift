@preconcurrency import AVFoundation
import CoreGraphics
import XCTest
@testable import Camelot

final class GroundReferenceDetectionTests: XCTestCase {
    func testActualStressFrameReturnsOnlySupportedReferenceHints() async throws {
        let url = URL.documentsDirectory.appending(path: "Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path()), "Run on the fixture phone")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let source = try await generator.image(at: CMTime(seconds: 5, preferredTimescale: 600)).image
        let result = try GroundReferenceDetection.detect(in: source)
        print("GROUND_REFERENCE t=5 corners=\(result.corners.count) intersections=\(result.intersections.count)")
        XCTAssertTrue(result.corners.isEmpty || result.corners.count == 4)
        XCTAssertTrue(result.intersections.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        // No complete rectangle is guaranteed in a partial-field shot. Never
        // invent dimensions or a full pitch from an unsupported suggestion.
        if result.corners.count == 4 {
            XCTAssertNotNil(AnalysisFieldGuide.projection(corners: result.corners))
        }
    }

    func testCleanRectangleProducesClockwiseCornersAndIntersections() {
        let result = GroundReferenceDetection.propose(from: segments([
            (CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2)),
            (CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.8, y: 0.8)),
            (CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.2, y: 0.8)),
            (CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.2, y: 0.2))
        ]))
        XCTAssertEqual(result.corners.count, 4)
        XCTAssertEqual(result.intersections.count, 4)
        XCTAssertGreaterThan(signedArea(result.corners), 0) // clockwise in image coordinates
    }

    func testProjectiveQuadrilateralProducesCorners() {
        let result = GroundReferenceDetection.propose(from: segments([
            (CGPoint(x: 0.18, y: 0.22), CGPoint(x: 0.76, y: 0.12)),
            (CGPoint(x: 0.76, y: 0.12), CGPoint(x: 0.88, y: 0.76)),
            (CGPoint(x: 0.88, y: 0.76), CGPoint(x: 0.28, y: 0.88)),
            (CGPoint(x: 0.28, y: 0.88), CGPoint(x: 0.18, y: 0.22))
        ]))
        XCTAssertEqual(result.corners.count, 4)
    }

    func testPartialBoundariesKeepIntersectionsButDoNotProposeCorners() {
        let result = GroundReferenceDetection.propose(from: segments([
            (CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2)),
            (CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.8, y: 0.8)),
            (CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.2, y: 0.8))
        ]))
        XCTAssertTrue(result.corners.isEmpty)
        XCTAssertEqual(result.intersections.count, 2)
    }

    func testNearParallelLinesAreRejected() {
        let result = GroundReferenceDetection.propose(from: segments([
            (CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.2)),
            (CGPoint(x: 0.1, y: 0.21), CGPoint(x: 0.9, y: 0.21)),
            (CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.9, y: 0.81)),
            (CGPoint(x: 0.1, y: 0.81), CGPoint(x: 0.9, y: 0.82))
        ]))
        XCTAssertTrue(result.corners.isEmpty)
        XCTAssertTrue(result.intersections.isEmpty)
    }

    func testDuplicatesAndAmbiguousGeometryDoNotCrashOrInventCorners() {
        let duplicate = FieldLineDetection.Segment(id: 9, start: CGPoint(x: 0.2, y: 0.2), end: CGPoint(x: 0.8, y: 0.2))
        let result = GroundReferenceDetection.propose(from: [duplicate, duplicate])
        XCTAssertTrue(result.corners.isEmpty)
        XCTAssertTrue(result.intersections.isEmpty)
    }

    private func segments(_ values: [(CGPoint, CGPoint)]) -> [FieldLineDetection.Segment] {
        values.enumerated().map { FieldLineDetection.Segment(id: $0.offset, start: $0.element.0, end: $0.element.1) }
    }

    private func signedArea(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst() + points.prefix(1)).reduce(0) {
            $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y)
        } / 2
    }
}
