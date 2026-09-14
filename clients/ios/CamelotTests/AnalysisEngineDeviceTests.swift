@preconcurrency import AVFoundation
import SwiftUI
import XCTest
@testable import Camelot

/// End-to-end run of the analysis pipeline on footage already in the app's
/// Documents/Recordings folder (a physical device with real recordings).
/// Attaches overlay composites so the result can be checked by eye.
final class AnalysisEngineDeviceTests: XCTestCase {
    private func recordings() -> [URL] {
        let folder = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) ?? 0 > ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) ?? 0 }
    }

    @MainActor
    func testPipelineOnRecordedFootage() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision models cannot create an inference context on the simulator")
        #endif
        let urls = recordings()
        try XCTSkipIf(urls.isEmpty, "No recordings in Documents/Recordings")
        var report = ["=== ANALYSIS PIPELINE ==="]
        for url in urls.prefix(2) {
            let range = 2.0...6.0
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await AnalysisEngine.analyze(url: url, range: range) { _ in }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let detections = result.frames.reduce(0) { $0 + $1.detections.count }
            let posed = result.frames.reduce(0) { $0 + $1.detections.filter { $0.joints != nil }.count }
            report.append(String(format: "%@  %dx%d  %d frames in %.1fs (%.1f ms/frame)  detections %d  with pose %d  tracks %d  teams %@",
                url.lastPathComponent, Int(result.displaySize.width), Int(result.displaySize.height), result.frames.count, elapsed,
                elapsed * 1000 / Double(max(1, result.frames.count)), detections, posed, result.tracks.count, result.teamColors.description))
            XCTAssertGreaterThan(result.frames.count, 25, "expected ~10 analysed frames per second")
            let times = result.frames.map(\.time)
            XCTAssertEqual(times, times.sorted())
            XCTAssertGreaterThanOrEqual(times.first ?? 0, range.lowerBound - 0.1)
            XCTAssertLessThanOrEqual(times.last ?? 0, range.upperBound + 0.1)
            for detection in result.frames.flatMap(\.detections) {
                XCTAssertEqual(detection.box.count, 4)
                XCTAssert(detection.box.allSatisfy { $0 >= -0.2 && $0 <= 1.2 }, "box out of range: \(detection.box)")
                if let joints = detection.joints { XCTAssertEqual(joints.count, AnalysisSkeleton.jointNames.count * 3) }
            }

            var analysis = RecordingAnalysis(recordingID: UUID(), displayWidth: Int(result.displaySize.width), displayHeight: Int(result.displaySize.height))
            analysis.merge(frames: result.frames, tracks: result.tracks, teamColors: result.teamColors, range: range)
            let busiest = result.frames.max { $0.detections.count < $1.detections.count }
            for time in [busiest?.time ?? 3, 4.5] {
                if let image = try await composite(url: url, analysis: analysis, time: time) {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "\(url.deletingPathExtension().lastPathComponent)-\(String(format: "%.2f", time))s"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        report.append("=== END ===")
        print(report.joined(separator: "\n"))
        let text = XCTAttachment(string: report.joined(separator: "\n")); text.name = "analysis-report"; text.lifetime = .keepAlways
        add(text)
    }

    @MainActor
    private func composite(url: URL, analysis: RecordingAnalysis, time: Double) async throws -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let (cgImage, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let marks = (analysis.frame(at: time)?.detections ?? []).map { detection in
            AnalysisAnnotation(tool: .player, points: [detection.rect.origin, CGPoint(x: detection.rect.maxX, y: detection.rect.maxY)], start: time - 1, end: time + 1)
        }
        return UIGraphicsImageRenderer(size: size).image { renderer in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
            AnnotationRenderer.draw(marks, time: time, in: renderer.cgContext, frame: CGRect(origin: .zero, size: size))
        }
    }
}
