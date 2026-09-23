import XCTest
@testable import Camelot

final class GroundShapeGeometryTests: XCTestCase {
    private var ground: GroundCalibration {
        GroundCalibration(mode: .plane, points: [.init(x: 0.3, y: 0.25), .init(x: 0.65, y: 0.32),
            .init(x: 0.95, y: 0.90), .init(x: 0.05, y: 0.8)], lengthMeters: 40, widthMeters: 60,
            referenceTime: 0, imageAspectRatio: 16 / 9, fixedCamera: true)
    }

    private func shape(_ tool: AnalysisDrawingTool) throws -> AnalysisAnnotation {
        let points = try [CGPoint(x: 8, y: 10), .init(x: 28, y: 40)].map { try XCTUnwrap(ground.imagePoint($0, at: 0)) }
        var mark = AnalysisAnnotation(tool: tool, points: points, start: 0, end: 4)
        mark.grounded = true
        return mark
    }

    func testEveryRectangleCornerAndEllipseSampleLiesOnTheMetricPlane() throws {
        let rectangle = try shape(.rectangle)
        let corners = rectangle.shapeBoundary(at: 0, ground: ground)
        XCTAssertEqual(corners.count, 4)
        let expected = [CGPoint(x: 8, y: 10), .init(x: 28, y: 10), .init(x: 28, y: 40), .init(x: 8, y: 40)]
        for (point, world) in zip(corners, expected) {
            let actual = try XCTUnwrap(ground.worldPoint(point, at: 0))
            XCTAssertEqual(actual.x, world.x, accuracy: 0.001)
            XCTAssertEqual(actual.y, world.y, accuracy: 0.001)
        }
        XCTAssertGreaterThan(abs(corners[1].y - corners[0].y), 0.01, "Must not rebuild a screen-aligned rectangle")
        XCTAssertEqual(rectangle.editHandles(at: 0, ground: ground), corners)
        let ellipse = try shape(.ellipse).shapeBoundary(at: 0, ground: ground)
        XCTAssertEqual(ellipse.count, 96)
        for point in ellipse {
            let world = try XCTUnwrap(ground.worldPoint(point, at: 0))
            let x = (world.x - 18) / 10, y = (world.y - 25) / 15
            XCTAssertEqual(x * x + y * y, 1, accuracy: 0.001)
        }
    }

    func testAllFourResizeHandlesFollowTheFingerAndKeepOppositeCorner() throws {
        for tool: AnalysisDrawingTool in [.rectangle, .ellipse] {
            let mark = try shape(tool)
            let corners = mark.editHandles(at: 0, ground: ground)
            for handle in 0..<4 {
                var changed = mark
                changed.moveDrawing(to: mark.reshaped(at: 0, handle: handle, delta: .init(width: 0.025, height: 0.035), ground: ground), at: 0)
                let updated = changed.editHandles(at: 0, ground: ground)
                XCTAssertEqual(updated[handle].x, corners[handle].x + 0.025, accuracy: 0.0001)
                XCTAssertEqual(updated[handle].y, corners[handle].y + 0.035, accuracy: 0.0001)
                let opposite = (handle + 2) % 4
                XCTAssertEqual(updated[opposite].x, corners[opposite].x, accuracy: 0.0001)
                XCTAssertEqual(updated[opposite].y, corners[opposite].y, accuracy: 0.0001)
            }
        }
    }

    func testMovingShapesPreservesMetricSizeAndTrackingSurvivesEditingAndCoding() throws {
        var plane = ground; plane.fixedCamera = false
        let warp = CameraTransform(values: [1.1, -0.06, 0.03, 0.08, 0.9, 0.02, 0.07, -0.04, 1])
        plane.cameraMotion = .init(samples: [.init(time: 0, transform: .identity), .init(time: 2, transform: warp)])
        for tool: AnalysisDrawingTool in [.rectangle, .ellipse, .zone, .line, .arrow, .pen] {
            var mark = try shape(tool)
            if tool == .zone || tool == .pen { mark.points.append(.init(x: 0.4, y: 0.7)) }
            mark.setGrounding(true, at: 0, ground: plane)
            let before = mark.shapeBoundary(at: 0, ground: plane)
            let after = mark.shapeBoundary(at: 2, ground: plane)
            XCTAssertEqual(before.count, after.count)
            for (a, b) in zip(before, after) {
                let expected = try XCTUnwrap(warp.point(a))
                XCTAssertEqual(b.x, expected.x, accuracy: 0.0001)
                XCTAssertEqual(b.y, expected.y, accuracy: 0.0001)
            }
            let pose = mark.points(at: 2)
            let originalDistance = try XCTUnwrap(plane.distance(from: pose[0], to: pose[1], at: 2))
            let moved = mark.reshaped(at: 2, handle: nil, delta: .init(width: 0.04, height: 0.04), ground: plane)
            XCTAssertEqual(try XCTUnwrap(plane.distance(from: moved[0], to: moved[1], at: 2)), originalDistance, accuracy: 0.002)
            let track = mark.cameraMotion
            mark.moveDrawing(to: moved, at: 2)
            XCTAssertEqual(mark.cameraMotion, track)
            XCTAssertEqual(try JSONDecoder().decode(AnalysisAnnotation.self, from: JSONEncoder().encode(mark)), mark)
            XCTAssertTrue(mark.shapeBoundary(at: 3, ground: plane).isEmpty, "No stale geometry beyond camera coverage")
        }
    }

    func testGroundingPreservesKeysAndLegacyUngroundedGeometry() throws {
        var mark = try shape(.rectangle)
        mark.grounded = false
        XCTAssertEqual(mark.shapeBoundary(at: 0, ground: ground), mark.points)
        mark.setKeyframe(at: 0, points: mark.points)
        mark.setKeyframe(at: 2, points: mark.points.map { .init(x: $0.x + 0.05, y: $0.y) })
        let keys = mark.keyframes
        mark.setGrounding(true, at: 1, ground: ground)
        XCTAssertEqual(mark.keyframes, keys)
        XCTAssertEqual(mark.shapeBoundary(at: 1, ground: ground).count, 4)
        XCTAssertEqual(try shape(.ellipse).shapeBoundary(at: 0, ground: nil), [])
    }
}
