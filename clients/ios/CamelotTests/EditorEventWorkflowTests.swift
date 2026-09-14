import AVFoundation
import SwiftData
import SwiftUI
import XCTest
@testable import Camelot

final class EditorEventWorkflowTests: XCTestCase {
    @MainActor
    func testDrawingTimelineHasSolidFillAndIndependentNativeHandles() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sequence-test", withExtension: "mp4"))
        let drawing = TimelineEventSnapshot(offset: 5, preRoll: 3, postRoll: 3, kind: "✎ Polygon", colorHex: "BDEB35", lowerBound: 0, upperBound: 10, isDrawing: true)
        let event = TimelineEventSnapshot(offset: 5, preRoll: 3, postRoll: 3, kind: "Goal", colorHex: "BDEB35")
        var changed: (Double, Double)?
        var edited = drawing
        func surface() -> TimelineSurface { TimelineSurface(videoURL: fixture, clips: [], selectedClipID: nil, selectClip: { _ in }, reorderClip: { _, _ in },
            feedback: EditorTimelineFeedback(), duration: 10, currentSeconds: 5, zoom: 1, events: [edited, event], selectedEventID: drawing.id,
            trimStart: 0, trimEnd: 10, showsTrim: false, previewSeek: { _ in }, commitSeek: { _ in },
            changeZoom: { _ in }, beginTrimEdit: {}, updateTrim: { _, _ in }, selectEvent: { _ in }, updateEventWindow: { _, before, after in changed = (before, after) }) }
        let viewport = TimelineViewport(configuration: surface())
        defer { viewport.stop() }
        viewport.frame = CGRect(x: 0, y: 0, width: 390, height: 200); viewport.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: viewport.bounds).image { viewport.layer.render(in: $0.cgContext) }
        let cgImage = try XCTUnwrap(image.cgImage), data = try XCTUnwrap(cgImage.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data)), stride = cgImage.bitsPerPixel / 8
        func pixel(_ point: CGPoint) -> [UInt8] {
            let offset = Int(point.y * image.scale) * cgImage.bytesPerRow + Int(point.x * image.scale) * stride
            return Array(UnsafeBufferPointer(start: bytes + offset, count: stride))
        }
        let elements = try XCTUnwrap(viewport.accessibilityElements).compactMap { $0 as? UIAccessibilityElement }
        for snapshot in [drawing, event] {
            let element = try XCTUnwrap(elements.first { $0.accessibilityIdentifier == "timeline-event-\(snapshot.id)" })
            let frame = element.accessibilityFrameInContainerSpace
            let left = pixel(.init(x: frame.minX + frame.width * 0.3, y: frame.maxY - 5))
            let right = pixel(.init(x: frame.minX + frame.width * 0.7, y: frame.maxY - 5))
            if snapshot.isDrawing { XCTAssertEqual(left, right, "Drawing fill has no before/after split") }
            else { XCTAssertNotEqual(left, right, "Match events retain their split fill") }
        }
        let screenshot = XCTAttachment(image: image); screenshot.name = "Solid drawing and split event on main timeline"; screenshot.lifetime = .keepAlways; add(screenshot)
        let handle = try XCTUnwrap(viewport.subviews.first { $0.accessibilityLabel == "Drawing start" })
        XCTAssertEqual(handle.accessibilityLabel, "Drawing start")
        for _ in 0..<45 {
            handle.accessibilityIncrement()
            let rolls = try XCTUnwrap(changed)
            edited = TimelineEventSnapshot(id: drawing.id, offset: 5, preRoll: rolls.0, postRoll: rolls.1, kind: drawing.kind, lowerBound: 0, upperBound: 10, isDrawing: true)
            viewport.update(surface())
        }
        XCTAssertEqual(edited.start, 6.5, accuracy: 0.001, "Native handle crosses the old midpoint")
        edited.isLocked = true; viewport.update(surface())
        XCTAssertTrue(handle.isHidden)
    }

    @MainActor
    func testEventColorPersistsAndFollowsRepeatedClips() throws {
        let schema = Schema([Project.self, Recording.self, MatchEvent.self, VideoComposition.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true))
        let event = MatchEvent(projectID: UUID(), recordingID: UUID(), kind: "Goal")
        XCTAssertEqual(event.colorHex, "")
        event.colorHex = EventColor.purple.rawValue
        event.offsetSeconds = 5; event.preRollSeconds = 3; event.postRollSeconds = 3
        container.mainContext.insert(event)
        try container.mainContext.save()
        let context = ModelContext(container)
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<MatchEvent>()).first)
        XCTAssertEqual(stored.colorHex, "B89AFF")
        let source = TimelineEventSnapshot(stored)
        let first = EditorSequenceSegment(id: UUID(), sourceStart: 4, sourceEnd: 7, rate: 2, start: 0)
        let second = EditorSequenceSegment(id: UUID(), sourceStart: 2, sourceEnd: 6, rate: 0.5, start: first.end)
        for segment in [first, second] {
            let mapped = try XCTUnwrap(segment.eventSnapshot(source))
            XCTAssertEqual(mapped.colorHex, stored.colorHex)
            XCTAssertEqual(mapped.id.clipID, segment.id)
            XCTAssertGreaterThanOrEqual(mapped.start, segment.start)
            XCTAssertLessThanOrEqual(mapped.end, segment.end)
        }
        XCTAssertEqual(UIColor(EventColor.tint(hex: "invalid", kind: "Goal")), UIColor(EventKind.tint(for: "Goal")))
    }

    @MainActor
    func testReorderLabelStaysAboveClipsAndCommitsOnlyOnDrop() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sequence-test", withExtension: "mp4"))
        let first = EditorSequenceSegment(id: UUID(), sourceStart: 0, sourceEnd: 2, rate: 1, start: 0)
        let second = EditorSequenceSegment(id: UUID(), sourceStart: 0, sourceEnd: 2, rate: 1, start: 2)
        var drops: [(UUID, Int)] = []
        let surface = TimelineSurface(videoURL: fixture,
            clips: [EditorSequenceClip(segment: first, url: fixture, number: 1), EditorSequenceClip(segment: second, url: fixture, number: 2)],
            selectedClipID: first.id, selectClip: { _ in }, reorderClip: { drops.append(($0, $1)) },
            feedback: EditorTimelineFeedback(), duration: 4, currentSeconds: 2, zoom: 1, events: [], selectedEventID: nil,
            trimStart: 0, trimEnd: 2, showsTrim: false, previewSeek: { _ in }, commitSeek: { _ in },
            changeZoom: { _ in }, beginTrimEdit: {}, updateTrim: { _, _ in }, selectEvent: { _ in }, updateEventWindow: { _, _, _ in })
        let viewport = TimelineViewport(configuration: surface)
        defer { viewport.stop() }
        viewport.frame = CGRect(x: 0, y: 0, width: 390, height: 180)
        viewport.layoutIfNeeded()
        let drag = TestTimelineReorder()
        drag.testState = .began; drag.testLocation = CGPoint(x: 117, y: 45)
        viewport.perform(NSSelectorFromString("reordered:"), with: drag)
        let label = try XCTUnwrap(viewport.subviews.first { $0.accessibilityIdentifier == "timeline-reorder-label" } as? UILabel)
        XCTAssertFalse(label.isHidden)
        XCTAssertEqual(label.text, "Clip 1")
        XCTAssertLessThan(label.frame.maxY, 26, "The drag label must leave the filmstrip and insertion marker uncovered")
        XCTAssertLessThanOrEqual(label.frame.height, 22)
        drag.testState = .changed; drag.testLocation = CGPoint(x: 330, y: 45)
        viewport.perform(NSSelectorFromString("reordered:"), with: drag)
        XCTAssertTrue(drops.isEmpty)
        drag.testState = .ended
        viewport.perform(NSSelectorFromString("reordered:"), with: drag)
        XCTAssertEqual(drops.count, 1)
        XCTAssertEqual(drops.first?.0, first.id)
        XCTAssertEqual(drops.first?.1, 1)
        XCTAssertTrue(label.isHidden)
    }

    @MainActor
    func testDefaultEditorShowsSelectableAndAdjustableEventsOnTimeline() async throws {
        let schema = Schema([Project.self, Recording.self, MatchEvent.self, VideoComposition.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true))
        let recording = Recording(projectID: UUID(), localPath: "event-test-\(UUID()).mp4", duration: 2)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sequence-test", withExtension: "mp4"))
        try FileManager.default.createDirectory(at: recording.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: recording.fileURL)
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        let event = MatchEvent(projectID: recording.projectID, recordingID: recording.id, kind: "Goal")
        event.offsetSeconds = 0.4; event.preRollSeconds = 0.2; event.postRollSeconds = 0.2
        container.mainContext.insert(recording); container.mainContext.insert(event)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let oldWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let second = Recording(projectID: recording.projectID, localPath: "event-test-\(UUID()).mp4", duration: 2)
        try FileManager.default.copyItem(at: fixture, to: second.fileURL)
        defer { try? FileManager.default.removeItem(at: second.fileURL) }
        let laterEvent = MatchEvent(projectID: recording.projectID, recordingID: second.id, kind: "Shot")
        laterEvent.offsetSeconds = 0.8; laterEvent.preRollSeconds = 0.2; laterEvent.postRollSeconds = 0.2
        container.mainContext.insert(second); container.mainContext.insert(laterEvent)
        let clips = [
            CompositionClip(recordingID: recording.id, startSeconds: 0, endSeconds: 2),
            CompositionClip(recordingID: second.id, startSeconds: 0, endSeconds: 2, rate: 2),
            CompositionClip(recordingID: recording.id, startSeconds: 0.2, endSeconds: 1.8)
        ]
        let occurrenceID = TimelineEventID(eventID: laterEvent.id, clipID: clips[1].id)
        let host = UIHostingController(rootView: RecordingEditorView(recording: recording, initialClips: clips).modelContainer(container))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; oldWindow?.makeKey() }
        try await Task.sleep(for: .milliseconds(700))
        host.view.layoutIfNeeded()
        let player = try XCTUnwrap(descendants(host.view).compactMap { ($0.layer as? AVPlayerLayer)?.player }.first)
        for _ in 0..<30 {
            if player.currentItem?.status == .readyToPlay, abs((player.currentItem?.duration.seconds ?? 0) - 4.6) < 0.01 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let preparedItem = try XCTUnwrap(player.currentItem)
        XCTAssertEqual(preparedItem.duration.seconds, 4.6, accuracy: 0.01)
        await player.seek(to: CMTime(seconds: 2.3, preferredTimescale: 600))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(player.currentItem === preparedItem, "Seeking across clips must not rebuild the preview")
        let scroll = try XCTUnwrap(descendants(host.view).first { $0.accessibilityLabel == "Video timeline" })
        XCTAssertFalse(descendants(host.view).contains { $0.accessibilityIdentifier == "clip-sequence-timeline" })
        let viewport = try XCTUnwrap(scroll.superview)
        let bar = try XCTUnwrap((viewport.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }.first { $0.accessibilityIdentifier == "timeline-event-\(occurrenceID)" })
        let clipElements = (viewport.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }.filter { $0.accessibilityIdentifier?.hasPrefix("timeline-clip-") == true }
        XCTAssertEqual(clipElements.count, 3, "All three clips must be visible on the same timeline")
        XCTAssertTrue(bar.accessibilityActivate())
        try await Task.sleep(for: .milliseconds(150))
        let workspaceSwitch = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UISegmentedControl }.first)
        workspaceSwitch.selectedSegmentIndex = 1; workspaceSwitch.sendActions(for: .valueChanged)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(descendants(host.view).contains { $0.accessibilityLabel == "Video timeline" })
        workspaceSwitch.selectedSegmentIndex = 0; workspaceSwitch.sendActions(for: .valueChanged)
        try await Task.sleep(for: .milliseconds(150))
        let restoredScroll = try XCTUnwrap(descendants(host.view).first { $0.accessibilityLabel == "Video timeline" })
        let restoredViewport = try XCTUnwrap(restoredScroll.superview)
        let restoredBar = try XCTUnwrap((restoredViewport.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }.first { $0.accessibilityIdentifier == "timeline-event-\(occurrenceID)" })
        XCTAssertTrue(restoredBar.accessibilityTraits.contains(.selected), "List / timeline switching must retain event selection")
        let startHandle = try XCTUnwrap(descendants(restoredViewport).first { $0.accessibilityLabel == "Event start" && !$0.isHidden })
        let endHandle = try XCTUnwrap(descendants(restoredViewport).first { $0.accessibilityLabel == "Event end" && !$0.isHidden })
        XCTAssertGreaterThan(startHandle.frame.width, 0)
        XCTAssertGreaterThan(endHandle.frame.width, 0)
        endHandle.accessibilityIncrement()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(laterEvent.postRollSeconds, 0.4, accuracy: 0.001, "A 0.1s output trim at 2× is a 0.2s source change")
        XCTAssertEqual(event.postRollSeconds, 0.2, accuracy: 0.001, "Other recordings must remain unchanged")
        XCTAssertTrue(player.currentItem === preparedItem, "Event edits must not rebuild clip playback")
        let selectedBar = try XCTUnwrap((restoredViewport.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }.first { $0.accessibilityIdentifier == "timeline-event-\(occurrenceID)" })
        XCTAssertTrue(selectedBar.accessibilityTraits.contains(.selected))
        XCTAssertTrue(selectedBar.accessibilityActivate())
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(startHandle.isHidden)
        XCTAssertTrue(endHandle.isHidden)
        let testedViewport = try XCTUnwrap(restoredViewport as? TimelineViewport)
        testedViewport.configuration.commitSeek(2.3)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(player.currentTime().seconds, 2.3, accuracy: 0.02)
        let pinch = TestTimelinePinch()
        pinch.testLocation = CGPoint(x: 60, y: 25)
        pinch.testState = .began
        restoredViewport.perform(NSSelectorFromString("pinched:"), with: pinch)
        pinch.scale = 2
        pinch.testLocation = CGPoint(x: 190, y: 25)
        pinch.testState = .changed
        restoredViewport.perform(NSSelectorFromString("pinched:"), with: pinch)
        pinch.testState = .ended
        restoredViewport.perform(NSSelectorFromString("pinched:"), with: pinch)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(player.currentTime().seconds, 2.3, accuracy: 0.02, "Pinching off center and releasing must retain the playhead")
        player.playImmediately(atRate: 1)
        let tag = MatchEvent(projectID: second.projectID, recordingID: second.id, kind: "Save")
        tag.offsetSeconds = 0.6; tag.preRollSeconds = 0.2; tag.postRollSeconds = 0.2
        container.mainContext.insert(tag); try container.mainContext.save()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(player.currentItem === preparedItem)
        XCTAssertEqual(player.timeControlStatus, .playing, "Inserting an event while playing must not pause or rebuild the video")
        player.pause()
        // Reorder the same timeline by holding a clip, then dragging it past the next clip.
        testedViewport.configuration.changeZoom(1)
        testedViewport.configuration.commitSeek(2.3)
        try await Task.sleep(for: .milliseconds(150))
        let drag = TestTimelineReorder()
        let width = testedViewport.bounds.width
        let geometry = TimelineGeometry(duration: 4.6, width: width, zoom: 1, contentInset: width * 0.1)
        drag.testLocation = CGPoint(x: geometry.x(0.7, center: 2.3), y: 45)
        drag.testState = .began
        testedViewport.perform(NSSelectorFromString("reordered:"), with: drag)
        drag.testLocation = CGPoint(x: geometry.x(4.1, center: 2.3), y: 45)
        drag.testState = .changed
        testedViewport.perform(NSSelectorFromString("reordered:"), with: drag)
        XCTAssertTrue(player.currentItem === preparedItem, "Dragging must not rebuild the preview before dropping")
        drag.testState = .ended
        testedViewport.perform(NSSelectorFromString("reordered:"), with: drag)
        for _ in 0..<40 {
            if player.currentItem !== preparedItem, player.currentItem?.status == .readyToPlay { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(testedViewport.configuration.clips.map(\.segment.id), [clips[1].id, clips[2].id, clips[0].id])
        let movedEvent = try XCTUnwrap(testedViewport.configuration.events.first { $0.id == occurrenceID })
        XCTAssertEqual(movedEvent.offset, 0.4, accuracy: 0.001, "Events must travel with their source clip")
        XCTAssertEqual(player.currentItem?.status, .readyToPlay)
        XCTAssertEqual(player.currentItem?.duration.seconds ?? 0, 4.6, accuracy: 0.01)
        let playerLayer = try XCTUnwrap(descendants(host.view).compactMap { $0.layer as? AVPlayerLayer }.first)
        for _ in 0..<30 {
            if playerLayer.isReadyForDisplay, abs(player.currentTime().seconds - 2.6) < 0.05 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(playerLayer.isReadyForDisplay, "Reordering must restore a visible video frame")
        XCTAssertEqual(player.currentTime().seconds, 2.6, accuracy: 0.05)
        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
        let attachment = XCTAttachment(image: renderer.image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) })
        attachment.name = "Three clips with aligned events on one timeline"; attachment.lifetime = .keepAlways
        add(attachment)
        player.pause()
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(150))
    }

    @MainActor
    func testSavedVideoRetainsClipIdentityAndInvalidatesOnlyChangedRender() throws {
        let schema = Schema([Project.self, Recording.self, MatchEvent.self, VideoComposition.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true))
        let clips = [CompositionClip(recordingID: UUID(), startSeconds: 2, endSeconds: 9),
                     CompositionClip(recordingID: UUID(), startSeconds: 4, endSeconds: 8, rate: 2)]
        let video = VideoComposition(projectID: UUID(), name: "Video", kind: "multi-clip", clips: clips)
        container.mainContext.insert(video); try container.mainContext.save()
        let folder = URL.documentsDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let export = folder.appending(path: video.id.uuidString).appendingPathExtension("mp4")
        try Data("test render".utf8).write(to: export)
        defer { try? FileManager.default.removeItem(at: export) }
        let firstRevision = video.renderRevision
        try video.saveEdit(clips: clips, aspectRatio: "original", name: "Renamed", context: container.mainContext)
        XCTAssertEqual(video.renderRevision, firstRevision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path()), "Renaming must preserve an existing render")
        try video.saveEdit(clips: clips.reversed(), aspectRatio: "square", name: "Renamed", context: container.mainContext)
        XCTAssertNotEqual(video.renderRevision, firstRevision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path()), "A changed edit must not show an outdated render")
        let reopenedContext = ModelContext(container)
        let reopened = try XCTUnwrap(reopenedContext.fetch(FetchDescriptor<VideoComposition>()).first)
        XCTAssertEqual(reopened.id, video.id)
        XCTAssertEqual(reopened.decodedClips, Array(clips.reversed()))
        XCTAssertEqual(reopened.aspectRatio, "square")
        XCTAssertNil(reopened.shareURL)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<VideoComposition>()), 1, "Saving an edit must update the same video")
    }

    @MainActor
    func testDeletingAnEditKeepsSourcesAndDeletingSourceOnlyRemovesItsDependents() throws {
        let schema = Schema([Project.self, Recording.self, MatchEvent.self, VideoComposition.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let first = Recording(projectID: UUID(), localPath: "metadata-only-\(UUID()).mov", duration: 2)
        let other = Recording(projectID: first.projectID, localPath: "metadata-only-\(UUID()).mov", duration: 2)
        let event = MatchEvent(projectID: first.projectID, recordingID: first.id, kind: "Goal")
        let otherEvent = MatchEvent(projectID: first.projectID, recordingID: other.id, kind: "Shot")
        let edit = VideoComposition(projectID: first.projectID, name: "Edit", kind: "multi-clip",
            clips: [CompositionClip(recordingID: first.id, startSeconds: 0, endSeconds: 1)])
        let dependent = VideoComposition(projectID: first.projectID, name: "Dependent", kind: "multi-clip",
            clips: [CompositionClip(recordingID: first.id, startSeconds: 1, endSeconds: 2)])
        let unrelated = VideoComposition(projectID: first.projectID, name: "Other", kind: "multi-clip",
            clips: [CompositionClip(recordingID: other.id, startSeconds: 0, endSeconds: 1)])
        context.insert(first); context.insert(other); context.insert(event); context.insert(otherEvent)
        context.insert(edit); context.insert(dependent); context.insert(unrelated)
        try context.save()
        try RecordingLibrary.deleteVideo(composition: edit, context: context)
        XCTAssertTrue(edit.pendingDeletion)
        XCTAssertFalse(first.pendingDeletion); XCTAssertFalse(event.pendingDeletion); XCTAssertFalse(dependent.pendingDeletion)
        try RecordingLibrary.deleteVideo(recording: first, context: context)
        XCTAssertTrue(first.pendingDeletion); XCTAssertTrue(event.pendingDeletion); XCTAssertTrue(dependent.pendingDeletion)
        XCTAssertTrue(dependent.needsSync)
        XCTAssertFalse(other.pendingDeletion); XCTAssertFalse(otherEvent.pendingDeletion); XCTAssertFalse(unrelated.pendingDeletion)
    }

    func testMissingRecordingPathsNeverResolveToTheMediaDirectory() {
        for path in ["", "/", ".", ".."] {
            let recording = Recording(projectID: UUID(), localPath: path, duration: 0)
            XCTAssertNotEqual(recording.fileURL.standardizedFileURL, URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory).standardizedFileURL)
            XCTAssertEqual(recording.fileURL.deletingLastPathComponent().standardizedFileURL,
                URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory).standardizedFileURL)
        }
        XCTAssertEqual(Recording(projectID: UUID(), localPath: "").localPath, "")
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testPreviewIdentitySurvivesEncodingAndOnlyChangesForActualEdits() throws {
        let clip = CompositionClip(recordingID: UUID(), startSeconds: 2, endSeconds: 9, rate: 1.5)
        let request = EditorSequenceRequest(clips: [clip], aspectRatio: "original", isActive: true, retry: 0)
        for _ in 0..<100 {
            let decoded = try JSONDecoder().decode([CompositionClip].self, from: JSONEncoder().encode([clip]))
            XCTAssertEqual(request, EditorSequenceRequest(clips: decoded, aspectRatio: "original", isActive: true, retry: 0))
        }
        var changed = clip; changed.endSeconds = 8
        XCTAssertNotEqual(request, EditorSequenceRequest(clips: [changed], aspectRatio: "original", isActive: true, retry: 0))
    }
}

@MainActor
private final class TestTimelinePinch: UIPinchGestureRecognizer {
    var testState: UIGestureRecognizer.State = .possible
    var testLocation = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { testState } set { testState = newValue } }
    override func location(in view: UIView?) -> CGPoint { testLocation }
}

@MainActor
private final class TestTimelineReorder: UILongPressGestureRecognizer {
    var testState: UIGestureRecognizer.State = .possible
    var testLocation = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { testState } set { testState = newValue } }
    override func location(in view: UIView?) -> CGPoint { testLocation }
}
