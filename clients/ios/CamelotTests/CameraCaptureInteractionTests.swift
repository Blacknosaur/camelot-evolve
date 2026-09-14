import AVFoundation
import SwiftData
import SwiftUI
import XCTest
@testable import Camelot

final class CameraCaptureInteractionTests: XCTestCase {
    func testZoomHasConsistentPrecisionAndRespectsHardwareLimits() {
        let scale = CameraZoomScale(minimum: 0.5, maximum: 6)
        XCTAssertEqual(scale.dragging(from: 1, translation: -180 * log(2)), 2, accuracy: 0.001)
        XCTAssertEqual(scale.dragging(from: 2, translation: 180 * log(2)), 1, accuracy: 0.001)
        XCTAssertEqual(scale.dragging(from: 1, translation: -10000), 6)
        XCTAssertEqual(scale.dragging(from: 1, translation: 10000), 0.5)
        XCTAssertEqual(CameraZoomScale(minimum: 1, maximum: 3).stops, [1, 2, 3])
    }

    @MainActor
    func testOverlappingCountdownsAndEarlyEndPersistIndependently() throws {
        let schema = Schema([Project.self, Recording.self, MatchEvent.self, VideoComposition.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let recordingID = UUID()
        let capture = CameraEventCapture()
        let shot = event(recordingID: recordingID, kind: .shot, offset: 10)
        let goal = event(recordingID: recordingID, kind: .goal, offset: 12)
        container.mainContext.insert(shot); container.mainContext.insert(goal)
        capture.add(shot); capture.add(goal)
        XCTAssertEqual(capture.endOffset(for: recordingID), 20, "A shorter new event must not cut off an earlier window")
        capture.advance(recordingID: recordingID, offset: 14)
        XCTAssertEqual(capture.remaining(for: goal), 3)
        XCTAssertEqual(capture.remaining(for: shot), 6)
        XCTAssertTrue(capture.endNow(eventID: goal.id, recordingID: recordingID, offset: 14.5))
        XCTAssertEqual(goal.postRollSeconds, 2.5)
        XCTAssertEqual(shot.postRollSeconds, 10)
        XCTAssertEqual(capture.endOffset(for: recordingID), 20)
        XCTAssertEqual(capture.selected?.id, shot.id)
        try container.mainContext.save()
        let saved = try ModelContext(container).fetch(FetchDescriptor<MatchEvent>())
        XCTAssertEqual(saved.first { $0.id == goal.id }?.postRollSeconds, 2.5)
        capture.advance(recordingID: recordingID, offset: 20)
        XCTAssertTrue(capture.active.isEmpty)
        XCTAssertFalse(capture.endNow(eventID: shot.id, recordingID: recordingID, offset: 22))
        XCTAssertEqual(shot.postRollSeconds, 10, "An expired window must not grow")
    }

    @MainActor
    func testCountdownUsesMediaClockAndClosesOnInterruption() {
        let recordingID = UUID()
        let capture = CameraEventCapture()
        let goal = event(recordingID: recordingID, kind: .goal, offset: 4)
        capture.add(goal)
        capture.advance(recordingID: UUID(), offset: 100)
        XCTAssertEqual(capture.remaining(for: goal), 5, "A new segment must not advance the old segment's countdown")
        capture.advance(recordingID: recordingID, offset: 5)
        capture.advance(recordingID: recordingID, offset: 5)
        XCTAssertEqual(capture.remaining(for: goal), 4)
        capture.finishSegment(id: recordingID, duration: 6.25)
        XCTAssertEqual(goal.postRollSeconds, 2.25)
        XCTAssertTrue(capture.active.isEmpty)
    }

    @MainActor
    func testEarlyEndOnPhysicalCameraPreservesFullRecordingAndOtherReplayEvents() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw XCTSkip("Camera permissions required") }
        let recorder = CameraRecorder()
        let projectID = UUID()
        do {
            await recorder.prepare(quality: .efficient)
            XCTAssertTrue(recorder.isReady)
            recorder.start(projectID: projectID, mode: .full)
            try await waitUntil { recorder.canMarkEvent && recorder.currentOffset >= 0.3 }
            let fullID = try XCTUnwrap(recorder.activeSegmentID)
            let capture = CameraEventCapture()
            let fullEvent = event(recordingID: fullID, kind: .goal, offset: recorder.currentOffset)
            capture.add(fullEvent)
            try await waitUntil { recorder.currentOffset >= fullEvent.offsetSeconds + 0.5 }
            if recorder.supportsPause {
                recorder.togglePause()
                try await waitUntil { recorder.isPaused && !recorder.isChangingPause }
                let pausedOffset = recorder.currentOffset
                capture.advance(recordingID: fullID, offset: pausedOffset)
                let remaining = capture.remaining(for: fullEvent)
                try await Task.sleep(for: .milliseconds(600))
                capture.advance(recordingID: fullID, offset: recorder.currentOffset)
                XCTAssertEqual(recorder.currentOffset, pausedOffset, accuracy: 0.05)
                XCTAssertEqual(capture.remaining(for: fullEvent), remaining, accuracy: 0.05)
                XCTAssertFalse(recorder.canMarkEvent)
                XCTAssertTrue(recorder.isRecording)
                recorder.togglePause()
                try await waitUntil { recorder.canMarkEvent }
                try await waitUntil { recorder.currentOffset > pausedOffset + 0.2 }
                XCTAssertEqual(recorder.activeSegmentID, fullID, "Resume must continue the same file")
            }
            XCTAssertTrue(capture.endNow(eventID: fullEvent.id, recordingID: fullID, offset: recorder.currentOffset))
            XCTAssertLessThan(fullEvent.postRollSeconds, 1.5)
            XCTAssertTrue(recorder.isRecording, "Ending an event must not stop full-video capture")
            if recorder.supportsPause {
                recorder.togglePause()
                try await waitUntil { recorder.isPaused }
            }
            recorder.stop(reason: "user")
            try await waitUntil { !recorder.isRecording }
            XCTAssertFalse(recorder.isPaused)
            XCTAssertTrue(recorder.completedSegments.contains { $0.id == fullID })

            recorder.start(projectID: projectID, mode: .rolling5)
            try await waitUntil { recorder.canMarkEvent && recorder.currentOffset >= 0.3 }
            let replayID = try XCTUnwrap(recorder.activeSegmentID)
            let shot = event(recordingID: replayID, kind: .shot, offset: recorder.currentOffset)
            capture.add(shot)
            _ = recorder.promoteRollingBuffer(until: try XCTUnwrap(capture.endOffset(for: replayID)))
            try await waitUntil { recorder.currentOffset >= shot.offsetSeconds + 0.3 }
            let goal = event(recordingID: replayID, kind: .goal, offset: recorder.currentOffset)
            capture.add(goal)
            _ = recorder.promoteRollingBuffer(until: try XCTUnwrap(capture.endOffset(for: replayID)))
            try await waitUntil { recorder.currentOffset >= goal.offsetSeconds + 0.3 }
            XCTAssertTrue(capture.endNow(eventID: goal.id, recordingID: replayID, offset: recorder.currentOffset))
            recorder.endRollingEventCapture(until: capture.endOffset(for: replayID))
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(recorder.activeSegmentID, replayID, "The other event still needs its post-roll")
            XCTAssertTrue(capture.endNow(eventID: shot.id, recordingID: replayID, offset: recorder.currentOffset))
            recorder.endRollingEventCapture(until: capture.endOffset(for: replayID))
            try await waitUntil { recorder.activeSegmentID != replayID && recorder.canMarkEvent }
            XCTAssertTrue(recorder.completedSegments.contains { $0.id == replayID })
            XCTAssertTrue(recorder.isRecording, "Finishing the final event must resume the replay buffer")
        } catch {
            await cleanUp(recorder: recorder, projectID: projectID)
            throw error
        }
        await cleanUp(recorder: recorder, projectID: projectID)
    }

    @MainActor
    func testCountdownOverlayFitsAboveThePreview() async throws {
        let capture = CameraEventCapture()
        let recordingID = UUID()
        capture.add(event(recordingID: recordingID, kind: .shot, offset: 10))
        capture.add(event(recordingID: recordingID, kind: .goal, offset: 12))
        capture.advance(recordingID: recordingID, offset: 14)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let oldWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; oldWindow?.makeKey() }
        let host = UIHostingController(rootView: CameraEventCountdown(capture: capture, canEnd: true, end: { _ in })
            .preferredColorScheme(.dark))
        host.safeAreaRegions = []
        window.rootViewController = host; window.makeKeyAndVisible()
        let size = host.sizeThatFits(in: CGSize(width: 360, height: 200))
        XCTAssertLessThanOrEqual(size.height, 64)
        try await Task.sleep(for: .milliseconds(150))
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
        let attachment = XCTAttachment(image: renderer.image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) })
        attachment.name = "Two overlapping events — countdown and end now"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func event(recordingID: UUID, kind: EventKind, offset: Double) -> MatchEvent {
        let event = MatchEvent(projectID: UUID(), recordingID: recordingID, kind: kind.rawValue)
        event.offsetSeconds = offset; event.postRollSeconds = kind.defaultPostRoll
        return event
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Camera state did not settle within 10 seconds")
        throw CocoaError(.validationMissingMandatoryProperty)
    }

    @MainActor private func cleanUp(recorder: CameraRecorder, projectID: UUID) async {
        if recorder.isRecording { recorder.stop(reason: "user") }
        try? await waitUntil { !recorder.isRecording }
        recorder.shutdown()
        let files = (try? FileManager.default.contentsOfDirectory(at: RecordingRecovery.directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let journal = try? JSONDecoder().decode(CaptureJournal.self, from: data),
                  journal.projectID == projectID else { continue }
            RecordingRecovery.discard(journal)
        }
    }
}
