import XCTest

/// Physical-device test of the viewfinder gestures. Opens an existing project's camera without recording.
final class CameraGestureTests: XCTestCase {
    @MainActor
    func testLensPillsPinchFocusAndLock() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        guard app.tabBars.buttons["Projects"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Sign in or continue offline before running the camera gesture test")
        }
        app.tabBars.buttons["Projects"].tap()
        let project = app.collectionViews.cells.firstMatch
        guard project.waitForExistence(timeout: 5) else { throw XCTSkip("An existing project is required") }
        project.tap()
        let openCamera = app.buttons["Record"].firstMatch
        XCTAssertTrue(openCamera.waitForExistence(timeout: 5))
        openCamera.tap()
        let dial = app.descendants(matching: .any).matching(identifier: "camera-zoom-dial").firstMatch
        guard dial.waitForExistence(timeout: 8) else { throw XCTSkip("The camera did not become ready on this device") }
        XCTAssertEqual(dial.value as? String, "1.0 times")

        // Lens pills: tapping 2× ramps there; the pill that owns the value carries the dial identity.
        let twoTimes = app.buttons["camera-zoom-2x"]
        XCTAssertTrue(twoTimes.exists, "A 2× pill must exist on every supported device")
        twoTimes.tap()
        let reachedTwo = NSPredicate { _, _ in (dial.value as? String)?.hasPrefix("2.0") == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reachedTwo, object: nil)], timeout: 3), .completed)
        XCTAssertFalse(app.buttons["camera-zoom-2x"].exists, "The selected lens shows the live factor instead of its stop")
        app.buttons["camera-zoom-1x"].tap()
        let reachedOne = NSPredicate { _, _ in (dial.value as? String)?.hasPrefix("1.0") == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reachedOne, object: nil)], timeout: 3), .completed)
        add(screenshot("Lens pills"))

        // Pinch on the preview zooms and shows the HUD.
        let viewfinder = app.otherElements["camera-viewfinder"]
        XCTAssertTrue(viewfinder.exists)
        viewfinder.pinch(withScale: 1.8, velocity: 2)
        add(screenshot("Pinch zoom HUD"))
        let hud = app.descendants(matching: .any).matching(identifier: "camera-zoom-hud").firstMatch
        XCTAssertTrue(hud.waitForExistence(timeout: 2), "The zoom HUD must show while pinching; hud count \(app.descendants(matching: .any).matching(identifier: "camera-zoom-hud").count)")
        let zoomedIn = NSPredicate { _, _ in
            guard let text = dial.value as? String, let number = Double(text.prefix { $0.isNumber || $0 == "." }) else { return false }
            return number > 1.2
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: zoomedIn, object: nil)], timeout: 2), .completed)
        viewfinder.doubleTap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reachedOne, object: nil)], timeout: 3), .completed, "Double tap resets to 1×")

        // Tap to focus shows the reticle and the exposure slider.
        viewfinder.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45)).tap()
        let reticle = app.descendants(matching: .any).matching(identifier: "camera-focus-indicator").firstMatch
        XCTAssertTrue(reticle.waitForExistence(timeout: 2))
        let exposure = app.descendants(matching: .any).matching(identifier: "camera-exposure-slider").firstMatch
        XCTAssertTrue(exposure.waitForExistence(timeout: 2))
        let sliderCenter = exposure.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        sliderCenter.press(forDuration: 0.1, thenDragTo: sliderCenter.withOffset(CGVector(dx: 0, dy: -30)))
        let raised = NSPredicate(format: "value != %@", "0.0 EV")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: raised, object: exposure)], timeout: 2), .completed,
                       "Dragging the sun up must raise the exposure bias")
        add(screenshot("Focus reticle and exposure slider"))

        // Long press locks AE/AF (away from the exposure slider); a tap unlocks.
        viewfinder.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.72)).press(forDuration: 0.9)
        add(screenshot("After long press"))
        let lock = app.descendants(matching: .any).matching(identifier: "camera-aeaf-lock").firstMatch
        XCTAssertTrue(lock.waitForExistence(timeout: 2))
        add(screenshot("AE/AF lock"))
        viewfinder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let unlocked = NSPredicate { _, _ in !lock.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: unlocked, object: nil)], timeout: 2), .completed)

        // Dragging the pill row opens the precision ruler.
        let start = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -90, dy: 0)))
        XCTAssertTrue((dial.value as? String)?.contains("dial open") == true)
        add(screenshot("Precision zoom ruler"))

        app.buttons["Close camera"].tap()
        XCTAssertTrue(openCamera.waitForExistence(timeout: 3))
    }

    @MainActor private func screenshot(_ name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        return attachment
    }
}
