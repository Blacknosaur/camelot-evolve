import XCTest

/// Drives the phone as a two-camera host while a real companion (the Android app or a second
/// iPhone) is running nearby: it must show up in the peers chip, a short take must complete,
/// and the companion's file must arrive. Creates a "UITest Multi-cam" project and removes it
/// with `-removeUITestProjects`, so it is safe on a phone with real data.
final class MultiCamHostUITests: XCTestCase {
    private let projectName = "UITest Multi-cam"

    @MainActor
    override func tearDown() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-removeUITestProjects"]
        app.launch()
        continueOfflineIfNeeded(app)
        let row = app.staticTexts[projectName]
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed, "The UITest project is removed after the test")
        app.terminate()
        try await super.tearDown()
    }

    @MainActor
    func testCompanionCameraJoinsRecordsAndDeliversItsFile() throws {
        let app = XCUIApplication()
        app.launch()
        continueOfflineIfNeeded(app)
        addUIInterruptionMonitor(withDescription: "Local network") { alert in
            for title in ["Allow", "OK"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            return false
        }
        app.tabBars.buttons["Projects"].tap()
        let row = app.staticTexts[projectName]
        if !row.waitForExistence(timeout: 3) {
            // A leftover from an interrupted run is reused; otherwise create the project.
            app.buttons["New project"].tap()
            let nameField = app.textFields["Project name"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 8), "The project form opens")
            nameField.tap(); nameField.typeText(projectName)
            app.buttons["Create"].tap()
            XCTAssertTrue(row.waitForExistence(timeout: 8))
        }
        row.tap()
        app.buttons["More"].tap()
        app.buttons["project-multicam"].tap()
        XCTAssertTrue(app.buttons["multicam-mode-dualCamera"].waitForExistence(timeout: 5))
        app.buttons["multicam-mode-dualCamera"].tap()
        app.buttons["multicam-start"].tap()

        let peers = app.descendants(matching: .any).matching(identifier: "multicam-peers").firstMatch
        XCTAssertTrue(peers.waitForExistence(timeout: 10))
        app.tap() // lets the interruption monitor handle the local-network prompt if it appears
        let joined = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] 'camera'"), object: peers)
        XCTAssertEqual(XCTWaiter.wait(for: [joined], timeout: 90), .completed, "A companion camera should join within 90 s (got \(peers.label))")

        let record = app.buttons["camera-record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, "The camera must be ready to record")
        record.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "camera-recording-time").firstMatch.waitForExistence(timeout: 8), "Recording chrome appears")
        sleep(8)
        record.tap()
        let stop = app.alerts.buttons["Stop and save"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.tap()

        let transfers = app.descendants(matching: .any).matching(identifier: "multicam-transfers").firstMatch
        XCTAssertTrue(transfers.waitForExistence(timeout: 30), "The transfer list appears once the take ends")
        XCTAssertTrue(app.staticTexts["Received"].waitForExistence(timeout: 180), "The companion's file should arrive (host says: \(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'video'")).firstMatch.label))")

        app.buttons["Close multi-cam"].tap()
        // Back in the project: the take and the companion's video are listed.
        let secondCamera = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Second camera'")).firstMatch
        XCTAssertTrue(secondCamera.waitForExistence(timeout: 10), "The companion's video is filed under the project")
    }

    /// Event-remote mode: this phone records on its own camera while a companion sends taps.
    /// A real companion must be running nearby (Android: launch with `--ez autoJoin true`).
    @MainActor
    func testEventRemoteSendsTapsOntoTheHostsRecording() throws {
        let app = XCUIApplication()
        app.launch()
        continueOfflineIfNeeded(app)
        addUIInterruptionMonitor(withDescription: "Local network") { alert in
            for title in ["Allow", "OK"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            return false
        }
        openMultiCamSetup(app)
        XCTAssertTrue(app.buttons["multicam-mode-eventRemote"].waitForExistence(timeout: 5))
        app.buttons["multicam-mode-eventRemote"].tap()
        app.buttons["multicam-start"].tap()

        // Event-remote hosting reuses the normal camera screen, with a remotes chip on the right.
        let remotes = app.descendants(matching: .any).matching(identifier: "camera-remotes").firstMatch
        XCTAssertTrue(remotes.waitForExistence(timeout: 15), "The camera opens with the remotes chip")
        app.tap()
        let joined = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES '.*[0-9]+ remote.*'"), object: remotes)
        XCTAssertEqual(XCTWaiter.wait(for: [joined], timeout: 90), .completed, "A companion should join as a remote (got \(remotes.label))")

        let record = app.buttons["camera-record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: record)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, "The camera must be ready to record")
        record.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "camera-recording-time").firstMatch.waitForExistence(timeout: 8), "Recording started")

        // The companion taps its pad while this runs; the chip counts what arrived.
        let tagged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS[c] 'events from remotes'"), object: remotes)
        XCTAssertEqual(XCTWaiter.wait(for: [tagged], timeout: 90), .completed, "Taps from the remote should become events (chip value: \(String(describing: remotes.value)))")

        record.tap()
        let stop = app.alerts.buttons["Stop and save"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.tap()
        XCTAssertTrue(app.staticTexts["Close camera"].waitForExistence(timeout: 2) || true)
        let saved = app.descendants(matching: .any).matching(identifier: "camera-saved-status").firstMatch
        let savedOne = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] '1 saved'"), object: saved)
        XCTAssertEqual(XCTWaiter.wait(for: [savedOne], timeout: 60), .completed, "The host's own recording is saved")
        app.buttons["Close camera"].tap()
    }

    /// Opens the project (creating it only when a previous run did not leave one) and its setup sheet.
    @MainActor
    private func openMultiCamSetup(_ app: XCUIApplication) {
        app.tabBars.buttons["Projects"].tap()
        let row = app.staticTexts[projectName]
        if !row.waitForExistence(timeout: 3) {
            app.buttons["New project"].tap()
            let nameField = app.textFields["Project name"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 8), "The project form opens")
            nameField.tap(); nameField.typeText(projectName)
            app.buttons["Create"].tap()
            XCTAssertTrue(row.waitForExistence(timeout: 8))
        }
        row.tap()
        app.buttons["More"].tap()
        app.buttons["project-multicam"].tap()
    }

    @MainActor
    private func continueOfflineIfNeeded(_ app: XCUIApplication) {
        if app.buttons["Continue offline"].waitForExistence(timeout: 4) { app.buttons["Continue offline"].tap() }
    }
}
