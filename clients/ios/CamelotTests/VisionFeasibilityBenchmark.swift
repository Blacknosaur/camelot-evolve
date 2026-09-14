@preconcurrency import AVFoundation
import Vision
import XCTest

/// On-device feasibility benchmark for match-analysis models built into Vision.
/// Runs against recordings already present in the app's Documents/Recordings
/// folder (real footage on a physical device) and prints ms/frame per request.
/// Skips when no recordings exist, so it never fails CI or the simulator.
final class VisionFeasibilityBenchmark: XCTestCase {
    private struct Sample { let buffer: CVPixelBuffer; let sample: CMSampleBuffer; let time: CMTime }

    private func recordings() -> [URL] {
        let folder = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 }
    }

    private func readFrames(_ url: URL, count: Int, stride: Int, startSeconds: Double) async throws -> (frames: [Sample], size: CGSize, fps: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw XCTSkip("no video track") }
        let size = try await track.load(.naturalSize)
        let fps = Double(try await track.load(.nominalFrameRate))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: startSeconds, preferredTimescale: 600), duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        var frames: [Sample] = []
        var index = 0
        while frames.count < count, let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard index % stride == 0, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append(Sample(buffer: buffer, sample: sample, time: CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        reader.cancelReading()
        return (frames, size, fps)
    }

    private func measure(_ label: String, frames: [Sample], _ body: (Sample) throws -> Int) rethrows -> String {
        var detections = 0
        let start = CFAbsoluteTimeGetCurrent()
        for frame in frames { detections += try body(frame) }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(frames.count)
        return String(format: "%-28@ %7.1f ms/frame  (%5.1f fps)  detections/frame %.1f", label, elapsed, 1000 / elapsed, Double(detections) / Double(frames.count))
    }

    func testVisionModelsOnRecordedFootage() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Vision models cannot create an inference context on the simulator")
        #endif
        let urls = recordings()
        try XCTSkipIf(urls.isEmpty, "No recordings in Documents/Recordings")
        var report: [String] = ["", "=== VISION FEASIBILITY (device: \(await UIDevice.current.model) \(await UIDevice.current.systemVersion)) ==="]

        for url in urls.prefix(3) {
            let (frames, size, fps) = try await readFrames(url, count: 40, stride: 2, startSeconds: 2)
            guard !frames.isEmpty else { continue }
            report.append("--- \(url.lastPathComponent)  \(Int(size.width))x\(Int(size.height)) @ \(Int(fps))fps, \(frames.count) frames sampled")

            // 1. Person boxes (cheap, good enough for "highlight a player" spotlight + tracking seed)
            report.append(try measure("HumanRectangles", frames: frames) { frame in
                let request = VNDetectHumanRectanglesRequest(); request.upperBodyOnly = false
                try VNImageRequestHandler(cvPixelBuffer: frame.buffer, orientation: .up).perform([request])
                return request.results?.count ?? 0
            })

            // 2. Full body pose (17 joints) for every person in frame
            report.append(try measure("HumanBodyPose (2D)", frames: frames) { frame in
                let request = VNDetectHumanBodyPoseRequest()
                try VNImageRequestHandler(cvPixelBuffer: frame.buffer, orientation: .up).perform([request])
                return request.results?.count ?? 0
            })

            // 3. 3D body pose (iOS 17+) — gives joint positions in metres, one athlete
            if #available(iOS 17, *) {
                report.append(try measure("HumanBodyPose3D", frames: frames) { frame in
                    let request = VNDetectHumanBodyPose3DRequest()
                    try VNImageRequestHandler(cvPixelBuffer: frame.buffer, orientation: .up).perform([request])
                    return request.results?.count ?? 0
                })
            }

            // 4. Ball / projectile trajectories — stateful, needs consecutive frames
            let sequence = VNSequenceRequestHandler()
            var trajectories = 0
            let trajectoryRequest = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 6) { request, _ in
                trajectories += (request.results as? [VNTrajectoryObservation])?.count ?? 0
            }
            trajectoryRequest.objectMinimumNormalizedRadius = 0.002
            trajectoryRequest.objectMaximumNormalizedRadius = 0.08
            var trajectoryErrors: [String: Int] = [:]
            let trajectoryLine = try measure("Trajectories (ball)", frames: frames) { frame in
                do { try sequence.perform([trajectoryRequest], on: frame.sample, orientation: .up) }
                catch { trajectoryErrors[error.localizedDescription, default: 0] += 1 }
                return 0
            }
            report.append(trajectoryLine + "  total trajectories \(trajectories)  errors \(trajectoryErrors)")

            // 5. Tracking a user-drawn box across frames (manual "follow this player")
            if let first = frames.first {
                let seedRequest = VNDetectHumanRectanglesRequest()
                try VNImageRequestHandler(cvPixelBuffer: first.buffer, orientation: .up).perform([seedRequest])
                if let seed = seedRequest.results?.first {
                    let tracker = VNSequenceRequestHandler()
                    var observation: VNDetectedObjectObservation = seed
                    var tracked = 0
                    report.append(try measure("TrackObject (1 box)", frames: frames) { frame in
                        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
                        request.trackingLevel = .accurate
                        try tracker.perform([request], on: frame.buffer, orientation: .up)
                        if let result = request.results?.first as? VNDetectedObjectObservation, result.confidence > 0.3 {
                            observation = result; tracked += 1
                        }
                        return tracked > 0 ? 1 : 0
                    })
                } else {
                    report.append("TrackObject               skipped (no person in first frame)")
                }
            }

            // 6. Foreground instance mask (iOS 17) — subject cut-out for spotlight / dim-background
            if #available(iOS 17, *) {
                let subset = Array(frames.prefix(8))
                report.append(try measure("ForegroundInstanceMask", frames: subset) { frame in
                    let request = VNGenerateForegroundInstanceMaskRequest()
                    try VNImageRequestHandler(cvPixelBuffer: frame.buffer, orientation: .up).perform([request])
                    return request.results?.first?.allInstances.count ?? 0
                })
            }

            // 7. Optical flow between consecutive frames — basis for "freeze frame + motion trails"
            if frames.count > 1 {
                let pairs = Array(zip(frames, frames.dropFirst()).prefix(10))
                let start = CFAbsoluteTimeGetCurrent()
                for (a, b) in pairs {
                    let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: b.buffer, orientation: .up, options: [:])
                    request.computationAccuracy = .low
                    try VNImageRequestHandler(cvPixelBuffer: a.buffer, orientation: .up).perform([request])
                }
                let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(pairs.count)
                report.append(String(format: "%-28@ %7.1f ms/frame  (%5.1f fps)", "OpticalFlow (low)", ms, 1000 / ms))
            }
        }
        report.append("=== END ===")
        let text = report.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text); attachment.name = "vision-benchmark"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
