import XCTest
@testable import Camelot

final class TimelineGeometryTests: XCTestCase {
    func testDrawingEdgesCrossMidpointButStayInsideClip() {
        let drawing = TimelineEventSnapshot(offset: 5, preRoll: 3, postRoll: 3, kind: "✎ Polygon", lowerBound: 1, upperBound: 10, isDrawing: true)
        XCTAssertEqual(drawing.resizing(7, start: 2, end: 8, leading: true, duration: 20).0, 7)
        XCTAssertEqual(drawing.resizing(3, start: 2, end: 8, leading: false, duration: 20).1, 3)
        XCTAssertEqual(drawing.resizing(-10, start: 2, end: 8, leading: true, duration: 20).0, 1)
        XCTAssertEqual(drawing.resizing(30, start: 2, end: 8, leading: false, duration: 20).1, 10)
        XCTAssertEqual(drawing.resizing(9, start: 2, end: 8, leading: true, duration: 20).0, 8 - 1 / 30, accuracy: 0.00001)
        XCTAssertEqual(drawing.resizing(0, start: 2, end: 8, leading: false, duration: 20).1, 2 + 1 / 30, accuracy: 0.00001)
        let moved = TimelineEventSnapshot(offset: 5, preRoll: -2, postRoll: 3, kind: drawing.kind, isDrawing: true)
        XCTAssertEqual(moved.start, 7, "Signed roll transports drawing edges past the old midpoint")
        XCTAssertEqual(moved.end, 8)
    }

    func testEventEdgesStillContainMarkerAndLockedDrawingsCannotResize() {
        let event = TimelineEventSnapshot(offset: 5, preRoll: 3, postRoll: 3, kind: "Goal")
        XCTAssertEqual(event.resizing(7, start: 2, end: 8, leading: true, duration: 20).0, 5)
        XCTAssertEqual(event.resizing(3, start: 2, end: 8, leading: false, duration: 20).1, 5)
        var drawing = event; drawing.isDrawing = true; drawing.isLocked = true
        XCTAssertEqual(drawing.resizing(7, start: 2, end: 8, leading: true, duration: 20).0, 2)
        XCTAssertEqual(drawing.resizing(3, start: 2, end: 8, leading: false, duration: 20).1, 8)
    }

    func testInspectionPanClampsWithoutExposingBlackEdges() {
        XCTAssertEqual(AnnotationViewport.inspectionCenter(.init(x: -2, y: 4), zoom: 2), CGPoint(x: 0.25, y: 0.75))
        XCTAssertEqual(AnnotationViewport.inspectionCenter(.init(x: 0.4, y: 0.6), zoom: 2), CGPoint(x: 0.4, y: 0.6))
        XCTAssertEqual(AnnotationViewport.inspectionCenter(.init(x: 0.1, y: 0.9), zoom: 1), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(AnnotationViewport.inspectionCenter(.init(x: 0.1, y: 0.9), zoom: 0.25), CGPoint(x: 0.5, y: 0.5))
    }

    func testOffscreenFieldCornersRemainEditableBelowOneTimes() throws {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 100)
        let outside = CGPoint(x: 50, y: 230)
        XCTAssertEqual(AnnotationViewport.sourcePoint(outside, frame: frame), CGPoint(x: 0, y: 1))
        XCTAssertEqual(AnnotationViewport.sourcePoint(outside, frame: frame, allowsOffscreen: true), CGPoint(x: -0.25, y: 1.3))
        let corners: [CGPoint] = [.init(x: -0.4, y: -0.1), .init(x: 1.4, y: -0.1), .init(x: 1.8, y: 1.5), .init(x: -0.8, y: 1.5)]
        XCTAssertNotNil(AnalysisFieldGuide.projection(corners: corners))
        var guide = AnalysisAnnotation(tool: .zone, points: corners, start: 0, end: 5)
        guide.fieldLines = true
        let changed = guide.reshaped(at: 1, handle: 3, delta: .init(width: -0.1, height: 0.2))
        XCTAssertEqual(changed[3].x, -0.9, accuracy: 0.0001)
        XCTAssertEqual(changed[3].y, 1.7, accuracy: 0.0001)
    }

    func testAspectRatioLabelsHandleOrientationAndEncoderRounding() {
        XCTAssertEqual(videoAspectRatioLabel(CGSize(width: 1080, height: 1920)), "9:16")
        XCTAssertEqual(videoAspectRatioLabel(CGSize(width: 1920, height: 1080)), "16:9")
        XCTAssertEqual(videoAspectRatioLabel(CGSize(width: 1080, height: 1080)), "1:1")
        XCTAssertEqual(videoAspectRatioLabel(CGSize(width: 1920, height: 1082)), "16:9")
        XCTAssertEqual(videoAspectRatioLabel(.zero), "…")
    }

    func testCoordinatesRoundTripAtEveryZoom() {
        for duration in [0.1, 15, 7200.0] {
            for zoom in [1.0, 4, max(1, duration / 2)] {
                let geometry = TimelineGeometry(duration: duration, width: 390, zoom: zoom)
                for time in [0, duration / 3, duration] {
                    XCTAssertEqual(geometry.seconds(geometry.x(time, center: duration / 2), center: duration / 2), time, accuracy: 0.00001)
                }
            }
        }
    }

    func testTrimCannotCrossOrLeaveRecording() {
        let start = TimelineGeometry.trim(12, start: 2, end: 10, duration: 20, leading: true)
        XCTAssertEqual(start.0, 9.9, accuracy: 0.0001)
        let end = TimelineGeometry.trim(-20, start: 2, end: 10, duration: 20, leading: false)
        XCTAssertEqual(end.1, 2.1, accuracy: 0.0001)
        XCTAssertEqual(TimelineGeometry.trim(-20, start: 2, end: 10, duration: 20, leading: true).0, 0)
        XCTAssertEqual(TimelineGeometry.trim(100, start: 2, end: 10, duration: 20, leading: false).1, 20)
    }

    func testVeryShortRecordingHasValidTrimBounds() {
        let range = TimelineGeometry.trim(0, start: 0, end: 0.04, duration: 0.04, leading: false)
        XCTAssertEqual(range.0, 0)
        XCTAssertEqual(range.1, 0.04)
    }

    func testRulerWorkIsBoundedForLongRecordings() {
        for width in [320.0, 1024, 1366] {
            for zoom in [1.0, 10, 3600] {
                let geometry = TimelineGeometry(duration: 7200, width: width, zoom: zoom)
                let visibleDuration = Double(width / geometry.pointsPerSecond)
                XCTAssertLessThanOrEqual(visibleDuration / geometry.tickInterval, width / 72 + 1)
                XCTAssertLessThanOrEqual(visibleDuration / geometry.subdivisionInterval, width / 12 + 1)
                XCTAssertEqual((geometry.tickInterval / geometry.subdivisionInterval).rounded(), geometry.tickInterval / geometry.subdivisionInterval, accuracy: 0.001)
            }
        }
    }

    func testOffCenterPinchPreservesTimeUnderFingers() {
        let before = TimelineGeometry(duration: 600, width: 400, zoom: 2)
        let anchor = before.seconds(280, center: 300)
        let after = TimelineGeometry(duration: 600, width: 400, zoom: 8)
        let newCenter = anchor - Double((280 - 200) / after.pointsPerSecond)
        XCTAssertEqual(after.seconds(280, center: newCenter), anchor, accuracy: 0.0001)
    }

    func testTimecodeCarriesRoundedTenthsAcrossMinute() {
        XCTAssertEqual(timelineTimecode(59.99, includesTenths: true), "1:00.0")
        XCTAssertEqual(timelineTimecode(.nan, includesTenths: true), "0:00.0")
    }
}

final class EditorWorkspaceTests: XCTestCase {
    func testPanelsAlwaysFitAndRetainUsableSpace() {
        for height in [350.0, 600, 760, 1024] {
            for request in [100.0, 240, 600] {
                let sizes = EditorPanelSizes(height: height, workspace: request)
                XCTAssertEqual(sizes.preview + sizes.workspace + 20, height, accuracy: 0.01)
                XCTAssertGreaterThan(sizes.preview, 0)
                XCTAssertGreaterThan(sizes.workspace, 0)
            }
        }
    }

    func testExpandingWorkspaceTakesSpaceFromOtherPanels() {
        let before = EditorPanelSizes(height: 800, workspace: 224)
        let after = EditorPanelSizes(height: 800, workspace: 350)
        XCTAssertGreaterThan(after.workspace, before.workspace)
        XCTAssertLessThan(after.preview, before.preview)
    }

    func testEventsUseFullWindowsForOverlap() {
        let first = TimelineEventSnapshot(offset: 20, preRoll: 15, postRoll: 5, kind: "Goal")
        let second = TimelineEventSnapshot(offset: 30, preRoll: 10, postRoll: 10, kind: "Shot")
        let third = TimelineEventSnapshot(offset: 50, preRoll: 5, postRoll: 5, kind: "Save")
        let laidOut = TimelinePlacedEvent.layout([third, second, first])
        XCTAssertEqual(first.start, 5)
        XCTAssertEqual(first.end, 25)
        XCTAssertNotEqual(laidOut.first { $0.event.id == first.id }?.row, laidOut.first { $0.event.id == second.id }?.row)
        XCTAssertEqual(laidOut.first { $0.event.id == third.id }?.row, 0)
    }

    func testHundredsOfOverlappingWindowsRemainDistinct() {
        let events = (0..<240).map { TimelineEventSnapshot(offset: Double($0) / 100, preRoll: 10, postRoll: 10, kind: "Goal") }
        let placed = TimelinePlacedEvent.layout(events)
        XCTAssertEqual(Set(placed.map(\.row)).count, 240)
        XCTAssertEqual(placed, TimelinePlacedEvent.layout(events.reversed()))
    }

    func test4KQualityMapsToActual4KPreset() {
        XCTAssertEqual(CaptureQuality.ultraHD.preset, .hd4K3840x2160)
        XCTAssertEqual(CaptureQuality.actual(for: .hd4K3840x2160), .ultraHD)
        XCTAssertEqual(CaptureQuality.actual(for: .hd1920x1080), .hd)
        XCTAssertNil(CaptureQuality.actual(for: .photo))
    }
}

final class EditorSequenceTests: XCTestCase {
    func testSequenceMappingHonorsTrimsAndSpeed() {
        let first = EditorSequenceSegment(id: UUID(), sourceStart: 5, sourceEnd: 15, rate: 2, start: 0)
        let second = EditorSequenceSegment(id: UUID(), sourceStart: 3, sourceEnd: 7, rate: 0.5, start: first.end)
        XCTAssertEqual(first.duration, 5)
        XCTAssertEqual(second.end, 13)
        XCTAssertEqual(first.sourceTime(at: 2), 9)
        XCTAssertEqual(second.sourceTime(at: 9), 5)
        XCTAssertEqual(second.outputTime(at: 5), 9)
        XCTAssertEqual(EditorSequenceSegment.containing(5, in: [first, second])?.id, second.id)
        XCTAssertEqual(EditorSequenceSegment.containing(13, in: [first, second])?.id, second.id)
    }

    func testSourceAndOutputTimesRoundTripAcrossClips() {
        for rate in [0.5, 1, 1.5, 2.0] {
            let segment = EditorSequenceSegment(id: UUID(), sourceStart: 12, sourceEnd: 42, rate: rate, start: 23)
            for source in [12.0, 18, 33, 42] {
                XCTAssertEqual(segment.sourceTime(at: segment.outputTime(at: source)), source, accuracy: 0.0001)
            }
            XCTAssertEqual(segment.sourceTime(at: -100), 12)
            XCTAssertEqual(segment.sourceTime(at: 1000), 42)
        }
    }

    func testFitEntireRangeHasSpaceOnBothSides() {
        let geometry = TimelineGeometry(duration: 20, width: 400, zoom: 1, contentInset: 40)
        XCTAssertEqual(geometry.x(0, center: 10), 40, accuracy: 0.001)
        XCTAssertEqual(geometry.x(20, center: 10), 360, accuracy: 0.001)
        XCTAssertEqual(geometry.seconds(40, center: 10), 0, accuracy: 0.001)
    }
}

final class EditorEventMappingTests: XCTestCase {
    func testSplitJoinsTheFullEventWindowAndKeepsOneMarker() throws {
        let source = TimelineEventSnapshot(offset: 12, preRoll: 4, postRoll: 6, kind: "Goal")
        for rate in [0.5, 1, 2.0] {
            for cut in [9.0, 12, 16] {
                let first = EditorSequenceSegment(id: UUID(), sourceStart: 0, sourceEnd: cut, rate: rate, start: 7)
                let second = EditorSequenceSegment(id: UUID(), sourceStart: cut, sourceEnd: 20, rate: rate, start: first.end)
                let before = try XCTUnwrap(first.eventSnapshot(source))
                let after = try XCTUnwrap(second.eventSnapshot(source))
                let joined = try XCTUnwrap(before.joiningContinuousWindow(after))
                XCTAssertEqual(joined.start, 7 + 8 / rate, accuracy: 0.0001)
                XCTAssertEqual(joined.end, 7 + 18 / rate, accuracy: 0.0001)
                XCTAssertEqual(joined.offset, 7 + 12 / rate, accuracy: 0.0001)
                XCTAssertEqual(joined.id.clipID, cut <= source.offset ? second.id : first.id)
                XCTAssertEqual(joined.lowerBound, 7)
                XCTAssertEqual(joined.upperBound, second.end)
            }
        }
    }

    func testSeparatedRepeatedAndTrimmedEventPiecesDoNotBridgeMissingFootage() throws {
        let source = TimelineEventSnapshot(offset: 10, preRoll: 8, postRoll: 8, kind: "Goal")
        let first = EditorSequenceSegment(id: UUID(), sourceStart: 0, sourceEnd: 10, rate: 1, start: 0)
        let before = try XCTUnwrap(first.eventSnapshot(source))
        for second in [
            EditorSequenceSegment(id: UUID(), sourceStart: 10, sourceEnd: 20, rate: 1, start: 15),
            EditorSequenceSegment(id: UUID(), sourceStart: 12, sourceEnd: 20, rate: 1, start: 10),
            EditorSequenceSegment(id: UUID(), sourceStart: 0, sourceEnd: 10, rate: 1, start: 10),
            EditorSequenceSegment(id: UUID(), sourceStart: 10, sourceEnd: 20, rate: 2, start: 10)
        ] {
            let after = try XCTUnwrap(second.eventSnapshot(source))
            XCTAssertNil(before.joiningContinuousWindow(after))
        }
    }

    func testMultipleCutsKeepOneListEntryAndDistinctEventsStayDistinct() throws {
        let recordingID = UUID()
        let event = MatchEvent(projectID: UUID(), recordingID: recordingID, kind: "Goal")
        let otherEvent = MatchEvent(projectID: event.projectID, recordingID: recordingID, kind: "Shot")
        let source = TimelineEventSnapshot(id: TimelineEventID(eventID: event.id), offset: 10, preRoll: 8, postRoll: 8, kind: "Goal")
        let other = TimelineEventSnapshot(id: TimelineEventID(eventID: otherEvent.id), offset: 10, preRoll: 8, postRoll: 8, kind: "Shot")
        var pieces: [EditorSequenceEvent] = []
        for index in 0..<4 {
            let segment = EditorSequenceSegment(id: UUID(), sourceStart: Double(index * 5), sourceEnd: Double((index + 1) * 5), rate: 1, start: Double(index * 5))
            for (model, snapshot) in [(event, source), (otherEvent, other)] {
                pieces.append(EditorSequenceEvent(event: model, clipNumbers: (index + 1)...(index + 1), snapshot: try XCTUnwrap(segment.eventSnapshot(snapshot))))
            }
        }
        let joined = EditorSequenceEvent.joiningContinuousWindows(pieces)
        XCTAssertEqual(joined.count, 2)
        XCTAssertEqual(joined.map(\.clipLabel), ["Clips 1–4", "Clips 1–4"])
        XCTAssertEqual(joined.map(\.snapshot.start), [2, 2])
        XCTAssertEqual(joined.map(\.snapshot.end), [18, 18])
    }

    func testEventMappingIncludesSpeedAndOutputOffset() throws {
        let source = TimelineEventSnapshot(offset: 12, preRoll: 4, postRoll: 6, kind: "Goal")
        let clip = EditorSequenceSegment(id: UUID(), sourceStart: 8, sourceEnd: 20, rate: 2, start: 30)
        let event = try XCTUnwrap(clip.eventSnapshot(source))
        XCTAssertEqual(event.offset, 32)
        XCTAssertEqual(event.start, 30)
        XCTAssertEqual(event.end, 35)
        XCTAssertEqual(event.id.eventID, source.id.eventID)
        XCTAssertEqual(event.id.clipID, clip.id)
    }

    func testSplitWindowsRemainVisibleOnBothSidesOfCut() throws {
        let source = TimelineEventSnapshot(offset: 12, preRoll: 4, postRoll: 6, kind: "Goal")
        let first = EditorSequenceSegment(id: UUID(), sourceStart: 0, sourceEnd: 10, rate: 1, start: 0)
        let second = EditorSequenceSegment(id: UUID(), sourceStart: 10, sourceEnd: 20, rate: 1, start: 10)
        let before = try XCTUnwrap(first.eventSnapshot(source))
        let after = try XCTUnwrap(second.eventSnapshot(source))
        XCTAssertEqual(before.start, 8); XCTAssertEqual(before.end, 10)
        XCTAssertEqual(after.start, 10); XCTAssertEqual(after.end, 18)
        XCTAssertNotEqual(before.id, after.id)
        XCTAssertEqual(before.id.eventID, after.id.eventID)
    }

    func testRepeatedClipKeepsSeparateEventOccurrences() throws {
        let source = TimelineEventSnapshot(offset: 2, preRoll: 1, postRoll: 1, kind: "Shot")
        let first = EditorSequenceSegment(id: UUID(), sourceStart: 0, sourceEnd: 4, rate: 1, start: 0)
        let repeatClip = EditorSequenceSegment(id: UUID(), sourceStart: 0, sourceEnd: 4, rate: 1, start: 4)
        let before = try XCTUnwrap(first.eventSnapshot(source))
        let after = try XCTUnwrap(repeatClip.eventSnapshot(source))
        XCTAssertNotEqual(before.id, after.id)
        XCTAssertEqual(after.offset - before.offset, 4)
        let removed = EditorSequenceSegment(id: UUID(), sourceStart: 5, sourceEnd: 8, rate: 1, start: 0)
        XCTAssertNil(removed.eventSnapshot(source))
    }
}
