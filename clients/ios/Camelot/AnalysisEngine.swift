@preconcurrency import AVFoundation
import CoreImage
import CoreML
import Foundation
import OSLog
import Vision

private let analysisLog = Logger(subsystem: "com.camelot.evolve", category: "Analysis")

/// What this device can run. Everything in tier 1 works from iOS 17 through the
/// `VN*` request API; the tiers above are reserved for models only exposed by the
/// newer Swift Vision API (iOS 18) and on-device language models (iOS 26).
enum AnalysisCapabilities {
    static var supportsPlayerTracking: Bool { true }
    static var supportsModernVision: Bool { if #available(iOS 18, *) { true } else { false } }
    static var supportsOnDeviceLanguageModel: Bool { if #available(iOS 26, *) { true } else { false } }
}

enum AnalysisError: LocalizedError {
    case noVideoTrack
    case thermal
    case cancelled
    case reader(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The recording has no video track."
        case .thermal: "The phone is too hot to analyse right now. Try again in a minute."
        case .cancelled: "Analysis was cancelled."
        case .reader(let message): message
        }
    }
}

struct AnalysisResult: Sendable {
    let frames: [AnalysisFrame]
    let tracks: [AnalysisTrack]
    let teamColors: [[Float]]
    let displaySize: CGSize
}

/// Runs the tier-1 pipeline over one time window of one recording:
/// person boxes + 2D pose on every analysed frame, overlap tracking, team colours.
enum AnalysisEngine {
    /// Sample motion at 10 fps; interpolation supplies the positions in between.
    static let targetFrameRate = 10.0
    /// Frames are decoded at most this wide; Vision resamples internally anyway.
    static let maximumDecodeWidth = 1280.0

    static func analyze(url: URL, range: ClosedRange<Double>, progress: @escaping @Sendable (Double) -> Void) async throws -> AnalysisResult {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AnalysisError.noVideoTrack }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalRate = Double(try await track.load(.nominalFrameRate))
        let displaySize = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
        let orientation = Self.orientation(for: transform)
        let stride = max(1, Int((nominalRate / targetFrameRate).rounded()))

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                       end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        let scale = min(1, maximumDecodeWidth / max(1, naturalSize.width))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(naturalSize.width * scale / 2) * 2,
            kCVPixelBufferHeightKey as String: Int(naturalSize.height * scale / 2) * 2,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw AnalysisError.reader(reader.error?.localizedDescription ?? "Could not read the recording.") }

        var tracker = PlayerTracker()
        let sportsDetector = try SportsPlayerDetector()
        var frames: [AnalysisFrame] = []
        // Some devices and every simulator cannot set up the pose model; boxes still work there.
        var posesAvailable = true
        var index = 0
        var lastProgress = 0.0
        let span = max(0.001, range.upperBound - range.lowerBound)
        while let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            if Task.isCancelled { reader.cancelReading(); throw AnalysisError.cancelled }
            guard index % stride == 0, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if index % 60 == 0 {
                switch ProcessInfo.processInfo.thermalState {
                case .critical: reader.cancelReading(); throw AnalysisError.thermal
                case .serious: try? await Task.sleep(for: .milliseconds(150))
                default: break
                }
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let candidates: [PlayerTracker.Candidate]
            do {
                candidates = try detect(in: buffer, orientation: orientation, includePoses: posesAvailable, sportsDetector: sportsDetector)
            } catch let error as NSError where posesAvailable && error.domain == VNErrorDomain {
                analysisLog.warning("Body pose unavailable (\(error.localizedDescription)); continuing with person boxes only")
                posesAvailable = false
                candidates = try detect(in: buffer, orientation: orientation, includePoses: false, sportsDetector: sportsDetector)
            }
            let detections = tracker.update(time: time, candidates: candidates)
            frames.append(AnalysisFrame(time: (time * 1000).rounded() / 1000, detections: detections))
            let fraction = min(1, (time - range.lowerBound) / span)
            if fraction - lastProgress >= 0.02 { lastProgress = fraction; progress(fraction) }
        }
        if reader.status == .failed { throw AnalysisError.reader(reader.error?.localizedDescription ?? "Decoding failed.") }
        let clustered = TeamClustering.assign(tracker.tracks)
        analysisLog.info("Analysed \(frames.count) frames, \(clustered.tracks.count) tracks in \(range.lowerBound, format: .fixed(precision: 1))–\(range.upperBound, format: .fixed(precision: 1))s")
        return AnalysisResult(frames: frames, tracks: clustered.tracks, teamColors: clustered.centers, displaySize: displaySize)
    }

    // MARK: Per-frame detection

    private static let jointOrder: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .leftEye, .rightEye, .leftEar, .rightEar,
        .leftShoulder, .rightShoulder, .leftElbow, .rightElbow, .leftWrist, .rightWrist,
        .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle, .neck, .root,
    ]

    private static func detect(in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, includePoses: Bool, sportsDetector: SportsPlayerDetector) throws -> [PlayerTracker.Candidate] {
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        let poses = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation).perform(includePoses ? [people, poses] : [people])

        // Vision boxes use a lower-left origin; flip to top-left.
        let modelBoxes = try sportsDetector.playerBoxes(in: buffer, orientation: orientation)
        var boxes = deduplicated(modelBoxes + (people.results ?? []).map { Self.flip($0.boundingBox) })
        var poseEntries: [(box: CGRect, joints: [Float])] = (poses.results ?? []).compactMap { observation in
            guard let points = try? observation.recognizedPoints(.all) else { return nil }
            var joints: [Float] = []
            joints.reserveCapacity(jointOrder.count * 3)
            var minX = CGFloat.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minX
            var confident = 0
            for name in jointOrder {
                let point = points[name]
                let x = CGFloat(point?.location.x ?? 0), y = 1 - CGFloat(point?.location.y ?? 0)
                let confidence = point?.confidence ?? 0
                joints += [Float((x * 1000).rounded() / 1000), Float((y * 1000).rounded() / 1000), Float((confidence * 100).rounded() / 100)]
                if confidence > 0.2 { confident += 1; minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y) }
            }
            guard confident >= 4 else { return nil }
            let pad = max(0.01, (maxY - minY) * 0.08)
            return (CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2), joints)
        }

        // Attach each pose to the best overlapping person box; poses without a box become their own candidate.
        var candidates: [PlayerTracker.Candidate] = []
        for box in boxes {
            var best: (index: Int, score: CGFloat)?
            for (index, pose) in poseEntries.enumerated() {
                let score = PlayerTracker.overlap(box, pose.box)
                if score > 0.2, score > (best?.score ?? 0) { best = (index, score) }
            }
            var candidate = PlayerTracker.Candidate(box: box, joints: nil, color: nil)
            if let best { candidate.joints = poseEntries.remove(at: best.index).joints }
            candidate.color = torsoColor(in: buffer, box: box, orientation: orientation)
            candidates.append(candidate)
        }
        for pose in poseEntries {
            candidates.append(PlayerTracker.Candidate(box: pose.box, joints: pose.joints, color: torsoColor(in: buffer, box: pose.box, orientation: orientation)))
        }
        boxes.removeAll()
        return candidates
    }

    private static func deduplicated(_ boxes: [CGRect]) -> [CGRect] {
        var kept: [CGRect] = []
        for box in boxes.sorted(by: { $0.width * $0.height < $1.width * $1.height }) {
            if !kept.contains(where: { PlayerTracker.overlap($0, box) > 0.55 }) { kept.append(box) }
        }
        return kept
    }

    private static func flip(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// Mean colour of the shirt area (upper-middle of the box), sampled sparsely from the BGRA buffer.
    static func torsoColor(in buffer: CVPixelBuffer, box: CGRect, orientation: CGImagePropertyOrientation) -> SIMD3<Float>? {
        let torso = CGRect(x: box.minX + box.width * 0.3, y: box.minY + box.height * 0.22, width: box.width * 0.4, height: box.height * 0.26)
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var sum = SIMD3<Float>.zero
        var count = 0
        let steps = 6
        for row in 0..<steps {
            for column in 0..<steps {
                let display = CGPoint(x: torso.minX + torso.width * (CGFloat(column) + 0.5) / CGFloat(steps),
                                      y: torso.minY + torso.height * (CGFloat(row) + 0.5) / CGFloat(steps))
                let pixel = bufferPoint(display, orientation: orientation)
                let x = Int(pixel.x * CGFloat(width)), y = Int(pixel.y * CGFloat(height))
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                let offset = y * rowBytes + x * 4
                let p = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                sum += SIMD3(Float(p[2]), Float(p[1]), Float(p[0])) / 255
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : nil
    }

    /// Map a normalised display-space point (top-left origin) back into the stored buffer's coordinates.
    static func bufferPoint(_ point: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        switch orientation {
        case .right: CGPoint(x: point.y, y: 1 - point.x)      // portrait, home button on the right
        case .left: CGPoint(x: 1 - point.y, y: point.x)
        case .down: CGPoint(x: 1 - point.x, y: 1 - point.y)
        default: point
        }
    }

    static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        // Camera transforms are exact, but rotations built from angles carry ~1e-16 noise.
        switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }
}

/// Sports-specific player detector shared with the proven Hoops pipeline.
/// Two overlapping crops make distant athletes materially larger at model input.
final class SportsPlayerDetector {
    private let request: VNCoreMLRequest
    private let decoder = SportsDetectorDecoder()

    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "BasketballDetector", withExtension: "mlmodelc") else {
            throw AnalysisError.reader("The player detection model is missing from this installation.")
        }
        let model = try MLModel(contentsOf: url)
        let visionModel = try VNCoreMLModel(for: model)
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        self.request = request
    }

    func playerBoxes(in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> [CGRect] {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)
        let regions = [CGRect(x: 0, y: 0, width: 0.6, height: 1), CGRect(x: 0.4, y: 0, width: 0.6, height: 1)]
        var boxes: [(CGRect, Float)] = []
        for region in regions {
            request.regionOfInterest = region
            try handler.perform([request])
            boxes += decode(request).compactMap { detection in
                guard detection.label == 2, detection.confidence >= 0.22 else { return nil }
                let visionBox = CGRect(
                    x: region.minX + detection.box.minX * region.width,
                    y: region.minY + detection.box.minY * region.height,
                    width: detection.box.width * region.width,
                    height: detection.box.height * region.height
                )
                return (CGRect(x: visionBox.minX, y: 1 - visionBox.maxY, width: visionBox.width, height: visionBox.height), detection.confidence)
            }
        }
        var kept: [(CGRect, Float)] = []
        for candidate in boxes.sorted(by: { $0.1 > $1.1 }) {
            if !kept.contains(where: { PlayerTracker.overlap($0.0, candidate.0) > 0.5 }) { kept.append(candidate) }
        }
        return kept.map(\.0)
    }

    private func decode(_ request: VNCoreMLRequest) -> [SportsDetectorDecoder.Result] {
        let objects = (request.results ?? []).compactMap { $0 as? VNRecognizedObjectObservation }.compactMap { observation -> SportsDetectorDecoder.Result? in
            guard let label = observation.labels.first else { return nil }
            let value = label.identifier.lowercased()
            let classIndex = value.contains("player") || value == "person" ? 2 : -1
            return classIndex < 0 ? nil : .init(label: classIndex, confidence: label.confidence, box: observation.boundingBox)
        }
        if !objects.isEmpty { return objects }
        let features = (request.results ?? []).compactMap { $0 as? VNCoreMLFeatureValueObservation }
        let values = Dictionary(uniqueKeysWithValues: features.compactMap { value in value.featureValue.multiArrayValue.map { (value.featureName, $0) } })
        guard let boxes = values["boxes"], let logits = values["logits"] else { return [] }
        return decoder.decode(boxes: boxes, logits: logits)
    }
}

private struct SportsDetectorDecoder {
    struct Result { let label: Int; let confidence: Float; let box: CGRect }

    func decode(boxes: MLMultiArray, logits: MLMultiArray) -> [Result] {
        guard boxes.shape.count == 3, logits.shape.count == 3,
              boxes.shape[0].intValue == 1, logits.shape[0].intValue == 1,
              boxes.shape[1] == logits.shape[1], boxes.shape[2].intValue == 4,
              logits.shape[2].intValue >= 4 else { return [] }
        var results: [Result] = []
        for candidate in 0..<boxes.shape[1].intValue {
            var bestClass = 0, confidence: Float = 0
            for label in 0..<min(4, logits.shape[2].intValue) {
                let score = 1 / (1 + exp(-value(logits, candidate, label)))
                if score > confidence { bestClass = label; confidence = score }
            }
            guard bestClass == 2, confidence >= 0.22 else { continue }
            let centerX = CGFloat(value(boxes, candidate, 0)), centerY = CGFloat(value(boxes, candidate, 1))
            let width = CGFloat(value(boxes, candidate, 2)), height = CGFloat(value(boxes, candidate, 3))
            let rect = CGRect(x: centerX - width / 2, y: 1 - centerY - height / 2, width: width, height: height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if !rect.isNull, rect.width > 0, rect.height > 0 { results.append(.init(label: bestClass, confidence: confidence, box: rect)) }
        }
        return results
    }

    private func value(_ array: MLMultiArray, _ candidate: Int, _ component: Int) -> Float {
        let offset = candidate * array.strides[1].intValue + component * array.strides[2].intValue
        return switch array.dataType {
        case .float16: Float(Float16(bitPattern: array.dataPointer.assumingMemoryBound(to: UInt16.self)[offset]))
        case .float32: array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
        case .double: Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
        default: array[offset].floatValue
        }
    }
}

// MARK: - Session state for the editor

/// Owns one background analysis at a time and the loaded results per recording.
@MainActor @Observable
final class AnalysisSession {
    private(set) var analyses: [UUID: RecordingAnalysis] = [:]
    private(set) var progress: Double?
    private(set) var runningRecordingID: UUID?
    var errorMessage: String?
    var showsPlayers = true
    var showsSkeletons = false
    var selectedTrack: (recordingID: UUID, id: Int)?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { runningRecordingID != nil }

    func load(recordingIDs: [UUID]) {
        for id in recordingIDs where analyses[id] == nil {
            if let stored = AnalysisStore.load(recordingID: id) { analyses[id] = stored }
        }
    }

    func analysis(for recordingID: UUID) -> RecordingAnalysis? { analyses[recordingID] }

    func analyze(recording: Recording, range: ClosedRange<Double>) {
        guard task == nil else { return }
        let id = recording.id, url = recording.fileURL
        runningRecordingID = id; progress = 0; errorMessage = nil
        task = Task {
            defer { task = nil; runningRecordingID = nil; progress = nil }
            do {
                let session = self
                let report: @Sendable (Double) -> Void = { fraction in
                    Task { @MainActor in session.progress = fraction }
                }
                let worker = Task.detached(priority: .userInitiated) { @Sendable in
                    try await AnalysisEngine.analyze(url: url, range: range, progress: report)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                var analysis = analyses[id] ?? RecordingAnalysis(recordingID: id, displayWidth: Int(result.displaySize.width), displayHeight: Int(result.displaySize.height))
                analysis.merge(frames: result.frames, tracks: result.tracks, teamColors: result.teamColors, range: range)
                analyses[id] = analysis
                try AnalysisStore.save(analysis)
            } catch is CancellationError {
            } catch AnalysisError.cancelled {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }

    func clear(recordingID: UUID) {
        analyses[recordingID] = nil
        AnalysisStore.delete(recordingID: recordingID)
        if selectedTrack?.recordingID == recordingID { selectedTrack = nil }
    }
}
