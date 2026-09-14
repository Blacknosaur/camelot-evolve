import UIKit
import XCTest

/// Physical-device smoke test using an existing project, without recording or adding data.
final class CameraRotationTests: XCTestCase {
    @MainActor
    func testRepeatedRotationKeepsControlsAvailable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-previewRecordingChrome"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        guard app.tabBars.buttons["Projects"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Sign in or continue offline before running the camera smoke test")
        }
        app.tabBars.buttons["Projects"].tap()
        let project = app.collectionViews.cells.firstMatch
        guard project.waitForExistence(timeout: 5) else { throw XCTSkip("An existing project is required") }
        project.tap()
        let openCamera = app.buttons["Record"].firstMatch
        XCTAssertTrue(openCamera.waitForExistence(timeout: 5))
        openCamera.tap()
        let record = app.buttons["camera-record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["camera-tag-goal"].isHittable)
        XCTAssertLessThanOrEqual(record.frame.width, 48, "Stop must be smaller during recording")
        XCTAssertTrue(app.buttons["camera-pause"].exists)
        record.tap()
        XCTAssertTrue(app.buttons["Stop and save"].waitForExistence(timeout: 2))
        app.buttons["Keep recording"].tap()
        XCTAssertTrue(record.exists)
        let dial = app.descendants(matching: .any).matching(identifier: "camera-zoom-dial").firstMatch
        XCTAssertTrue(dial.exists)
        let oldZoom = dial.value as? String
        let start = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -100, dy: 0)))
        XCTAssertNotEqual(dial.value as? String, oldZoom, "Dragging the dial must change camera zoom")
        XCTAssertTrue((dial.value as? String)?.contains("dial open") == true, "The dial must stay expanded when a drag ends")
        let zoomAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        zoomAttachment.name = "Expanded camera zoom dial"; zoomAttachment.lifetime = .keepAlways; add(zoomAttachment)
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let isLandscape = orientation.isLandscape
            let settled = NSPredicate { _, _ in
                let frame = app.frame
                return (frame.width > frame.height) == isLandscape && record.isHittable && app.buttons["camera-tag-note"].isHittable
            }
            let expectation = XCTNSPredicateExpectation(predicate: settled, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 2), .completed)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Camera orientation \(orientation.rawValue)"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        app.buttons["Close camera"].tap()
        XCTAssertTrue(openCamera.waitForExistence(timeout: 3))
    }
}
