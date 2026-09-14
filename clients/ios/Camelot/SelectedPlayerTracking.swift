@preconcurrency import AVFoundation
import Vision
import CoreImage

struct PlayerMotionSample: Codable, Equatable, Sendable {
    var time: Double
    var box: CGRect
}

struct PlayerMotion: Codable, Equatable, Sendable {
    var samples: [PlayerMotionSample]
    var lostAt: Double?
    var gaps: [ClosedRange<Double>]? = nil
    var recoveryCount: Int? = nil
    /// Nil enables the default gentle stabilisation, including legacy projects.
    /// Raw samples remain untouched for correction, retracking and turning it off.
    var smoothing: Double? = nil
    var trackID: UUID? = nil
    /// A drawing's bind pose is independent of the shared track's first sample.
    var referenceBox: CGRect? = nil
    var jerseyProfile: PlayerJerseyProfile? = nil

    func box(at time: Double) -> CGRect? {
        guard let first = samples.first, let last = samples.last,
              time >= first.time - 0.05, time <= last.time + 0.12,
              lostAt.map({ time < $0 }) ?? true,
              !(gaps?.contains { $0.contains(time) } ?? false) else { return nil }
        var low = 0, high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < time { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return first.box }
        let a = samples[low - 1], b = samples[low]
        let t = CGFloat(min(1, max(0, (time - a.time) / max(0.001, b.time - a.time))))
        let lhs = stabilisedBox(at: low - 1), rhs = stabilisedBox(at: low)
        return CGRect(x: lhs.minX + (rhs.minX - lhs.minX) * t, y: lhs.minY + (rhs.minY - lhs.minY) * t,
                      width: lhs.width + (rhs.width - lhs.width) * t, height: lhs.height + (rhs.height - lhs.height) * t)
    }

    private func stabilisedBox(at index: Int) -> CGRect {
        let sample = samples[index]
        let amount = min(1, max(0, smoothing ?? 0.65))
        guard amount > 0, index > 0, index < samples.count - 1 else { return sample.box }
        let radius = 0.10 + amount * 0.22
        // Bound both time and work per rendered frame. A centred local linear fit
        // reduces box wobble without the trailing lag of a causal moving average.
        var weight = 0.0, dtSum = 0.0, dtSquared = 0.0
        var values = SIMD4<Double>.zero, slopes = SIMD4<Double>.zero
        for neighbour in max(0, index - 24)...min(samples.count - 1, index + 24) {
            let candidate = samples[neighbour], dt = candidate.time - sample.time
            guard abs(dt) <= radius else { continue }
            let lower = min(candidate.time, sample.time), upper = max(candidate.time, sample.time)
            guard !(gaps?.contains { $0.lowerBound <= upper && $0.upperBound >= lower } ?? false),
                  lostAt.map({ candidate.time < $0 }) ?? true else { continue }
            let w = exp(-0.5 * pow(dt / (radius * 0.48), 2))
            let box = candidate.box
            let value = SIMD4<Double>(box.midX, box.maxY, box.width, box.height)
            weight += w; dtSum += w * dt; dtSquared += w * dt * dt
            values += value * w; slopes += value * (w * dt)
        }
        let determinant = weight * dtSquared - dtSum * dtSum
        guard determinant > 0.000001 else { return sample.box }
        let fitted = (values * dtSquared - slopes * dtSum) / determinant
        let raw = SIMD4<Double>(sample.box.midX, sample.box.maxY, sample.box.width, sample.box.height)
        let value = raw + (fitted - raw) * amount
        let width = max(0.001, value.z), height = max(0.001, value.w)
        return CGRect(x: value.x - width / 2, y: value.y - height, width: width, height: height)
    }

    var reference: CGRect? { referenceBox ?? samples.first?.box }
}

/// Follow the selected image region on every decoded frame. This tracker has its
/// own visual identity; it does not depend on IDs from separate detection passes.
enum SelectedPlayerTracking {
    static func track(url: URL, seed: CGRect, from start: Double, to end: Double,
                      allowRecovery: Bool = true,
                      prior: PlayerMotion? = nil,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> PlayerMotion {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw AnalysisError.noVideoTrack }
        let naturalSize = try await video.load(.naturalSize)
        let orientation = AnalysisEngine.orientation(for: try await video.load(.preferredTransform))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let scale = min(1, 1280 / max(naturalSize.width, naturalSize.height))
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: max(2, Int(naturalSize.width * scale / 2) * 2),
            kCVPixelBufferHeightKey as String: max(2, Int(naturalSize.height * scale / 2) * 2)
        ])
        output.alwaysCopiesSampleData = false; reader.add(output)
        guard reader.startReading() else { throw AnalysisError.reader(reader.error?.localizedDescription ?? "Cannot open video") }
        defer { reader.cancelReading() }
        let tracker = VisionPlayerTracker(seed: flip(seed))
        defer { tracker.finish() }
        let detector = try SportsPlayerDetector()
        var result = PlayerMotion(samples: [.init(time: start, box: seed)])
        var profile = PlayerJerseyProfile.resuming(prior?.jerseyProfile)
        var trajectory = PlayerTrackingTrajectory()
        if let prior, let last = prior.samples.last(where: { $0.time < start }), start - last.time <= 0.25,
           PlayerTracker.overlap(last.box, seed) > 0.3 {
            let gapEnd: Double = (prior.gaps ?? []).filter { $0.lowerBound < start }.map(\.upperBound).max() ?? -Double.infinity
            let loss: Double = prior.lostAt ?? Double.infinity
            let boundary = max(gapEnd, loss < start ? loss : -Double.infinity)
            for sample in prior.samples where sample.time < start && sample.time > boundary && sample.time >= start - 0.7 && prior.box(at: sample.time) != nil {
                trajectory.append(sample)
            }
        }
        trajectory.append(.init(time: start, box: seed))
        var recovery = PlayerRecoveryConfirmation()
        var previous = seed
        var lastReport = start
        var lastDetection = start - 1
        var previousTime = start
        var missingSince: Double?
        var lastGoodBuffer: CVPixelBuffer?
        var cameraReference: (buffer: CVPixelBuffer, time: Double)?
        var nextCameraReference: (buffer: CVPixelBuffer, time: Double)?
        var recoveryCameraVelocity: CGPoint?
        var firstFrame = true
        let imageContext = CIContext(options: [.cacheIntermediates: false])
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if seconds - lastReport >= 0.15 { lastReport = seconds; progress(min(1, (seconds - start) / max(0.01, end - start))) }
            if firstFrame {
                firstFrame = false
                // The user's selection defines identity, never the first nearby
                // detector result. Existing tracks retain their original anchor.
                if profile.examples.isEmpty, let jersey = PlayerJerseySignature.sample(buffer, box: seed, orientation: orientation) {
                    profile.learn(jersey, clear: true)
                }
            }
            let observation = missingSince == nil ? try tracker.track(buffer, orientation: orientation) : nil
            var predicted = trajectory.predicted(at: seconds) ?? previous
            var box = observation.map { flip($0.boundingBox) } ?? predicted
            // Stop on uncertain tracking instead of drawing a frozen ring or
            // jumping to a different player after a cut or occlusion.
            let displacement = hypot(box.midX - previous.midX, box.midY - previous.midY)
            var reliable = (observation?.confidence ?? 0) >= 0.35 && box.width > 0.003 && box.height > 0.008 &&
                displacement < max(0.035, previous.height * 0.7) &&
                box.width / previous.width < 1.5 && box.height / previous.height < 1.5 && missingSince == nil
            if !profile.examples.isEmpty, let shirt = PlayerJerseySignature.sample(buffer, box: box, orientation: orientation),
               profile.similarity(to: shirt) < 0.45 { reliable = false }
            let neededRecovery = !reliable
            var recoveryCamera: CameraTransform?
            if neededRecovery, !allowRecovery { result.lostAt = seconds; break }
            let detectionDue = seconds - lastDetection >= (neededRecovery ? 0.12 : 0.3)
            if neededRecovery, detectionDue, let lastGoodBuffer,
               let camera = try? CameraMotionTracking.register(previous: lastGoodBuffer, current: buffer, orientation: orientation, context: imageContext),
               let center = camera.point(.init(x: previous.midX, y: previous.maxY)) {
                recoveryCamera = camera
                // Estimate the recent pan only on loss. Subtract it from the
                // screen trajectory before applying the current camera warp,
                // so player movement survives recovery without counting pan twice.
                if recoveryCameraVelocity == nil, let reference = cameraReference,
                   previousTime - reference.time >= 0.2,
                   let pastCamera = try? CameraMotionTracking.register(previous: reference.buffer, current: lastGoodBuffer, orientation: orientation, context: imageContext),
                   let past = pastCamera.point(.init(x: previous.midX, y: previous.maxY)) {
                    let dt = previousTime - reference.time
                    recoveryCameraVelocity = CGPoint(x: (past.x - previous.midX) / dt, y: (past.y - previous.maxY) / dt)
                }
                if let velocity = recoveryCameraVelocity,
                   let moving = trajectory.predicted(at: seconds, cameraVelocity: velocity),
                   let feet = camera.point(.init(x: moving.midX, y: moving.maxY)) {
                    predicted = previous.offsetBy(dx: feet.x - previous.midX, dy: feet.y - previous.maxY)
                } else if hypot(center.x - previous.midX, center.y - previous.maxY) > max(0.002, previous.width * 0.25) {
                    // Without a recent pan estimate, only replace trajectory
                    // prediction for material scene movement. An identity warp
                    // must not erase the runner's established velocity.
                    predicted = previous.offsetBy(dx: center.x - previous.midX, dy: center.y - previous.maxY)
                }
            }
            // Optical tracking can gradually shrink to the shirt. Re-anchor to
            // a full-body sports detection so rings remain under the feet.
            if detectionDue {
                if ProcessInfo.processInfo.thermalState == .critical { throw AnalysisError.thermal }
                lastDetection = seconds
                let detected = try detector.playerBoxes(in: buffer, orientation: orientation)
                let candidates = detected.enumerated().map { index, candidate in
                    PlayerIdentityAssociation.Candidate(box: candidate,
                        jersey: PlayerJerseySignature.sample(buffer, box: candidate, orientation: orientation),
                        crowded: detected.enumerated().contains { other, rect in
                            other != index && PlayerTracker.overlap(rect, candidate) > 0.25
                        })
                }
                let match = PlayerIdentityAssociation.choose(candidates, expected: predicted,
                    optical: reliable ? box : nil, profile: profile, recovering: neededRecovery)
                if let match {
                    if match.candidate.crowded && !profile.isConfirmed {
                        reliable = false
                    } else if !neededRecovery || recovery.accept(match.candidate.box, at: seconds, camera: recoveryCamera) {
                        box = match.candidate.box; tracker.reseed(flip(box))
                        // The detector box belongs to THIS frame. Prime Vision
                        // here, before a fast pan moves the player next frame.
                        _ = try tracker.track(buffer, orientation: orientation)
                        reliable = true
                        if !neededRecovery, seconds - start >= 0.15, let jersey = match.candidate.jersey {
                            profile.learn(jersey, clear: !match.candidate.crowded)
                        }
                    }
                } else {
                    _ = recovery.accept(nil, at: seconds)
                    // A nearby incompatible/ambiguous body is an occlusion, not
                    // permission to keep the optical tracker on that other body.
                    if candidates.contains(where: { PlayerTracker.overlap($0.box, box) > 0.25 }) { reliable = false }
                }
            }
            if !reliable {
                if missingSince == nil { missingSince = previousTime.nextUp }
                // A short, explicitly hidden gap gives the detector a chance to
                // reacquire. Never display predicted positions as confirmed motion.
                if !allowRecovery || seconds - (missingSince ?? seconds) >= PlayerTrackingLimits.maximumRecoverySeconds {
                    result.lostAt = missingSince; break
                }
                continue
            }
            if let missing = missingSince {
                result.gaps = (result.gaps ?? []) + [missing...seconds.nextDown]
                missingSince = nil
                trajectory = PlayerTrackingTrajectory()
                cameraReference = nil; nextCameraReference = nil
            }
            if neededRecovery { result.recoveryCount = (result.recoveryCount ?? 0) + 1 }
            if seconds > start + 0.001 { result.samples.append(.init(time: seconds, box: box)) }
            trajectory.append(.init(time: seconds, box: box))
            previous = box
            previousTime = seconds
            lastGoodBuffer = buffer
            recoveryCameraVelocity = nil
            if nextCameraReference == nil || seconds - (nextCameraReference?.time ?? seconds) >= 0.35 {
                cameraReference = nextCameraReference
                nextCameraReference = (buffer, seconds)
            }
        }
        if reader.status == .failed { throw AnalysisError.reader(reader.error?.localizedDescription ?? "Video decoding failed") }
        if let missingSince { result.lostAt = missingSince }
        result.jerseyProfile = profile.examples.isEmpty ? prior?.jerseyProfile : profile
        progress(1)
        return result
    }
    private static func flip(_ box: CGRect) -> CGRect { CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height) }
}
