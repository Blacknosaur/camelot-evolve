import XCTest

/// Walks every screen in portrait and landscape and writes PNGs to `CAMELOT_SHOTS_DIR`.
/// Run manually on a simulator; the sample video is seeded through the debug launch argument:
/// `TEST_RUNNER_CAMELOT_SHOTS_DIR=/tmp/shots TEST_RUNNER_CAMELOT_SAMPLE_VIDEO=/path/sample.mp4 xcodebuild test -only-testing:CamelotUITests/ScreenshotWalkthroughTests ...`
final class ScreenshotWalkthroughTests: XCTestCase {
    private var app: XCUIApplication!
    private var outputDirectory: URL?

    override func setUpWithError() throws {
        continueAfterFailure = true
        if let path = ProcessInfo.processInfo.environment["CAMELOT_SHOTS_DIR"], !path.isEmpty {
            outputDirectory = URL(filePath: path)
            try FileManager.default.createDirectory(at: outputDirectory!, withIntermediateDirectories: true)
        }
        app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        if let sample = ProcessInfo.processInfo.environment["CAMELOT_SAMPLE_VIDEO"], !sample.isEmpty {
            app.launchArguments += ["-seedSampleVideo", sample]
        }
        app.launchEnvironment = ProcessInfo.processInfo.environment
        app.launch()
    }

    @MainActor
    func testWalkthrough() throws {
        capture("01-onboarding")

        app.buttons["Continue offline"].tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))

        app.buttons["New project"].tap()
        app.textFields["Project name"].tap()
        app.textFields["Project name"].typeText("Training Tuesday")
        capture("03-new-project", portraitOnly: true)
        app.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["Training Tuesday"].waitForExistence(timeout: 5))
        capture("04-projects-list")

        app.staticTexts["Weekend Match"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Record"].waitForExistence(timeout: 5))
        let importedRow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'events,'")).firstMatch
        XCTAssertTrue(importedRow.waitForExistence(timeout: 15), "Seeded video row did not appear")
        sleep(2)
        capture("06-project-detail")

        importedRow.tap()
        XCTAssertTrue(app.navigationBars["Edit video"].waitForExistence(timeout: 10))
        sleep(2)
        capture("07-editor-events")
        let goalBar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Goal at'")).firstMatch
        if goalBar.waitForExistence(timeout: 3) {
            goalBar.tap()
            sleep(1)
            capture("07b-editor-event-selected")
        }
        app.buttons["Clips"].tap()
        capture("08-editor-clips")
        app.buttons["Trim"].tap()
        capture("09-editor-trim")
        app.buttons["Info"].tap()
        capture("10-editor-info", portraitOnly: true)
        app.buttons["Next"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        sleep(2)
        capture("11-highlight-player")
        app.buttons["Done"].tap()
        app.buttons["Close"].tap()

        app.buttons["Record"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Close camera"].waitForExistence(timeout: 5))
        sleep(2)
        capture("13-camera")
        app.buttons["Close camera"].tap()

        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5))
        capture("14-account")
    }

    /// Camera with the recording chrome forced on (debug flag) to check the tagging layout without a camera.
    @MainActor
    func testRecordingChrome() throws {
        app.terminate()
        app.launchArguments = ["-previewRecordingChrome"]
        app.launch()
        if app.buttons["Continue offline"].waitForExistence(timeout: 3) { app.buttons["Continue offline"].tap() }
        let projectRow = app.staticTexts["Weekend Match"].firstMatch
        if !projectRow.waitForExistence(timeout: 5) {
            app.buttons["New project"].tap()
            app.textFields["Project name"].tap()
            app.textFields["Project name"].typeText("Weekend Match")
            app.buttons["Create"].tap()
        }
        app.staticTexts["Weekend Match"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Record"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Record"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Tag goal"].waitForExistence(timeout: 5))
        sleep(2)
        capture("15-camera-recording")
    }

    @MainActor
    private func capture(_ name: String, portraitOnly: Bool = false) {
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        save(name: "\(name)-portrait")
        guard !portraitOnly else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        save(name: "\(name)-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
    }

    @MainActor
    private func save(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let outputDirectory else { return }
        try? screenshot.pngRepresentation.write(to: outputDirectory.appending(path: "\(name).png"))
    }
}
