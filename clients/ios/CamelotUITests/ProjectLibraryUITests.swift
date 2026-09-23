import XCTest

/// Search and filtering in a project's video library.
/// Seeded library checks require `CAMELOT_SAMPLE_VIDEO`. The existing-project
/// import check is opt-in and only opens/cancels the picker without saving.
final class ProjectLibraryUITests: XCTestCase {
    private static let projectName = "UITest Library"
    private var outputDirectory: URL?

    /// Read-only: opens and cancels Photos twice, without choosing any media.
    @MainActor
    func testExistingProjectImportMenuOpensPhotoPickerAndCanCancel() throws {
        guard ProcessInfo.processInfo.environment["CAMELOT_EXISTING_ANALYSIS_PROJECT"] != nil else { throw XCTSkip("Opt in on the fixture phone") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Editor stress test,")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        let more = app.buttons["project-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        for _ in 0..<2 {
            more.tap()
            let importVideo = app.buttons["project-import-video"]
            XCTAssertTrue(importVideo.waitForExistence(timeout: 3)); importVideo.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Import must present the system photo picker")
            capture(app, "project-import-picker")
            cancel.tap()
            XCTAssertTrue(more.waitForExistence(timeout: 5))
        }
    }

    private func makeApp() throws -> XCUIApplication {
        let sample = ProcessInfo.processInfo.environment["CAMELOT_SAMPLE_VIDEO"] ?? ""
        guard !sample.isEmpty else { throw XCTSkip("Set CAMELOT_SAMPLE_VIDEO to run the library walkthrough") }
        if let path = ProcessInfo.processInfo.environment["CAMELOT_SHOTS_DIR"], !path.isEmpty {
            outputDirectory = URL(filePath: path)
            try FileManager.default.createDirectory(at: outputDirectory!, withIntermediateDirectories: true)
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-seedSampleVideo", sample,
            "-seedVideoCount", "3",
            "-seedProjectName", Self.projectName,
        ]
        return app
    }

    @MainActor
    private func openSeededProject(_ app: XCUIApplication) throws {
        app.launch()
        if app.buttons["Continue offline"].waitForExistence(timeout: 5) { app.buttons["Continue offline"].tap() }
        if app.tabBars.buttons["Projects"].waitForExistence(timeout: 5) { app.tabBars.buttons["Projects"].tap() }
        let row = app.staticTexts[Self.projectName].firstMatch
        guard row.waitForExistence(timeout: 20) else { throw XCTSkip("Seeded project unavailable") }
        row.tap()
        XCTAssertTrue(app.staticTexts["video-result-count"].waitForExistence(timeout: 20), "The library summary appears")
    }

    private func videoCount(_ app: XCUIApplication) -> Int {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "source-")).count
    }

    /// Searching by title, then filtering by event kind, narrows the list and clearing restores it.
    @MainActor
    func testSearchAndKindFilterNarrowTheLibrary() throws {
        continueAfterFailure = false
        let app = try makeApp()
        XCUIDevice.shared.orientation = .portrait
        try openSeededProject(app)
        defer { app.terminate() }

        XCTAssertTrue(waitForVideoCount(app, 3), "All seeded videos are listed")
        // Navigation bar, search field, summary line and filter chips only; the old header pushed
        // the first card past 420pt on this phone.
        let firstCardTop = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "source-")).firstMatch.frame.minY
        XCTAssertLessThan(firstCardTop, 290, "The first video card sits near the top of the screen")

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "The library has a search field")
        search.tap()
        search.typeText("Second half")
        XCTAssertTrue(waitForVideoCount(app, 1), "Only the matching video remains")
        capture(app, "search-title")

        // An event note that no title contains still finds its video.
        clear(search, in: app)
        search.typeText("Penalty")
        XCTAssertTrue(waitForVideoCount(app, 1), "An event note matches its video")

        clear(search, in: app)
        XCTAssertTrue(waitForVideoCount(app, 3), "Clearing the search restores every video")

        let goal = app.buttons["filter-kind-Goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 5), "Event kind filters are available")
        goal.tap()
        XCTAssertTrue(waitForVideoCount(app, 1), "Only videos containing a goal remain")
        XCTAssertTrue(app.staticTexts["video-result-count"].label.hasPrefix("1 of 3"), "The result count is visible")
        capture(app, "filter-goal")

        app.buttons["filter-clear"].tap()
        XCTAssertTrue(waitForVideoCount(app, 3), "Clearing the filter restores every video")

        // A combination with no matches shows the empty result state.
        goal.tap()
        search.tap()
        search.typeText("Warm up")
        XCTAssertTrue(waitForVideoCount(app, 0), "No video is both a warm up and a goal video")
        XCTAssertTrue(app.staticTexts["No matching videos"].waitForExistence(timeout: 3))
        capture(app, "no-results")
    }

    /// Writes PNGs for review when `CAMELOT_SHOTS_DIR` is set; otherwise it only attaches them.
    @MainActor
    func testLibraryScreenshots() throws {
        continueAfterFailure = true
        let app = try makeApp()
        XCUIDevice.shared.orientation = .portrait
        try openSeededProject(app)
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        sleep(2)
        capture(app, "library-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        capture(app, "library-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
    }

    @MainActor
    private func waitForVideoCount(_ app: XCUIApplication, _ expected: Int) -> Bool {
        let predicate = NSPredicate { [weak self] _, _ in self?.videoCount(app) == expected }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5) == .completed
    }

    @MainActor
    private func clear(_ search: XCUIElement, in app: XCUIApplication) {
        let clearButton = search.buttons.firstMatch
        if clearButton.exists { clearButton.tap() } else if let value = search.value as? String {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let outputDirectory else { return }
        try? screenshot.pngRepresentation.write(to: outputDirectory.appending(path: "\(name).png"))
    }
}
