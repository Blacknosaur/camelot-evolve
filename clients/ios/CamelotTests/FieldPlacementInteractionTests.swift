import XCTest
@testable import Camelot

final class FieldPlacementInteractionTests: XCTestCase {
    func testInspectionPanAndPinchRemainAnchoredOutsideAuthoredZoom() {
        let fitted = CGRect(x: 0, y: 90, width: 390, height: 220)
        var mark = AnalysisAnnotation(tool: .zoom, points: [.init(x: 0.8, y: 0.6)], start: 0, end: 8)
        mark.zoomScale = 3
        let authored = AnnotationViewport.transform(marks: [mark], time: 2, frame: fitted, bounds: fitted)
        let initial = FieldPlacementViewport(zoom: 2, center: .init(x: 0.45, y: 0.55))
        let from = CGPoint(x: 150, y: 180), to = CGPoint(x: 200, y: 195)
        let next = initial.navigating(scale: 1.4, from: from, to: to, fitted: fitted)
        let a = fitted.applying(authored).applying(AnnotationViewport.inspectionTransform(fitted: fitted, zoom: initial.zoom, center: initial.center))
        let b = fitted.applying(authored).applying(AnnotationViewport.inspectionTransform(fitted: fitted, zoom: next.zoom, center: next.center))
        let source = AnnotationViewport.sourcePoint(from, frame: a, allowsOffscreen: true)
        XCTAssertEqual(b.minX + source.x * b.width, to.x, accuracy: 0.001)
        XCTAssertEqual(b.minY + source.y * b.height, to.y, accuracy: 0.001)
    }

    func testPinchAndPanKeepSourcePointUnderMovingFingers() {
        let fitted = CGRect(x: 0, y: 80, width: 390, height: 219.375)
        let start = FieldPlacementViewport(zoom: 2, center: .init(x: 0.3, y: 0.6))
        let finger = CGPoint(x: 120, y: 170), moved = CGPoint(x: 160, y: 200)
        let source = AnnotationViewport.sourcePoint(finger, frame: start.frame(fitted: fitted), allowsOffscreen: true)
        let next = start.navigating(scale: 1.8, from: finger, to: moved, fitted: fitted)
        let after = AnnotationViewport.sourcePoint(moved, frame: next.frame(fitted: fitted), allowsOffscreen: true)
        XCTAssertEqual(next.zoom, 3.6, accuracy: 0.0001)
        XCTAssertEqual(after.x, source.x, accuracy: 0.0001); XCTAssertEqual(after.y, source.y, accuracy: 0.0001)
        let panned = start.navigating(scale: 1, from: finger, to: moved, fitted: fitted)
        XCTAssertEqual(panned.frame(fitted: fitted).minX - start.frame(fitted: fitted).minX, 40, accuracy: 0.0001)
        XCTAssertEqual(panned.frame(fitted: fitted).minY - start.frame(fitted: fitted).minY, 30, accuracy: 0.0001)
    }

    func testZoomLimitsFitAndOffscreenCoordinates() {
        let fitted = CGRect(x: 0, y: 50, width: 400, height: 225), center = CGPoint(x: 200, y: 162.5)
        let start = FieldPlacementViewport()
        XCTAssertEqual(start.navigating(scale: 100, from: center, to: center, fitted: fitted).zoom, 8)
        let out = start.navigating(scale: 0.01, from: center, to: center, fitted: fitted)
        XCTAssertEqual(out.zoom, 0.25)
        XCTAssertLessThan(AnnotationViewport.sourcePoint(.zero, frame: out.frame(fitted: fitted), allowsOffscreen: true).x, 0)
        XCTAssertEqual(start.frame(fitted: fitted), fitted)
        XCTAssertEqual(start.navigating(scale: .nan, from: center, to: center, fitted: fitted), start)
    }

    func testAddingSecondFingerRollsBackCornerAndRemainingFingerCannotPlace() {
        var state = FieldPlacementTouchState()
        let a = CGPoint(x: 100, y: 100), b = CGPoint(x: 200, y: 100)
        XCTAssertEqual(state.update([a]), [.beginCorner(a)])
        XCTAssertEqual(state.update([b]), [.moveCorner(b)])
        XCTAssertEqual(state.update([a, b]), [.cancelCorner, .beginNavigation])
        XCTAssertEqual(state.update([.init(x: 80, y: 120), .init(x: 240, y: 120)]), [.navigate(scale: 1.6, from: .init(x: 150, y: 100), to: .init(x: 160, y: 120))])
        XCTAssertEqual(state.update([b]), [.endNavigation])
        XCTAssertEqual(state.update([a]), [])
        XCTAssertEqual(state.update([]), [])
        XCTAssertEqual(state.update([a]), [.beginCorner(a)])
        XCTAssertEqual(state.update([]), [.endCorner])
    }

    func testDirectTwoFingerStartAndCancellationNeverCommitCorner() {
        var state = FieldPlacementTouchState()
        XCTAssertEqual(state.update([.zero, .init(x: 100, y: 0)]), [.beginNavigation])
        XCTAssertEqual(state.cancel(), [.endNavigation])
        XCTAssertEqual(state.update([.zero]), [.beginCorner(.zero)])
        XCTAssertEqual(state.cancel(), [.cancelCorner])
        XCTAssertEqual(state.update([]), [])
    }

    func testLoupeStaysVisibleAndAwayFromFingerAtEdgesAndInLandscape() {
        let size = CGSize(width: 112, height: 100)
        for bounds in [CGRect(x: 0, y: 0, width: 390, height: 330), CGRect(x: 0, y: 0, width: 700, height: 140)] {
            for x in [bounds.minX + 2, bounds.midX, bounds.maxX - 2] {
                for y in [bounds.minY + 2, bounds.midY, bounds.maxY - 2] {
                    let finger = CGPoint(x: x, y: y), center = FieldPlacementViewport.loupeCenter(finger: finger, bounds: bounds, size: size)
                    let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
                    XCTAssertTrue(bounds.contains(rect)); XCTAssertFalse(rect.insetBy(dx: -30, dy: -30).contains(finger))
                }
            }
        }
    }
}
