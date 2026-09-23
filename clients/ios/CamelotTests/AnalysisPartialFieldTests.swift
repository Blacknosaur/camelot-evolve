import XCTest
import UIKit
import Vision
@testable import Camelot

final class AnalysisPartialFieldTests: XCTestCase {
    func testConnectionKeepsConfirmedPlayersDuringLossAndRestoresRecoveredEndpoint() throws {
        func track(_ x: Double) -> PlayerMotion {
            .init(samples: [0.0, 1, 2, 3, 4].map {
                .init(time: $0, box: .init(x: x + $0 * 0.02, y: 0.4, width: 0.04, height: 0.1))
            }, smoothing: 0, trackID: UUID())
        }
        let first = track(0.1), third = track(0.7)
        var missing = track(0.4); missing.gaps = [1.5...2.5]
        var mark = AnalysisAnnotation(tool: .connection,
            points: [first, missing, third].map { .init(x: $0.reference!.midX, y: $0.reference!.maxY) }, start: 0, end: 4)
        mark.linkedPlayers = [first, missing, third]
        XCTAssertEqual(mark.renderedPoints(at: 1).count, 3)
        XCTAssertTrue(mark.hasMotion(at: 2))
        XCTAssertGreaterThan(mark.opacity(at: 2), 0)
        XCTAssertEqual(mark.renderedPoints(at: 2).count, 2)
        XCTAssertEqual(mark.renderedPoints(at: 2)[0].x, first.box(at: 2)!.midX, accuracy: 0.0001)
        XCTAssertEqual(mark.renderedPoints(at: 2)[1].x, third.box(at: 2)!.midX, accuracy: 0.0001)
        mark.showsDistance = true
        let distances = AnnotationMeasurements.distances(for: mark, at: 2, ground: nil)
        XCTAssertEqual(distances.count, 1, "Only the surviving segment may get a distance label")
        XCTAssertEqual(distances.first!.point.x, 0.46, accuracy: 0.0001)
        XCTAssertEqual(mark.renderedPoints(at: 3).count, 3)
        XCTAssertEqual(mark.linkedPlayers, [first, missing, third], "Rendering must not mutate reusable identities")
        mark.tool = .zone
        XCTAssertFalse(mark.hasMotion(at: 2), "Do not invent a new polygon when a vertex disappears")
        mark.tool = .connection
        mark.linkedPlayers?[2].gaps = [1.5...2.5]
        XCTAssertFalse(mark.hasMotion(at: 2), "One confirmed player cannot form a connection")
    }

    func testVisibleReferenceLayoutsStayInsideTheirFourHandlesAndRoundTrip() throws {
        let corners: [CGPoint] = [.zero, .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)]
        for region in AnalysisFieldLayout.Region.allCases {
            for side in AnalysisFieldLayout.GoalSide.allCases {
                let layout = AnalysisFieldLayout(region: region, goalSide: side)
                let path = AnalysisFieldGuide.path(corners: corners, layout: layout)
                XCTAssertFalse(path.isEmpty)
                XCTAssertEqual(path.boundingBox.minX, 0, accuracy: 0.0001)
                XCTAssertEqual(path.boundingBox.maxX, 1, accuracy: 0.0001)
                XCTAssertEqual(path.boundingBox.minY, 0, accuracy: 0.0001)
                XCTAssertEqual(path.boundingBox.maxY, 1, accuracy: 0.0001)
                var mark = AnalysisAnnotation(tool: .zone, points: corners, start: 0, end: 4)
                mark.fieldLines = true; mark.fieldLayout = layout
                XCTAssertEqual(mark, try JSONDecoder().decode(AnalysisAnnotation.self, from: JSONEncoder().encode(mark)))
            }
        }
        let half = AnalysisFieldGuide.path(corners: corners, layout: .init(region: .halfPitch, goalSide: .left))
        let box = AnalysisFieldGuide.path(corners: corners, layout: .init(region: .penaltyArea, goalSide: .left))
        XCTAssertNotEqual(half, box)
        XCTAssertEqual(AnalysisFieldGuide.path(corners: corners), AnalysisFieldGuide.path(corners: corners, layout: .legacy))
        let right = AnalysisFieldGuide.path(corners: corners, layout: .init(region: .penaltyArea, goalSide: .right))
        XCTAssertNotEqual(box, right)
    }

    func testConnectionNumbersUseSavedNamesAndMissingPositionsAreHistorical() throws {
        let a = UUID(), b = UUID()
        let first = PlayerMotion(samples: [.init(time: 0, box: .init(x: 0.1, y: 0.2, width: 0.05, height: 0.15)),
                                          .init(time: 1, box: .init(x: 0.2, y: 0.2, width: 0.05, height: 0.15))], lostAt: 1.1, trackID: a)
        let second = PlayerMotion(samples: [.init(time: 0, box: .init(x: 0.6, y: 0.2, width: 0.05, height: 0.15)),
                                           .init(time: 4, box: .init(x: 0.7, y: 0.2, width: 0.05, height: 0.15))], trackID: b)
        var mark = AnalysisAnnotation(tool: .connection, points: [.init(x: 0.125, y: 0.35), .init(x: 0.625, y: 0.35)], start: 0, end: 4)
        mark.linkedPlayers = [first, second]
        let library = AnalysisTrackingLibrary(players: [.init(id: b, name: "Alex", motion: second), .init(id: a, name: "Sam", motion: first)])
        let anchors = mark.connectionAnchors(at: 3, library: library)
        XCTAssertEqual(anchors.map(\.title), ["1 · Sam", "2 · Alex"])
        XCTAssertTrue(anchors[0].isMissing); XCTAssertFalse(anchors[1].isMissing)
        XCTAssertEqual(anchors[0].lastSeen?.time, 1)
        XCTAssertEqual(try XCTUnwrap(anchors[0].point).x, 0.225, accuracy: 0.0001)
        XCTAssertEqual(mark.opacity(at: 3), 0, "Historical correction markers must not make a lost connection appear in export")
        XCTAssertNil(mark.connectionAnchors(at: -1, library: library)[0].point, "Never use a future sample as a last-seen position")
    }

    func testRepeatedReanchoringDoesNotExhaustVisionTrackerPool() throws {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                                          &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 240,
                                             bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(CGColor(gray: 0.25, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 96, y: 72, width: 48, height: 72))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 107, y: 85, width: 10, height: 40))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let box = CGRect(x: 0.3, y: 0.3, width: 0.15, height: 0.3)
        for _ in 0..<3 {
            let tracker = VisionPlayerTracker(seed: box)
            defer { tracker.finish() }
            for _ in 0..<64 {
                XCTAssertNotNil(try tracker.track(buffer, orientation: .up))
                XCTAssertNotNil(try tracker.track(buffer, orientation: .up))
                tracker.reseed(box)
            }
        }
    }
}
