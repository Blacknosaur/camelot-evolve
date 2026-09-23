import XCTest

/// Field setup on a seeded synthetic pitch video: rough handles snap to the
/// painted markings and the quality readout drives the review flow. Runs on the
/// simulator; the pitch model is not required because handles are placed by hand.
final class FieldSetupUITests: XCTestCase {
    private let corners: [CGPoint] = [.init(x: 0.18, y: 0.16), .init(x: 0.83, y: 0.15), .init(x: 0.98, y: 0.92), .init(x: 0.03, y: 0.94)]

    @MainActor private func openMeasurements() throws -> XCUIApplication {
        guard let sample = ProcessInfo.processInfo.environment["CAMELOT_SAMPLE_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_CAMELOT_SAMPLE_VIDEO to the synthetic pitch video")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding", "-seedSampleVideo", sample, "-seedEventCount", "3"]
        app.launch()
        if app.buttons["Continue offline"].waitForExistence(timeout: 5) { app.buttons["Continue offline"].tap() }
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Editor stress test,")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "source-")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10)); video.tap()
        XCTAssertTrue(app.buttons["open-analysis"].waitForExistence(timeout: 10)); app.buttons["open-analysis"].tap(); app.buttons["open-video-analysis"].tap()
        XCTAssertTrue(app.otherElements["analysis-workspace-canvas"].waitForExistence(timeout: 10))
        if app.alerts["Analysis"].waitForExistence(timeout: 3) { app.alerts["Analysis"].buttons["OK"].tap() }
        app.buttons["analysis-tools"].tap()
        app.buttons["analysis-tool-measure"].tap()
        XCTAssertTrue(app.otherElements["ground-preview"].waitForExistence(timeout: 10))
        if app.buttons["ground-adjustments"].exists, !app.buttons["ground-snap"].exists { app.buttons["ground-adjustments"].tap() }
        XCTAssertTrue(app.buttons["ground-snap"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
        return app
    }

    /// Screen coordinate of a normalized video point inside the aspect-fitted preview.
    @MainActor private func location(_ point: CGPoint, in preview: XCUIElement, offset: CGVector = .zero) -> XCUICoordinate {
        let bounds = preview.frame
        let scale = min(bounds.width / 16, bounds.height / 9)
        let fitted = CGRect(x: bounds.midX - 8 * scale, y: bounds.midY - 4.5 * scale, width: 16 * scale, height: 9 * scale)
        let target = CGPoint(x: fitted.minX + point.x * fitted.width + offset.dx, y: fitted.minY + point.y * fitted.height + offset.dy)
        return preview.coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: target.x - bounds.minX, dy: target.y - bounds.minY))
    }

    @MainActor
    func testRoughWholePitchHandlesSnapToMarkingsAndApply() throws {
        let app = try openMeasurements()
        let preview = app.otherElements["ground-preview"]
        XCTAssertTrue((preview.value as? String ?? "").contains("Overlay visible; 4 points"))
        XCTAssertFalse(app.otherElements["ground-quality"].exists)
        app.buttons["ground-landmark-picker"].tap(); app.buttons["Whole pitch"].tap()
        // Place every corner a few points away from the real pitch corner.
        for (index, corner) in corners.enumerated() {
            app.buttons["ground-point-\(index)"].tap()
            location(corner, in: preview, offset: .init(dx: index.isMultiple(of: 2) ? 5 : -5, dy: index < 2 ? 4 : -4)).tap()
        }
        XCTAssertFalse(app.buttons["ground-apply"].isEnabled)
        let before = preview.value as? String
        let rough = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); rough.name = "Rough whole-pitch handles"; rough.lifetime = .keepAlways; add(rough)
        if app.buttons["ground-adjustments"].exists, !app.buttons["ground-snap"].exists { app.buttons["ground-adjustments"].tap() }
        app.buttons["ground-snap"].tap()
        let quality = app.otherElements["ground-quality"]
        XCTAssertTrue(quality.waitForExistence(timeout: 30))
        XCTAssertTrue((quality.value as? String ?? "").hasPrefix("Good fit"), quality.value as? String ?? "")
        XCTAssertNotEqual(preview.value as? String, before, "Snapping moves the handles onto the markings")
        XCTAssertFalse(app.buttons["ground-apply"].isEnabled, "Snapping never bypasses the alignment review")
        let snapped = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); snapped.name = "Handles snapped to painted markings"; snapped.lifetime = .keepAlways; add(snapped)
        // Editing after a snap clears the quality until the next snap.
        app.buttons["ground-nudge-right"].tap()
        XCTAssertFalse(quality.exists)
        app.buttons["ground-snap"].tap()
        XCTAssertTrue(quality.waitForExistence(timeout: 30))
        app.buttons["ground-settings"].tap()
        XCTAssertTrue(app.staticTexts["Median residual"].waitForExistence(timeout: 5))
        let fixed = app.switches["Camera stays fixed"]
        if fixed.value as? String != "1" { fixed.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        app.buttons["Done"].tap()
        XCTAssertTrue(quality.exists, "Reference settings do not discard the snap")
        XCTAssertTrue(app.buttons["ground-apply"].isEnabled)
        app.buttons["ground-apply"].tap()
        XCTAssertTrue(app.otherElements["analysis-workspace-canvas"].waitForExistence(timeout: 5))
        app.buttons["analysis-clip-tracks"].tap(); app.buttons["Measurements & ground"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue((preview.value as? String ?? "").contains("4 points"))
        XCTAssertTrue(app.buttons["ground-apply"].wait(for: \.isEnabled, toEqual: true, timeout: 10), "A saved calibration reopens already reviewed")
        app.buttons["ground-cancel"].tap()
        app.buttons["cancel-analysis-workspace"].tap()
    }

    @MainActor
    func testMethodMenuSwitchesBetweenTracedLinesAndLandmarks() throws {
        let app = try openMeasurements()
        let preview = app.otherElements["ground-preview"]
        app.buttons["ground-landmark-picker"].tap(); app.buttons["Trace visible lines"].tap()
        XCTAssertTrue((preview.value as? String ?? "").contains("0 points"))
        if app.buttons["ground-adjustments"].exists, !app.buttons["ground-snap"].exists { app.buttons["ground-adjustments"].tap() }
        XCTAssertFalse(app.buttons["ground-snap"].isEnabled, "Nothing to snap before four lines are traced")
        XCTAssertTrue(app.buttons["ground-line-picker"].exists)
        let lineStatus = app.otherElements["ground-line-status"]
        XCTAssertTrue(lineStatus.exists)
        XCTAssertTrue((lineStatus.value as? String ?? "").contains("Trace visible parts"))
        app.buttons["ground-landmark-picker"].tap(); app.buttons["Centre circle"].tap()
        XCTAssertTrue((preview.value as? String ?? "").contains("4 points"))
        XCTAssertTrue(app.buttons["ground-snap"].wait(for: \.isEnabled, toEqual: true, timeout: 5))
        XCTAssertTrue(app.buttons["ground-nudge-left"].isEnabled)
        app.buttons["ground-overlay-toggle"].tap()
        XCTAssertTrue((preview.value as? String ?? "").contains("Overlay hidden"))
        XCTAssertFalse(app.buttons["ground-nudge-left"].isEnabled)
        app.buttons["ground-overlay-toggle"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["ground-snap"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ground-apply"].isHittable)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Field setup landscape"; landscape.lifetime = .keepAlways; add(landscape)
        XCUIDevice.shared.orientation = .portrait
        app.buttons["ground-cancel"].tap()
        app.buttons["cancel-analysis-workspace"].tap()
    }
}
