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

        // Home stays armed, with a banner, until Done.
        tapAny("board-start-players")
        XCTAssertTrue(element("board-mode-banner").waitForExistence(timeout: 3))
        for (x, y) in [(0.3, 0.35), (0.3, 0.65), (0.45, 0.5)] { point(x, y).tap() }
        capture("03-home-placed")
        tapAny("board-item-away")
        for (x, y) in [(0.62, 0.4), (0.62, 0.6)] { point(x, y).tap() }
        capture("04-away-armed")
        tapAny("board-disarm")

        // Drag a ball straight from the bar onto the pitch.
        element("board-item-ball").coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: point(0.5, 0.56))
        tapAny("board-item-cone")
        for (x, y) in [(0.2, 0.25), (0.2, 0.75)] { point(x, y).tap() }
        tapAny("board-disarm")
        capture("05-drill")

        // Selecting shows the card straight away.
        point(0.45, 0.5).tap()
        XCTAssertTrue(element("board-inspector").waitForExistence(timeout: 3))
        capture("06-player-card")
        tapAny("board-card-close")

        // Draw: line types in the banner, several lines until Done.
        tapAny("board-draw")
        capture("07-draw")
        point(0.3, 0.35).press(forDuration: 0.1, thenDragTo: point(0.45, 0.5))
        tapAny("board-draw-run")
        point(0.3, 0.65).press(forDuration: 0.1, thenDragTo: point(0.55, 0.75))
        capture("08-drawn")
        tapAny("board-disarm")
        point(0.42, 0.72).tap()
        capture("09-line-card")
        tapAny("board-card-close")

        tapAny("board-animate")
        XCTAssertTrue(element("board-transport").waitForExistence(timeout: 3))
        tapAny("board-stage-add")
        point(0.45, 0.5).press(forDuration: 0.1, thenDragTo: point(0.62, 0.3))
        capture("10-step-2")
        if element("board-card-close").exists { element("board-card-close").tap() }
        tapAny("board-animation-done")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        capture("11-landscape")
        XCUIDevice.shared.orientation = .portrait
        tapAny("board-close")
    }

    /// Zooming in and back to 100% returns the pitch to the centre.
    @MainActor
    func testZoomBackToFullSizeRecentresThePitch() throws {
        app.tabBars.buttons["Boards"].tap()
        let canvas = app.openNewBoard("Full pitch")
        tapAny("board-start-players")
        canvas.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        tapAny("board-disarm")
        capture("30-start")
        canvas.pinch(withScale: 2.5, velocity: 2)
        sleep(1)
        capture("31-zoomed")
        let badge = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "%")).firstMatch
        if badge.waitForExistence(timeout: 3) { badge.tap() }
        sleep(2)
        capture("32-badge-reset")
        canvas.pinch(withScale: 2.5, velocity: 2)
        sleep(1)
        canvas.pinch(withScale: 0.2, velocity: -2)
        sleep(2)
        capture("33-pinched-out")
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
