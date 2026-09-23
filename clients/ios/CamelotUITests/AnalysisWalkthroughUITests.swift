import XCTest

/// Walks the task-first Analyse workspace and saves a screenshot of every
/// state. Runs on a simulator or a phone without touching real projects: it
/// seeds its own "UITest Analyse" project and removes it afterwards, and it
/// always closes the workspace without saving.
///
/// `TEST_RUNNER_CAMELOT_SAMPLE_VIDEO=<football clip> TEST_RUNNER_CAMELOT_SHOTS_DIR=<folder>`
final class AnalysisWalkthroughUITests: XCTestCase {
    private var app: XCUIApplication!
    private var shots: URL?
    private let project = "UITest Analyse"

    override func setUpWithError() throws {
        guard let sample = ProcessInfo.processInfo.environment["CAMELOT_SAMPLE_VIDEO"], !sample.isEmpty else {
            throw XCTSkip("Set CAMELOT_SAMPLE_VIDEO to a football clip")
        }
        if let path = ProcessInfo.processInfo.environment["CAMELOT_SHOTS_DIR"], !path.isEmpty {
            shots = URL(filePath: path)
            try FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-removeUITestProjects", "-seedSampleVideo", sample, "-seedProjectName", project]
        app.launch()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        guard let app else { return }
        app.terminate()
        app.launchArguments = ["-removeUITestProjects"]
        app.launch()
        app.terminate()
    }

    @MainActor
    func testTaskFirstWorkspaceWithoutSaving() throws {
        openAnalysis()
        let canvas = app.otherElements["analysis-preview-touch-surface"]
        func point(_ x: Double, _ y: Double) -> XCUICoordinate { canvas.coordinate(withNormalizedOffset: .init(dx: x, dy: y)) }

        XCTAssertTrue(app.buttons["analysis-task-player"].waitForExistence(timeout: 10))
        for id in ["analysis-task-draw", "analysis-task-text", "analysis-task-zoom", "analysis-task-pitch"] {
            XCTAssertTrue(app.buttons[id].exists, "\(id) should be on the resting bar")
            XCTAssertGreaterThanOrEqual(app.buttons[id].frame.height, 44)
        }
        capture("01-tasks")

        // Player: the prompt, then a box drawn around a player opens the highlight sheet.
        app.buttons["analysis-task-player"].tap()
        XCTAssertTrue(app.otherElements["analysis-player-prompt"].waitForExistence(timeout: 5))
        dismissAlert()
        capture("02-player-prompt")
        point(0.30, 0.42).press(forDuration: 0.15, thenDragTo: point(0.36, 0.62))
        XCTAssertTrue(element("analysis-player-ring").waitForExistence(timeout: 5))
        capture("03-highlight-sheet")
        element("analysis-player-label").tap()
        capture("04-highlight-sheet-name")
        app.buttons["analysis-apply-player-effects"].tap()
        // Vision is unavailable on the simulator; on a phone this is the live follow.
        if app.otherElements["analysis-tracking-status"].waitForExistence(timeout: 3) {
            capture("05-following")
            app.buttons["analysis-stop-tracking"].tap()
        }
        dismissAlert()
        if app.otherElements["analysis-player-bar"].waitForExistence(timeout: 10) {
            capture("06-player-bar")
            app.buttons["analysis-player-tracking"].tap()
            XCTAssertTrue(app.otherElements["analysis-fix-prompt"].waitForExistence(timeout: 5))
            capture("07-fix-prompt")
            app.buttons["analysis-fix-prompt-cancel"].tap()
        }
        deselect()

        // Draw: palette, then an arrow becomes the selection with plain actions.
        app.buttons["analysis-task-draw"].tap()
        XCTAssertTrue(app.otherElements["analysis-drawing-tools"].waitForExistence(timeout: 5))
        app.buttons["analysis-tool-arrow"].tap()
        capture("08-draw-palette")
        point(0.55, 0.75).press(forDuration: 0.1, thenDragTo: point(0.8, 0.45))
        XCTAssertTrue(app.otherElements["analysis-selection-bar"].waitForExistence(timeout: 5))
        capture("09-drawing-selected")
        app.buttons["analysis-motion-mode"].tap()
        capture("10-movement-menu")
        app.buttons["Stay put on screen"].tap()
        app.buttons["analysis-drawing-style"].tap()
        XCTAssertTrue(app.collectionViews["analysis-inspector-form"].waitForExistence(timeout: 5))
        capture("11-style-sheet")
        app.collectionViews["analysis-inspector-form"].swipeUp()
        capture("12-style-sheet-timing")
        app.buttons["Done"].firstMatch.tap()

        // Landscape keeps the same bars beside the video.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        capture("13-landscape-selected")
        deselect()
        capture("14-landscape-tasks")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)

        // Pitch: opens straight into automatic lining up.
        app.buttons["analysis-task-pitch"].tap()
        XCTAssertTrue(app.buttons["ground-apply"].waitForExistence(timeout: 10))
        sleep(4)
        capture("15-pitch")
        app.buttons["ground-adjustments"].tap()
        capture("16-pitch-adjust")
        app.buttons["ground-cancel"].tap()

        app.buttons["cancel-analysis-workspace"].tap()
        let discard = app.buttons["Discard changes"]
        if discard.waitForExistence(timeout: 3) { discard.tap() }
    }

    @MainActor
    private func openAnalysis() {
        let offline = app.buttons["Continue offline"]
        if offline.waitForExistence(timeout: 3) { offline.tap() }
        let projects = app.tabBars.buttons["Projects"]
        if projects.waitForExistence(timeout: 3) { projects.tap() }
        let row = app.staticTexts[project].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "source-")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 15)); source.tap()
        XCTAssertTrue(app.buttons["open-analysis"].waitForExistence(timeout: 15))
        app.buttons["open-analysis"].tap()
        app.buttons["open-video-analysis"].tap()
        XCTAssertTrue(app.otherElements["analysis-workspace-canvas"].waitForExistence(timeout: 10))
        sleep(2)
        dismissAlert()
    }

    @MainActor
    private func deselect() {
        for id in ["analysis-prompt-cancel", "analysis-player-prompt-cancel", "analysis-draw-done", "analysis-deselect"] where app.buttons[id].exists {
            app.buttons[id].tap()
        }
        XCTAssertTrue(app.buttons["analysis-task-player"].waitForExistence(timeout: 3), "The task tiles return after deselecting")
    }

    /// Highlight tiles are toggles, so match any element type.
    @MainActor
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func dismissAlert() {
        let alert = app.alerts["Analysis"]
        if alert.waitForExistence(timeout: 2) { alert.buttons["OK"].tap() }
    }

    @MainActor
    private func capture(_ name: String) {
        sleep(1)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let shots { try? shot.pngRepresentation.write(to: shots.appending(path: "\(name).png")) }
    }
}
