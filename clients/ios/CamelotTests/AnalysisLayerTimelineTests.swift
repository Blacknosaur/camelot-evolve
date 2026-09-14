import XCTest
@testable import Camelot

final class AnalysisLayerTimelineTests: XCTestCase {
    func testShapeHandlesResizeCornersAndEndpointsAtCurrentKeyframe() {
        for tool in [AnalysisDrawingTool.rectangle, .ellipse, .spotlight, .player] {
            var mark = AnalysisAnnotation(tool: tool, points: [.init(x: 0.2, y: 0.3), .init(x: 0.6, y: 0.7)], start: 0, end: 4)
            XCTAssertEqual(mark.editHandles(at: 0).count, 4)
            mark.enableKeyframes(at: 0)
            let moved = mark.reshaped(at: 2, handle: 1, delta: .init(width: 0.1, height: -0.1))
            mark.moveDrawing(to: moved, at: 2)
            XCTAssertEqual(mark.points(at: 0)[0].y, 0.3, accuracy: 0.0001)
            XCTAssertEqual(mark.points(at: 2)[0].x, 0.2, accuracy: 0.0001)
            XCTAssertEqual(mark.points(at: 2)[0].y, 0.2, accuracy: 0.0001)
            XCTAssertEqual(mark.points(at: 2)[1].x, 0.7, accuracy: 0.0001)
            XCTAssertEqual(mark.points(at: 2)[1].y, 0.7, accuracy: 0.0001)
        }
        let arrow = drawing()
        let moved = arrow.reshaped(at: 2, handle: 1, delta: .init(width: 0.1, height: 0.1))
        XCTAssertEqual(moved.first, arrow.points.first)
        XCTAssertEqual(moved.last?.x ?? 0, 0.5, accuracy: 0.0001)
    }

    func testPolygonTopologyEditsPreserveKeyframeIDsAndOtherVertices() throws {
        var mark = AnalysisAnnotation(tool: .zone, points: [.init(x: 0.1, y: 0.1), .init(x: 0.9, y: 0.1), .init(x: 0.7, y: 0.8)], start: 0, end: 4)
        mark.enableKeyframes(at: 2)
        let original = mark, ids = mark.keyframes.map(\.id)
        mark.insertPolygonCorner(after: 0)
        XCTAssertEqual(mark.points.count, 4)
        XCTAssertEqual(mark.points[1], CGPoint(x: 0.5, y: 0.1))
        XCTAssertEqual(mark.keyframes.map(\.points.count), [4, 4])
        XCTAssertEqual(mark.keyframes.map(\.id), ids)
        mark.removePolygonCorner(at: 1)
        XCTAssertEqual(mark, original)
        mark.removePolygonCorner(at: 0)
        XCTAssertEqual(mark, original, "A polygon must keep at least three corners")
        mark.isLocked = true; let locked = mark; mark.insertPolygonCorner(after: 0)
        XCTAssertEqual(mark, locked)
        XCTAssertEqual(AnalysisDrawingTool.zone.rawValue, "zone", "Existing areas remain decodable")
    }

    func testTimedZoomEasesClampsEdgesAndSurvivesTimelineEdits() throws {
        var zoom = AnalysisAnnotation(tool: .zoom, points: [.init(x: 0.75, y: 0.5)], start: 2, end: 6)
        zoom.zoomScale = 2; zoom.zoomRamp = 0.4
        let frame = CGRect(x: 0, y: 50, width: 400, height: 200)
        func transform(_ time: Double, _ marks: [AnalysisAnnotation]? = nil) -> CGAffineTransform {
            AnnotationViewport.transform(marks: marks ?? [zoom], time: time, frame: frame, bounds: frame)
        }
        XCTAssertEqual(transform(1), .identity); XCTAssertEqual(transform(2), .identity); XCTAssertEqual(transform(6), .identity)
        XCTAssertEqual(transform(2.2).a, 1.5, accuracy: 0.0001)
        XCTAssertEqual(CGPoint(x: 300, y: 150).applying(transform(3)), CGPoint(x: 200, y: 150))
        zoom.points = [.init(x: 1, y: 1)]
        XCTAssertTrue(frame.applying(transform(3)).contains(frame), "Never expose black edges")
        var hidden = zoom; hidden.zoomScale = 4; hidden.isHidden = true
        XCTAssertEqual(transform(3, [zoom, hidden]), transform(3))
        hidden.isHidden = false
        XCTAssertEqual(transform(3, [zoom, hidden]).a, 4, "Topmost active zoom wins")
        zoom = zoom.applying(.move(2), within: 0...10).applying(.trimEnd(9), within: 0...10)
        XCTAssertEqual(zoom.start, 4); XCTAssertEqual(zoom.end, 9)
        XCTAssertEqual(zoom, try JSONDecoder().decode(AnalysisAnnotation.self, from: JSONEncoder().encode(zoom)))
    }

    func testTrackingSmoothingReducesJitterWithoutTrailingOrChangingRawSamples() throws {
        let samples: [PlayerMotionSample] = (0...120).map { i in
            let time = Double(i) / 60, jitter = i.isMultiple(of: 2) ? 0.006 : -0.006
            return .init(time: time, box: .init(x: 0.1 + time * 0.1 + jitter, y: 0.3, width: 0.05, height: 0.12 + jitter))
        }
        var motion = PlayerMotion(samples: samples)
        var rawError = 0.0, smoothError = 0.0
        for i in 12...108 {
            let sample = samples[i], ideal = 0.125 + sample.time * 0.1
            rawError += pow(sample.box.midX - ideal, 2)
            smoothError += pow(try XCTUnwrap(motion.box(at: sample.time)).midX - ideal, 2)
        }
        XCTAssertLessThan(smoothError, rawError * 0.25)
        XCTAssertEqual(motion.samples, samples)
        XCTAssertEqual(motion.box(at: 0), samples.first?.box, "Keep the authored seed exact")
        motion.smoothing = 0
        XCTAssertEqual(motion.box(at: samples[30].time), samples[30].box)
        motion.samples = samples.map { sample in var clean = sample; clean.box.origin.x = 0.1 + sample.time * 0.1; return clean }
        motion.smoothing = 1
        XCTAssertEqual(try XCTUnwrap(motion.box(at: 1)).midX, 0.225, accuracy: 0.00001, "A steady run should not lag")
        XCTAssertEqual(motion, try JSONDecoder().decode(PlayerMotion.self, from: JSONEncoder().encode(motion)))
    }

    func testSmoothingNeverBlendsAcrossARecoveryGap() throws {
        var motion = PlayerMotion(samples: (0...60).map { i in
            .init(time: Double(i) / 60, box: .init(x: i < 30 ? 0.1 : 0.8, y: 0.2, width: 0.05, height: 0.1))
        }, lostAt: 0.9, gaps: [0.48...0.52], smoothing: 1)
        XCTAssertNil(motion.box(at: 0.5)); XCTAssertNil(motion.box(at: 0.95))
        XCTAssertEqual(try XCTUnwrap(motion.box(at: 28.0 / 60)).minX, 0.1, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(motion.box(at: 32.0 / 60)).minX, 0.8, accuracy: 0.00001)
        motion.smoothing = 0
        XCTAssertNil(motion.box(at: 0.5), "Disabling smoothing cannot unhide lost tracking")
    }

    private func drawing() -> AnalysisAnnotation {
        AnalysisAnnotation(tool: .arrow, points: [.init(x: 0.2, y: 0.3), .init(x: 0.4, y: 0.3)], start: 2, end: 6)
    }

    func testMovingLayerMovesAuthoredKeyframesAndPreservesIdentity() {
        var mark = drawing(); mark.enableKeyframes(at: 4)
        let moved = mark.applying(.move(3), within: 0...10)
        XCTAssertEqual(moved.start, 5); XCTAssertEqual(moved.end, 9)
        XCTAssertEqual(moved.keyframes.map(\.time), [5, 7])
        XCTAssertEqual(moved.keyframes.map(\.id), mark.keyframes.map(\.id))
        let clamped = moved.applying(.move(99), within: 0...10)
        XCTAssertEqual(clamped.end, 10); XCTAssertEqual(clamped.start, 6)
    }

    func testTrimmingPreservesAnimationOutsideTrimForLaterExtension() {
        var mark = drawing(); mark.enableKeyframes(at: 4)
        let trimmed = mark.applying(.trimStart(3), within: 0...10).applying(.trimEnd(3.5), within: 0...10)
        XCTAssertEqual(trimmed.start, 3); XCTAssertEqual(trimmed.end, 3.5)
        XCTAssertEqual(trimmed.keyframes, mark.keyframes)
        XCTAssertGreaterThan(trimmed.applying(.trimEnd(-1), within: 0...10).end, trimmed.start)
    }

    func testKeyframeDragClampsBetweenNeighboursAndPositionEditKeepsID() {
        var mark = drawing(); mark.enableKeyframes(at: 4); mark.setKeyframe(at: 5, points: [.init(x: 0.8, y: 0.7)])
        let id = mark.keyframes[1].id
        let moved = mark.applying(.keyframe(id, 20), within: 0...10)
        XCTAssertLessThan(moved.keyframes[1].time, 5)
        XCTAssertEqual(moved.keyframes[1].id, id)
        mark.setKeyframe(at: 4, points: [.init(x: 0.7, y: 0.6)])
        XCTAssertEqual(mark.keyframes[1].id, id)
    }

    func testPlayerSamplesNeverMoveOntoUnrelatedSourceFrames() {
        var mark = drawing()
        mark.playerMotion = .init(samples: [.init(time: 2, box: .init(x: 0.2, y: 0.3, width: 0.1, height: 0.2)), .init(time: 6, box: .init(x: 0.4, y: 0.4, width: 0.1, height: 0.2))])
        let moved = mark.applying(.move(2), within: 0...10)
        XCTAssertEqual(moved.start, 4); XCTAssertEqual(moved.playerMotion, mark.playerMotion)
        XCTAssertEqual(mark.applying(.move(-2), within: 0...10).start, 0)
        let earlier = mark.applying(.trimStart(0), within: 0...10)
        XCTAssertEqual(earlier.start, 0, "Layer In is independent of the tracking seed")
        XCTAssertEqual(earlier.end, 6)
        XCTAssertEqual(earlier.playerMotion, mark.playerMotion)
        XCTAssertFalse(earlier.hasMotion(at: 1), "Extending In must not invent earlier tracked positions")
    }

    func testEarlierInWorksForStaticKeyframedLinkedAndCameraLayers() {
        var keyframed = drawing(); keyframed.enableKeyframes(at: 4)
        var linked = drawing()
        linked.linkedPlayers = [.init(samples: [.init(time: 2, box: .init(x: 0.2, y: 0.3, width: 0.1, height: 0.2))])]
        var camera = drawing()
        camera.cameraMotion = .init(samples: [.init(time: 2, transform: .identity), .init(time: 6, transform: .identity)])
        for original in [drawing(), keyframed, linked, camera] {
            let earlier = original.applying(.trimStart(-10), within: 0...10)
            XCTAssertEqual(earlier.start, 0); XCTAssertEqual(earlier.end, original.end)
            XCTAssertEqual(earlier.points, original.points); XCTAssertEqual(earlier.keyframes, original.keyframes)
            XCTAssertEqual(earlier.linkedPlayers, original.linkedPlayers); XCTAssertEqual(earlier.cameraMotion, original.cameraMotion)
            XCTAssertEqual(earlier.hasMotion(at: 1), original.motionMode == .still || original.motionMode == .keyframes)
        }
    }

    func testMotionModesVisibilityLocksAndLegacyKeyframesRoundTrip() throws {
        var mark = drawing(); mark.enableKeyframes(at: 3)
        XCTAssertEqual(mark.motionMode, .keyframes)
        mark.moveDrawing(to: [.init(x: 0.8, y: 0.7)], at: 4)
        mark.makeStatic(at: 4)
        XCTAssertEqual(mark.motionMode, .still); XCTAssertEqual(mark.points[0].x, 0.8)
        mark.isHidden = true; mark.isLocked = true
        XCTAssertEqual(mark.opacity(at: 4), 0)
        XCTAssertEqual(mark.applying(.move(2), within: 0...10), mark)
        XCTAssertEqual(mark, try JSONDecoder().decode(AnalysisAnnotation.self, from: JSONEncoder().encode(mark)))
        let legacy = Data("{\"time\":2,\"points\":[[0.1,0.2]]}".utf8)
        let decoded = try JSONDecoder().decode(AnnotationKeyframe.self, from: legacy)
        XCTAssertEqual(decoded.time, 2)
        XCTAssertEqual(decoded, try JSONDecoder().decode(AnnotationKeyframe.self, from: legacy))
        XCTAssertEqual(decoded, try JSONDecoder().decode(AnnotationKeyframe.self, from: JSONEncoder().encode(decoded)))
    }
}
