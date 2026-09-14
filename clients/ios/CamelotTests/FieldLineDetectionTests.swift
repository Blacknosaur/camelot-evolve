@preconcurrency import AVFoundation
import UIKit
import XCTest
@testable import Camelot

final class FieldLineDetectionTests: XCTestCase {
    @MainActor
    func testStraightMarkingsAndBlankFrames() throws {
        let size = CGSize(width: 640, height: 360)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func fixture(lines: Bool) -> CGImage {
            UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                UIColor(red: 0.3, green: 0.55, blue: 0.15, alpha: 1).setFill(); renderer.fill(CGRect(origin: .zero, size: size))
                if lines {
                    let context = renderer.cgContext
                    context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(3)
                    context.move(to: .init(x: 80, y: 130)); context.addLine(to: .init(x: 500, y: 200)); context.strokePath()
                    context.move(to: .init(x: 500, y: 200)); context.addLine(to: .init(x: 590, y: 90)); context.strokePath()
                }
            }.cgImage!
        }
        XCTAssertTrue(try FieldLineDetection.detect(in: fixture(lines: false)).isEmpty)
        let detected = try FieldLineDetection.detect(in: fixture(lines: true))
        XCTAssertEqual(detected.count, 2)
        XCTAssertTrue(detected.contains { abs(($0.start.y + $0.end.y) / 2 - 165 / 360.0) < 0.015 })
        XCTAssertTrue(detected.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.start) && CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.end) })
    }

    @MainActor
    func testDetectsActualPenaltyBoxWithoutInventingWholePitch() async throws {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings/EBB12192-62DB-495B-A6CE-218F0C420A74.mov")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Stress clip only exists on the fixture device") }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: 3, preferredTimescale: 600)).image
        let start = Date(), lines = try FieldLineDetection.detect(in: frame)
        print("FIELD_LINES count=\(lines.count) seconds=\(Date().timeIntervalSince(start))")
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        // The long penalty-box edge visibly crosses this source-space point.
        XCTAssertTrue(lines.contains { segment in
            let a = segment.start, b = segment.end, p = CGPoint(x: 0.65, y: 0.532)
            let length = hypot(b.x - a.x, b.y - a.y)
            let distance = abs((b.y - a.y) * p.x - (b.x - a.x) * p.y + b.x * a.y - b.y * a.x) / max(0.001, length)
            return length > 0.15 && distance < 0.008 && min(a.x, b.x) < p.x && max(a.x, b.x) > p.x
        })
        XCTAssertTrue(lines.allSatisfy { ($0.start.y + $0.end.y) / 2 > 0.43 }, "Floodlights and fences are not pitch lines")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: .init(width: frame.width, height: frame.height), format: format).image { renderer in
            let rect = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            UIImage(cgImage: frame).draw(in: rect)
            let marks = lines.map { AnalysisAnnotation(tool: .line, points: [$0.start, $0.end], start: 0, end: 5) }
            AnnotationRenderer.draw(marks, time: 1, in: renderer.cgContext, frame: rect)
        }
        let attachment = XCTAttachment(image: image); attachment.name = "Detected straight field markings - actual night stress clip"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
