import XCTest

final class EditorInteractionTests: XCTestCase {
    @MainActor
    private func openEditor() throws -> XCUIApplication {
        guard let sample = ProcessInfo.processInfo.environment["CAMELOT_SAMPLE_VIDEO"] else {
            throw XCTSkip("Set TEST_RUNNER_CAMELOT_SAMPLE_VIDEO to a local video to run editor interaction tests")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding", "-seedSampleVideo", sample, "-seedEventCount", "240"]
        app.launch()
        if app.buttons["Continue offline"].waitForExistence(timeout: 5) { app.buttons["Continue offline"].tap() }
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Editor stress test,")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
        let video = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "240 events,")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        video.tap()
        XCTAssertTrue(app.navigationBars["Untitled video"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollViews["Video timeline"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["clip-sequence-timeline"].exists)
        return app
    }

    @MainActor
    func testHundredsOfEventsSearchFilterAndEdit() throws {
        let app = try openEditor()
        app.segmentedControls.buttons["Event list"].tap()
        let panel = app.otherElements["resize-workspace"]
        let divider = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let oldSize = panel.value as? String
        divider.press(forDuration: 0.1, thenDragTo: divider.withOffset(CGVector(dx: 0, dy: -100)))
        XCTAssertNotEqual(panel.value as? String, oldSize)
        let goal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Goal at")).firstMatch
        goal.tap()
        XCTAssertTrue(app.buttons["Deselect event"].exists)
        goal.tap()
        XCTAssertFalse(app.buttons["Deselect event"].exists)
        goal.tap()
        app.segmentedControls.buttons["Timeline"].tap()
        XCTAssertTrue(app.buttons["Edit selected event"].exists)
        app.buttons["Fit selected event"].tap()
        XCTAssertTrue(app.otherElements["Event start"].exists)
        XCTAssertTrue(app.otherElements["Event end"].exists)
        app.buttons["Deselect event"].tap()
        app.segmentedControls.buttons["Event list"].tap()
        let search = app.textFields["event-search"]
        search.tap(); search.typeText("Moment 239")
        XCTAssertEqual(app.staticTexts["event-result-count"].label, "1 / 240")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Moment 239")).firstMatch
        XCTAssertTrue(result.exists)
        result.tap()
        app.buttons["Event details"].tap()
        app.buttons["Edit details"].tap()
        XCTAssertTrue(app.navigationBars["Edit event"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Resizable editor with full event windows"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testClipTrimUndoZoomAndRotation() throws {
        let app = try openEditor()
        app.buttons["Trim selected clip"].tap()
        app.buttons["Move clip start later"].tap()
        XCTAssertEqual(app.staticTexts["timeline-current-time"].label, "0:00.1")
        app.buttons["Undo clip edit"].tap()
        app.buttons["Jump to clip start"].tap()
        XCTAssertEqual(app.staticTexts["timeline-current-time"].label, "0:00.0")
        app.buttons["Timeline options"].tap()
        app.buttons["Fit entire video"].tap()
        let before = app.staticTexts["timeline-current-time"].label
        app.buttons["Zoom in timeline"].tap()
        XCTAssertEqual(app.staticTexts["timeline-current-time"].label, before)
        app.buttons["Zoom out timeline"].tap()
        XCTAssertEqual(app.staticTexts["timeline-current-time"].label, before)
        let timeline = app.scrollViews["Video timeline"]
        timeline.pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(app.buttons["Zoom out timeline"].isEnabled)
        app.buttons["Fit range"].tap()
        let endHandle = app.otherElements["Clip end"]
        let oldEnd = endHandle.value as? String
        let edge = endHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        edge.press(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: -35, dy: 0)))
        XCTAssertNotEqual(endHandle.value as? String, oldEnd)
        app.buttons["Undo clip edit"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Fit range"].waitForExistence(timeout: 5))
        app.buttons["Fit range"].tap()
        XCTAssertTrue(app.otherElements["Clip start"].exists)
        XCTAssertTrue(app.otherElements["Clip end"].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Landscape trim"; attachment.lifetime = .keepAlways
        add(attachment)
        XCUIDevice.shared.orientation = .portrait
    }
    @MainActor
    func testClipsSplitSelectionAndReorder() throws {
        let app = try openEditor()
        app.buttons["Timeline options"].tap()
        app.buttons["Fit entire video"].tap()
        app.buttons["Split selected clip"].tap()
        app.buttons["Manage and reorder clips"].tap()
        XCTAssertTrue(app.staticTexts["Clips · 2"].waitForExistence(timeout: 3))
        app.buttons["Reorder"].tap()
        XCTAssertTrue(app.buttons["Done reordering"].exists)
        app.buttons["Done reordering"].tap()
        app.buttons["Undo clip edit"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Clips · 1"].exists)
    }

}
