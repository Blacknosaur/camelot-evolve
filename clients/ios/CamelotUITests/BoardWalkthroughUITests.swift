import XCTest

/// Walks the board editor the way a coach builds a drill and saves a
/// screenshot of every state. Safe on a phone: the board is named "UITest …"
/// at creation and removed with `-removeUITestBoards`.
///
/// `TEST_RUNNER_CAMELOT_SHOTS_DIR=<folder>` also writes the PNGs to disk.
final class BoardWalkthroughUITests: XCTestCase {
    private var app: XCUIApplication!
    private var shots: URL?

    override func setUpWithError() throws {
        if let path = ProcessInfo.processInfo.environment["CAMELOT_SHOTS_DIR"], !path.isEmpty {
            shots = URL(filePath: path)
            try FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-removeUITestBoards", "-uiTestBoards"]
        app.launch()
        if app.buttons["Continue offline"].waitForExistence(timeout: 4) { app.buttons["Continue offline"].tap() }
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        app.launchArguments = ["-removeUITestBoards"]
        app.launch()
        app.terminate()
    }

    @MainActor
    func testCoachBuildsADrill() throws {
        app.tabBars.buttons["Boards"].tap()
        capture("01-boards")
        let canvas = app.openNewBoard("Full pitch")
        func point(_ x: Double, _ y: Double) -> XCUICoordinate { canvas.coordinate(withNormalizedOffset: .init(dx: x, dy: y)) }
        XCTAssertTrue(element("board-starter").waitForExistence(timeout: 4), "An empty board offers a way to start")
        capture("02-empty-board")

        // Players: the palette opens with Home ready; each tap adds one until Done.
        tapAny("board-start-players")
        XCTAssertTrue(element("board-palette").waitForExistence(timeout: 3))
        for (x, y) in [(0.3, 0.35), (0.3, 0.65), (0.45, 0.5)] { point(x, y).tap() }
        capture("03-home-placed")
        tapAny("board-item-away")
        for (x, y) in [(0.62, 0.4), (0.62, 0.6)] { point(x, y).tap() }
        tapAny("board-item-ball")
        point(0.47, 0.53).tap()
        capture("04-players-and-ball")
        tapAny("board-disarm")
        // A tap that lands on an existing player selects it; clear that first.
        if element("deselect").exists { element("deselect").tap() }
        XCTAssertTrue(element("board-toolbar").waitForExistence(timeout: 3), "Done returns to the task tiles")
        capture("05-tasks")

        // Equipment
        tapAny("board-palette-equipment")
        for (x, y) in [(0.2, 0.25), (0.2, 0.75)] { point(x, y).tap() }
        capture("06-equipment")
        tapAny("board-disarm")

        // Selecting shows plain actions in the bar; Edit opens the details.
        point(0.45, 0.5).tap()
        XCTAssertTrue(element("board-selection").waitForExistence(timeout: 3))
        capture("07-player-selected")
        tapAny("board-selection-edit")
        capture("08-player-details")
        tapAny("board-selection-edit")
        tapAny("board-selection-name")
        capture("09-player-name")
        if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons["Cancel"].tap() }
        tapAny("deselect")

        // Draw: a pass and a run, then the palette stays until Done.
        tapAny("board-draw")
        point(0.3, 0.35).press(forDuration: 0.1, thenDragTo: point(0.45, 0.5))
        tapAny("board-item-line-run")
        point(0.3, 0.65).press(forDuration: 0.1, thenDragTo: point(0.55, 0.75))
        capture("10-draw")
        tapAny("board-disarm")
        point(0.42, 0.72).tap()
        capture("11-line-selected")
        tapAny("deselect")

        tapAny("board-view")
        capture("12-view-menu")
        app.buttons["Top"].firstMatch.tap()

        // Animate: steps, move a player in step 2, play.
        tapAny("board-animate")
        XCTAssertTrue(element("board-transport").waitForExistence(timeout: 3))
        capture("13-animate")
        tapAny("board-stage-add")
        point(0.45, 0.5).press(forDuration: 0.1, thenDragTo: point(0.62, 0.3))
        capture("14-step-2")
        tapAny("deselect")
        tapAny("board-animation-done")

        tapAny("board-export")
        capture("15-export")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() } else { app.swipeDown() }

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        capture("16-landscape")
        point(0.45, 0.5).tap()
        capture("17-landscape-selected")
        XCUIDevice.shared.orientation = .portrait
        tapAny("board-close")
    }

    @MainActor
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func tapAny(_ id: String) {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        if element.waitForExistence(timeout: 4) { element.tap() } else { XCTFail("\(id) not found") }
    }

    @MainActor
    private func capture(_ name: String) {
        sleep(1)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let shots { try? shot.pngRepresentation.write(to: shots.appending(path: "\(name).png")) }
    }
}
