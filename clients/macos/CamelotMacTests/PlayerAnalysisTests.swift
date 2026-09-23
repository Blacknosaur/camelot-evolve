import XCTest
@testable import Camelot

final class PlayerAnalysisTests: XCTestCase {
    private func box(_ x: CGFloat, _ y: CGFloat, w: CGFloat = 0.05, h: CGFloat = 0.12) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    func testTrackerKeepsIdentityAcrossSmallMovesAndAssignsNewIdsToNewPlayers() {
        var tracker = PlayerTracker()
        let first = tracker.update(time: 0, candidates: [.init(box: box(0.1, 0.5)), .init(box: box(0.6, 0.5))])
        XCTAssertEqual(first.map(\.track), [0, 1])
        // Both move slightly; a third player enters.
        let second = tracker.update(time: 1 / 30, candidates: [.init(box: box(0.61, 0.5)), .init(box: box(0.105, 0.51)), .init(box: box(0.9, 0.2))])
        XCTAssertEqual(second.map(\.track), [1, 0, 2])
        XCTAssertEqual(tracker.tracks.count, 3)
        XCTAssertEqual(tracker.tracks[0].frameCount, 2)
    }

    func testTrackerStartsANewTrackAfterALongGap() {
        var tracker = PlayerTracker()
        _ = tracker.update(time: 0, candidates: [.init(box: box(0.1, 0.5))])
        let soon = tracker.update(time: 0.5, candidates: [.init(box: box(0.1, 0.5))])
        XCTAssertEqual(soon.first?.track, 0)
        let late = tracker.update(time: 2, candidates: [.init(box: box(0.1, 0.5))])
        XCTAssertEqual(late.first?.track, 1)
        XCTAssertEqual(tracker.tracks.map(\.id), [0, 1])
        XCTAssertEqual(tracker.tracks[0].end, 0.5)
    }

    func testTeamClusteringSeparatesTwoKits() {
        var tracks: [AnalysisTrack] = []
        for index in 0..<6 {
            let shade = Float(index) * 0.03
            tracks.append(AnalysisTrack(id: index, start: 0, end: 5, frameCount: 20, color: [0.8 - shade, 0.1 + shade, 0.1], team: nil))     // red kit
            tracks.append(AnalysisTrack(id: 10 + index, start: 0, end: 5, frameCount: 20, color: [0.1, 0.2 + shade, 0.85 - shade], team: nil)) // blue kit
        }
        tracks.append(AnalysisTrack(id: 99, start: 0, end: 1, frameCount: 2, color: nil, team: nil))
        let result = TeamClustering.assign(tracks)
        let reds = Set(result.tracks.filter { $0.id < 10 }.compactMap(\.team))
        let blues = Set(result.tracks.filter { $0.id >= 10 && $0.id < 99 }.compactMap(\.team))
        XCTAssertEqual(reds.count, 1); XCTAssertEqual(blues.count, 1)
        XCTAssertNotEqual(reds, blues)
        XCTAssertNil(result.tracks.first { $0.id == 99 }?.team)
        XCTAssertEqual(result.centers.count, 2)
    }

    func testMergeReplacesWindowAndKeepsTrackIdsUnique() {
        var analysis = RecordingAnalysis(recordingID: UUID(), displayWidth: 1920, displayHeight: 1080)
        analysis.merge(frames: [AnalysisFrame(time: 1, detections: [AnalysisDetection(track: 0, box: [0, 0, 0.1, 0.1], joints: nil)])],
                       tracks: [AnalysisTrack(id: 0, start: 1, end: 1, frameCount: 1, color: nil, team: nil)], teamColors: [], range: 0...2)
        analysis.merge(frames: [AnalysisFrame(time: 3, detections: [AnalysisDetection(track: 0, box: [0, 0, 0.1, 0.1], joints: nil)])],
                       tracks: [AnalysisTrack(id: 0, start: 3, end: 3, frameCount: 1, color: nil, team: nil)], teamColors: [], range: 2...4)
        XCTAssertEqual(analysis.ranges, [[0, 4]])
        XCTAssertEqual(analysis.tracks.map(\.id), [0, 1])
        XCTAssertEqual(analysis.frames.map(\.time), [1, 3])
        XCTAssertEqual(analysis.frame(at: 3.05)?.detections.first?.track, 1)
        XCTAssertNil(analysis.frame(at: 2))
        XCTAssertTrue(analysis.isAnalyzed(from: 0.5, to: 3.9))
        XCTAssertFalse(analysis.isAnalyzed(from: 0.5, to: 5))
        // Re-analysing the first window drops its old frames and tracks.
        analysis.merge(frames: [], tracks: [], teamColors: [], range: 0...2)
        XCTAssertEqual(analysis.frames.map(\.time), [3])
        XCTAssertEqual(analysis.tracks.map(\.id), [1])
    }

    func testFrameMappingFitsSourceAndCentresCrops() {
        let container = CGSize(width: 400, height: 300)
        let fit = AnalysisFrameMapping(container: container, displayAspect: 16 / 9, renderAspect: nil)
        XCTAssertEqual(fit.videoRect, CGRect(x: 0, y: 37.5, width: 400, height: 225))
        XCTAssertEqual(fit.point(CGPoint(x: 0.5, y: 1)), CGPoint(x: 200, y: 262.5))
        XCTAssertEqual(fit.normalized(CGPoint(x: 200, y: 262.5)).y, 1, accuracy: 0.0001)
        // Square crop of a 16:9 source: the render frame is 300x300, the source overflows it horizontally.
        let square = AnalysisFrameMapping(container: container, displayAspect: 16 / 9, renderAspect: 1)
        XCTAssertEqual(square.videoRect.height, 300, accuracy: 0.0001)
        XCTAssertEqual(square.videoRect.width, 300 * 16 / 9, accuracy: 0.0001)
        XCTAssertEqual(square.videoRect.midX, 200, accuracy: 0.0001)
    }

    func testOrientationFromTransform() {
        XCTAssertEqual(AnalysisEngine.orientation(for: .identity), .up)
        XCTAssertEqual(AnalysisEngine.orientation(for: CGAffineTransform(rotationAngle: .pi / 2)), .right)
    }

    func testAnalysisRoundTripsThroughStore() throws {
        let id = UUID()
        var analysis = RecordingAnalysis(recordingID: id, displayWidth: 1280, displayHeight: 720)
        analysis.merge(frames: [AnalysisFrame(time: 0.5, detections: [AnalysisDetection(track: 0, box: [0.1, 0.2, 0.05, 0.1], joints: Array(repeating: 0.5, count: 57))])],
                       tracks: [AnalysisTrack(id: 0, start: 0.5, end: 0.5, frameCount: 1, color: [0.3, 0.3, 0.3], team: 0)], teamColors: [[0.3, 0.3, 0.3]], range: 0...1)
        try AnalysisStore.save(analysis)
        defer { AnalysisStore.delete(recordingID: id) }
        XCTAssertEqual(AnalysisStore.load(recordingID: id), analysis)
    }
}
