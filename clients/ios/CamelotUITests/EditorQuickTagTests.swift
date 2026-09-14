import UIKit
import XCTest

/// Existing footage only. Draft changes are cancelled or undone before closing; no library items are added or deleted.
final class EditorQuickTagTests: XCTestCase {
    @MainActor
    func testCompactEventWorkspaceAndContextualFit() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        guard app.tabBars.buttons["Projects"].waitForExistence(timeout: 5) else { throw XCTSkip("Existing workspace required") }
        app.tabBars.buttons["Projects"].tap()
        let project = app.collectionViews.cells.firstMatch
        guard project.waitForExistence(timeout: 5) else { throw XCTSkip("Existing project required") }
        project.tap()
        let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT label CONTAINS %@", "source-", "Unavailable")).firstMatch
        guard video.waitForExistence(timeout: 5) else { throw XCTSkip("Existing footage required") }
        for _ in 0..<4 {
            if video.isHittable { break }
            app.swipeUp()
        }
        video.tap()
        let fit = app.buttons["Fit entire video"]
        XCTAssertTrue(fit.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        fit.tap()
        XCTAssertFalse(app.buttons["Add video"].exists)
        XCTAssertTrue(app.buttons["Add clip at start"].isHittable)
        XCTAssertTrue(app.buttons["Add clip at end"].isHittable)
        let event = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-event-")).firstMatch
        XCTAssertTrue(event.exists, "This walkthrough needs an existing event")
        let bounds = try XCTUnwrap(event.value as? String).components(separatedBy: " to ")
        XCTAssertEqual(bounds.count, 2)
        func seconds(_ text: String) -> Double {
            let parts = text.split(separator: ":").compactMap { Double($0) }
            return parts.count == 2 ? parts[0] * 60 + parts[1] : -1
        }
        let middle = (seconds(bounds[0]) + seconds(bounds[1])) / 2
        event.tap()
        XCTAssertEqual(app.buttons.matching(identifier: "Fit selected event").count, 1)
        XCTAssertFalse(app.buttons["Fit entire video"].exists)
        app.buttons["Fit selected event"].tap()
        let time = app.staticTexts["timeline-current-time"]
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(seconds(time.label) - middle) < 0.15 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 3), .completed)
        let eventsTab = app.segmentedControls.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Events (")).firstMatch
        XCTAssertTrue(eventsTab.exists)
        eventsTab.tap()
        XCTAssertTrue(app.textFields["event-search"].isHittable)
        XCTAssertFalse(app.buttons["Undo edit"].exists)
        XCTAssertFalse(app.buttons["Redo edit"].exists)
        XCTAssertFalse(app.buttons["Add video"].exists)
        XCTAssertFalse(app.buttons["editor-add-events"].exists)
        XCTAssertFalse(app.staticTexts["event-result-count"].exists)
        XCTAssertFalse(app.buttons["Fit selected event"].exists)
        XCTAssertLessThanOrEqual(app.otherElements["editor-preview-controls"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["Play"].frame.height, 44)
        let list = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        list.name = "Compact events workspace"; list.lifetime = .keepAlways; add(list)
        app.segmentedControls.buttons["Timeline"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "Fit selected event").count, 1)
        let timeline = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        timeline.name = "Single contextual Fit and light preview controls"; timeline.lifetime = .keepAlways; add(timeline)
        event.tap()
        XCTAssertTrue(app.buttons["Trim selected clip"].waitForExistence(timeout: 2))
        let originalCount = eventsTab.label
        let clipQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-clip-"))
        let originalClipCount = clipQuery.count
        let originalRange = event.value as? String
        app.buttons["Split selected clip"].tap()
        XCTAssertTrue(fit.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        fit.tap()
        XCTAssertEqual(clipQuery.count, originalClipCount + 1)
        XCTAssertEqual(eventsTab.label, originalCount, "Splitting must not duplicate crossing events")
        XCTAssertEqual(event.value as? String, originalRange, "The event keeps its full before/after window")
        event.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Clips 1–2")).firstMatch.exists)
        app.buttons["Fit selected event"].tap()
        let splitShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        splitShot.name = "One event spanning the split"; splitShot.lifetime = .keepAlways; add(splitShot)
        app.buttons["Undo edit"].tap()
        XCTAssertTrue(fit.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        fit.tap()
        XCTAssertEqual(clipQuery.count, originalClipCount)
        XCTAssertEqual(eventsTab.label, originalCount)
        let play = app.buttons["Play"]
        XCTAssertTrue(play.isHittable)
        play.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 2))
        app.buttons["Pause"].tap()
        let options = app.scrollViews["editor-actions-scroll"]
        XCTAssertTrue(options.isHittable)
        options.swipeLeft()
        XCTAssertTrue(app.buttons["Delete selected clip"].isHittable)
        let actions = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        actions.name = "Faded scrolling clip options"; actions.lifetime = .keepAlways; add(actions)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Play"].isHittable)
        XCTAssertTrue(time.isHittable)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "Compact landscape workspace"; landscape.lifetime = .keepAlways; add(landscape)
    }

    @MainActor
    func testPreviewTransportAndActualAspectRatio() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        guard app.tabBars.buttons["Projects"].waitForExistence(timeout: 5) else { throw XCTSkip("Existing workspace required") }
        app.tabBars.buttons["Projects"].tap()
        let project = app.collectionViews.cells.firstMatch
        guard project.waitForExistence(timeout: 5) else { throw XCTSkip("Existing project required") }
        project.tap()
        let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT label CONTAINS %@", "source-", "Unavailable")).firstMatch
        guard video.waitForExistence(timeout: 5) else { throw XCTSkip("Existing source recording required") }
        for _ in 0..<4 {
            if video.isHittable { break }
            app.swipeUp()
        }
        video.tap()
        XCTAssertTrue(app.buttons["Fit entire video"].wait(for: \.isEnabled, toEqual: true, timeout: 5))
        let aspect = app.buttons["Video aspect ratio"]
        XCTAssertTrue(aspect.isHittable)
        let ratio = try XCTUnwrap(aspect.value as? String)
        XCTAssertNotNil(ratio.range(of: #"^\d+([.,]\d+)?:\d+$"#, options: .regularExpression))
        XCTAssertFalse(app.staticTexts["Aspect · Original"].exists)
        let transport = app.otherElements["editor-preview-controls"]
        let time = app.staticTexts["timeline-current-time"]
        let before = time.label
        let play = app.buttons["Play"]
        XCTAssertGreaterThanOrEqual(play.frame.width, 44)
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        play.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 2))
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in time.label != before }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 3), .completed)
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Play"].exists)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(transport.waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Play"].isHittable)
            XCTAssertTrue(time.isHittable)
            XCTAssertGreaterThanOrEqual(transport.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(transport.frame.maxX, app.frame.maxX)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = orientation == .portrait ? "Preview transport portrait" : "Preview transport landscape"
            shot.lifetime = .keepAlways; add(shot)
        }
    }

    @MainActor
    func testEventPaletteLeavesPlaybackRunningAndPinchKeepsPosition() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { app.terminate() }
        guard app.tabBars.buttons["Projects"].waitForExistence(timeout: 5) else { throw XCTSkip("Existing workspace required") }
        app.tabBars.buttons["Projects"].tap()
        let project = app.collectionViews.cells.firstMatch
        guard project.waitForExistence(timeout: 5) else { throw XCTSkip("Existing project required") }
        project.tap()
        let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT label CONTAINS %@", "source-", "Unavailable")).firstMatch
        guard video.waitForExistence(timeout: 5) else { throw XCTSkip("Existing source recording required") }
        for _ in 0..<4 {
            if video.isHittable { break }
            app.swipeUp()
        }
        let sourcePickerID = "clip-\(video.identifier)"
        video.tap()
        let timeline = app.scrollViews["Video timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Fit entire video"].isHittable)
        XCTAssertFalse(app.buttons["Timeline options"].exists)
        XCTAssertFalse(app.buttons["Manage and reorder clips"].exists)
        XCTAssertFalse(app.staticTexts["Full edit"].exists)
        XCTAssertTrue(app.staticTexts["editor-video-title"].exists)
        app.buttons["Fit entire video"].tap()
        XCTAssertTrue(app.buttons["Add clip at start"].isHittable)
        XCTAssertTrue(app.buttons["Add clip at end"].isHittable)
        let clipQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-clip-"))
        let originalClipID = clipQuery.firstMatch.identifier
        for label in ["Add clip at start", "Add clip at end"] {
            app.buttons[label].tap()
            XCTAssertTrue(app.navigationBars["Add a video"].waitForExistence(timeout: 3))
            app.buttons[sourcePickerID].tap()
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Full video ·")).firstMatch.tap()
            let fit = app.buttons["Fit entire video"]
            XCTAssertTrue(fit.wait(for: \.isEnabled, toEqual: true, timeout: 5))
            fit.tap()
            XCTAssertEqual(clipQuery.count, 2)
            if label == "Add clip at start" { XCTAssertNotEqual(clipQuery.firstMatch.identifier, originalClipID) }
            else { XCTAssertEqual(clipQuery.firstMatch.identifier, originalClipID) }
            app.buttons["Undo edit"].tap()
            XCTAssertTrue(fit.wait(for: \.isEnabled, toEqual: true, timeout: 5))
            fit.tap()
            XCTAssertEqual(clipQuery.count, 1)
            XCTAssertEqual(clipQuery.firstMatch.identifier, originalClipID)
        }
        XCTAssertFalse(app.buttons["Add video"].exists)
        XCTAssertEqual(app.buttons["editor-add-events"].frame.midY, app.buttons["Redo edit"].frame.midY, accuracy: 1)
        let rounded = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        rounded.name = "Rounded timeline with add clip buttons"; rounded.lifetime = .keepAlways; add(rounded)
        let originalTitle = app.staticTexts["editor-video-title"].label
        app.buttons["Video settings"].tap()
        XCTAssertTrue(app.textFields["video-settings-title"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["video-settings-aspect"].exists)
        app.buttons["video-settings-aspect"].tap()
        // A physical-device rotation dismisses native menus. Reopen after it settles.
        if !app.buttons["Portrait 9:16"].waitForExistence(timeout: 2) {
            app.buttons["video-settings-aspect"].tap()
        }
        XCTAssertTrue(app.buttons["Portrait 9:16"].waitForExistence(timeout: 3))
        app.buttons["Portrait 9:16"].tap()
        app.buttons["Delete video"].tap()
        XCTAssertTrue(app.alerts["Delete this video?"].waitForExistence(timeout: 2))
        app.alerts.buttons["Cancel"].tap()
        let settings = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        settings.name = "Video settings"; settings.lifetime = .keepAlways; add(settings)
        app.buttons["Close video settings"].tap()
        XCTAssertEqual(app.staticTexts["editor-video-title"].label, originalTitle)
        XCTAssertTrue(app.buttons["Add video"].isHittable)
        XCTAssertTrue(app.buttons["Undo edit"].exists)
        XCTAssertLessThan(app.buttons["Play"].frame.maxY, timeline.frame.minY)
        app.buttons["Play"].tap()
        app.buttons["editor-add-events"].tap()
        XCTAssertTrue(app.buttons["editor-tag-goal"].exists)
        XCTAssertTrue(app.buttons["editor-tag-note"].isHittable)
        XCTAssertTrue(app.buttons["Pause"].exists, "Opening event tools must keep playback running")
        app.buttons["Pause"].tap()
        let time = app.staticTexts["timeline-current-time"]
        let before = time.label
        timeline.pinch(withScale: 2, velocity: 1)
        XCTAssertEqual(time.label, before)
        timeline.pinch(withScale: 0.7, velocity: -1)
        XCTAssertEqual(time.label, before)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Quick event row above the timeline"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["editor-add-events"].tap()
        XCTAssertFalse(app.buttons["editor-tag-goal"].exists)
        let event = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline-event-")).firstMatch
        if event.exists {
            event.tap()
            XCTAssertTrue(app.buttons["Delete selected event"].isHittable)
            XCTAssertFalse(app.buttons["Trim selected clip"].exists)
            let selected = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            selected.name = "Selected event actions"; selected.lifetime = .keepAlways; add(selected)
            app.buttons["Edit selected event"].tap()
            XCTAssertTrue(app.buttons["Purple event color"].waitForExistence(timeout: 3))
            app.buttons["Purple event color"].tap()
            let color = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            color.name = "Event color picker"; color.lifetime = .keepAlways; add(color)
            app.buttons["Cancel"].tap()
            XCTAssertFalse(app.buttons["Deselect event"].exists)
            let eventID = event.identifier
            app.buttons[eventID].tap()
            XCTAssertFalse(app.buttons["Delete selected event"].exists)
            app.buttons[eventID].tap()
            let beforeDelete = time.label
            // Deletion remains an editor draft until closing; undo it before leaving.
            app.buttons["Delete selected event"].tap()
            XCTAssertFalse(app.buttons[eventID].exists)
            app.buttons["Undo edit"].tap()
            XCTAssertTrue(app.buttons[eventID].exists)
            XCTAssertEqual(time.label, beforeDelete)
            app.buttons["Redo edit"].tap()
            XCTAssertFalse(app.buttons[eventID].exists)
            app.buttons["Undo edit"].tap()
            XCTAssertTrue(app.buttons[eventID].exists)
        }
        app.segmentedControls.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Events (")).firstMatch.tap()
        XCTAssertFalse(app.buttons["Add"].exists)
        app.segmentedControls.buttons["Timeline"].tap()
        app.buttons["Trim selected clip"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "Fit clip").count, 1)
        XCTAssertFalse(app.buttons["Fit entire video"].exists)
        XCTAssertFalse(app.buttons["editor-add-events"].exists)
        XCTAssertFalse(app.buttons["Split selected clip"].exists)
        XCTAssertTrue(app.buttons["Move clip start later"].isHittable)
        XCTAssertTrue(app.buttons["Move clip end earlier"].isHittable)
        XCTAssertFalse(app.segmentedControls["editor-workspace-switch"].exists)
        XCTAssertTrue(app.buttons["save-clip-trim"].isHittable)
        XCTAssertTrue(app.buttons["cancel-clip-trim"].isHittable)
        let originalIn = app.staticTexts["clip-trim-in"].label
        let nudge = app.buttons["Move clip start later"]
        XCTAssertGreaterThanOrEqual(nudge.frame.width, 44)
        XCTAssertGreaterThanOrEqual(nudge.frame.height, 48)
        nudge.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
        XCTAssertNotEqual(app.staticTexts["clip-trim-in"].label, originalIn)
        let trim = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        trim.name = "Focused trim controls"; trim.lifetime = .keepAlways; add(trim)
        app.buttons["cancel-clip-trim"].tap()
        app.buttons["Trim selected clip"].tap()
        XCTAssertEqual(app.staticTexts["clip-trim-in"].label, originalIn, "Cancel must discard the draft range")
        app.buttons["Move clip start later"].tap()
        let savedIn = app.staticTexts["clip-trim-in"].label
        app.buttons["save-clip-trim"].tap()
        app.buttons["Trim selected clip"].tap()
        XCTAssertEqual(app.staticTexts["clip-trim-in"].label, savedIn, "Save must apply the draft range")
        app.buttons["cancel-clip-trim"].tap()
        app.buttons["Undo edit"].tap()
        app.buttons["Trim selected clip"].tap()
        XCTAssertEqual(app.staticTexts["clip-trim-in"].label, originalIn, "One undo must restore the whole trim")
        app.buttons["cancel-clip-trim"].tap()
        // Tap near the edge of the back button, away from the chevron glyph.
        app.buttons["Back to project"].coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(video.waitForExistence(timeout: 3))
        let unavailable = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source-", "Unavailable")).firstMatch
        if unavailable.exists {
            for _ in 0..<5 {
                if unavailable.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(app.buttons["delete-\(unavailable.identifier)"].exists)
            unavailable.tap()
            XCTAssertTrue(app.buttons["Delete video"].waitForExistence(timeout: 3))
            app.buttons["Delete video"].tap()
            XCTAssertTrue(app.alerts["Delete this video?"].waitForExistence(timeout: 3))
            let missing = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            missing.name = "Unavailable video deletion confirmation"; missing.lifetime = .keepAlways; add(missing)
            app.alerts.buttons["Cancel"].tap()
            app.buttons["Done"].tap()
            XCTAssertTrue(unavailable.exists)
        }
    }
}
