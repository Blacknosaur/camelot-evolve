@preconcurrency import AVFoundation
import Vision
import CoreImage

struct PlayerMotionSample: Codable, Equatable, Sendable {
    var time: Double
    var box: CGRect
    /// Optional body shape for effects; identity and position use one tracker.
    var silhouette: PlayerSilhouette? = nil
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
    /// Explicit picks are protected boundaries when repairing an earlier section.
    var correctionTimes: [Double]? = nil
    /// Display-only positions inside missing intervals and briefly after a
    /// terminal loss, derived from the confirmed neighbours (camera-aware when a
    /// clip camera track exists). Raw samples, gaps and measurements ignore them.
    var inferred: [PlayerMotionSample]? = nil
    /// Manual placements inside missing intervals. Exact like corrections, but
    /// bridging is allowed through them: they exist to repair a gap.
    var anchors: [Double]? = nil
    /// Longest missing interval an effect keeps following, in seconds. Nil is
    /// the legacy 0.4-second bridge; new tracks hide uncertain positions.
    var gapBridging: Double? = nil
    /// New passes hide unresolved identity, including when an older effect had
    /// automatic bridging enabled. The user can explicitly opt into estimates.
    var hidesUncertainPositions: Bool? = nil
    /// Bounded display interpolation, independent of legacy per-effect bridging.
    /// Raw gaps remain missing measurements and cannot seed tracking.
    var automaticallyInterpolatesTinyGaps: Bool? = nil
    /// Appearance memory learned by the last pass (kit, tone, number). Carried
    /// on the source track only; drawings' copies drop it.
    var identity: PlayerIdentityMemory? = nil
    /// Legacy storage describing whether body masks were requested. This is not
    /// an identity-engine choice; old v1/v2 projects remain readable.
    var engine: PlayerTrackingEngine? = nil

    static let defaultGapBridging = 0.0
    var bridgeHorizon: Double { hidesUncertainPositions == true ? 0 : gapBridging ?? 0.4 }
    /// A lost player keeps its last (camera-relative) position briefly rather
    /// than vanishing on the frame it was last confirmed.
    var holdSeconds: Double { bridgeHorizon > 0.4 ? min(1, bridgeHorizon) : 0 }

    /// The shape on the frame nearest `time`. Masks are per-frame and are never
    /// interpolated: a blended silhouette is a shape no player ever had. Nil
    /// once the nearest frame is too far away, so the caller falls back to the
    /// box rather than pinning a stale body over moving video.
    func silhouette(at time: Double) -> PlayerSilhouette? {
        guard box(at: time) != nil, !isMissing(at: time) else { return nil }
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < time - 0.075 { low = mid + 1 } else { high = mid }
        }
        var nearest: PlayerMotionSample?
        for sample in samples[low...] {
            if sample.time > time + 0.075 { break }
            guard sample.silhouette != nil, !isMissing(at: sample.time),
                  !(gaps?.contains { $0.overlaps(min(time, sample.time)...max(time, sample.time)) } ?? false),
                  !(correctionTimes?.contains { $0 > min(time, sample.time) && $0 <= max(time, sample.time) } ?? false) else { continue }
            if nearest == nil || abs(sample.time - time) < abs(nearest!.time - time) { nearest = sample }
        }
        return nearest?.silhouette
    }

    func box(at time: Double) -> CGRect? {
        if automaticallyInterpolatesTinyGaps == true,
           let gap = gaps?.first(where: { $0.contains(time) }),
           let interpolated = interpolatedGap(at: time, gap: gap, automatic: true) { return interpolated }
        if hidesUncertainPositions == true, isMissing(at: time) {
            return nil
        }
        if let bridged = inferredBox(at: time) { return bridged }
        guard let first = samples.first, let last = samples.last,
              time >= first.time - 0.05, time <= last.time + 0.12,
              lostAt.map({ time < $0 }) ?? true else { return nil }
        if let gap = gaps?.first(where: { $0.contains(time) }) {
            return interpolatedGap(at: time, gap: gap)
        }
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

    /// Display-only interpolation between confirmed observations. Keep the raw
    /// gap for correction and measurements; never extrapolate a missing player.
    private func interpolatedGap(at time: Double, gap: ClosedRange<Double>, automatic: Bool = false) -> CGRect? {
        let horizon = automatic ? 1.0 : min(0.4, bridgeHorizon)
        guard gap.upperBound - gap.lowerBound <= horizon,
              let left = samples.lastIndex(where: { $0.time < gap.lowerBound }),
              let right = samples.firstIndex(where: { $0.time > gap.upperBound }) else { return nil }
        let a = samples[left], b = samples[right]
        guard b.time - a.time <= horizon + (automatic ? 0.0001 : 0.1),
              lostAt.map({ b.time < $0 }) ?? true,
              !(gaps?.contains { $0.contains(a.time) || $0.contains(b.time) } ?? false),
              !(correctionTimes?.contains { $0 > a.time && $0 <= b.time } ?? false) else { return nil }
        let lhs = stabilisedBox(at: left), rhs = stabilisedBox(at: right)
        guard lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0,
              lhs.minX > 0, lhs.maxX < 1, rhs.minX > 0, rhs.maxX < 1,
              lhs.minY > 0, lhs.maxY < 1, rhs.minY > 0, rhs.maxY < 1,
              max(lhs.width, rhs.width) / min(lhs.width, rhs.width) < 1.5,
              max(lhs.height, rhs.height) / min(lhs.height, rhs.height) < 1.5,
              hypot(rhs.midX - lhs.midX, rhs.maxY - lhs.maxY) <= max(0.025, min(lhs.height, rhs.height) * 0.6) else { return nil }
        let t = CGFloat((time - a.time) / (b.time - a.time))
        return CGRect(x: lhs.minX + (rhs.minX - lhs.minX) * t, y: lhs.minY + (rhs.minY - lhs.minY) * t,
                      width: lhs.width + (rhs.width - lhs.width) * t, height: lhs.height + (rhs.height - lhs.height) * t)
    }

    /// Bridged positions apply only where raw tracking is missing: inside a
    /// gap whose confirmed neighbours are close enough in time, or during the
    /// short hold after a terminal loss. Consecutive inferred samples are dense,
    /// so interpolation never crosses from one bridged interval into another.
    private func inferredBox(at time: Double) -> CGRect? {
        // Drawings without an explicit limit keep the legacy 0.4-second rule.
        guard gapBridging != nil, let inferred, !inferred.isEmpty, isMissing(at: time) else { return nil }
        if let gap = gaps?.first(where: { $0.contains(time) }) {
            guard let a = samples.last(where: { $0.time < gap.lowerBound }),
                  let b = samples.first(where: { $0.time > gap.upperBound }),
                  b.time - a.time <= bridgeHorizon + 0.1 else { return nil }
        } else {
            // The hold starts at the last confirmed sample before the loss;
            // stale samples recorded after `lostAt` are not a position.
            let anchor = lostAt.flatMap { lost in samples.last { $0.time < lost } } ?? samples.last
            guard holdSeconds > 0, let anchor, time > anchor.time, time - anchor.time <= holdSeconds + 0.05 else { return nil }
        }
        var low = 0, high = inferred.count
        while low < high {
            let middle = (low + high) / 2
            if inferred[middle].time < time { low = middle + 1 } else { high = middle }
        }
        let next = low < inferred.count ? inferred[low] : nil
        let previous = low > 0 ? inferred[low - 1] : nil
        if let previous, let next, next.time - previous.time <= 0.2 {
            let t = CGFloat((time - previous.time) / max(0.001, next.time - previous.time))
            let lhs = previous.box, rhs = next.box
            return CGRect(x: lhs.minX + (rhs.minX - lhs.minX) * t, y: lhs.minY + (rhs.minY - lhs.minY) * t,
                          width: lhs.width + (rhs.width - lhs.width) * t, height: lhs.height + (rhs.height - lhs.height) * t)
        }
        if let previous, abs(previous.time - time) <= 0.1 { return previous.box }
        if let next, abs(next.time - time) <= 0.1 { return next.box }
        return nil
    }

    /// Raw tracking absent at this time: inside a recorded gap, after a terminal
    /// loss, or outside the sampled span. Bridged display does not change this.
    func isMissing(at time: Double) -> Bool {
        guard let first = samples.first, let last = samples.last else { return true }
        if time < first.time - 0.05 || time > last.time + 0.12 { return true }
        if let lostAt, time >= lostAt { return true }
        return gaps?.contains { $0.contains(time) } ?? false
    }

    private func stabilisedBox(at index: Int) -> CGRect {
        let sample = samples[index]
        let amount = min(1, max(0, smoothing ?? 0.65))
        guard amount > 0, index > 0, index < samples.count - 1,
              !(correctionTimes?.contains { abs($0 - sample.time) < 1 / 600 } ?? false),
              !(anchors?.contains { abs($0 - sample.time) < 1 / 600 } ?? false) else { return sample.box }
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
                  !(correctionTimes?.contains { $0 > lower && $0 <= upper } ?? false),
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

/// Which way through the clip a pass walks. Both directions run the same
/// per-frame logic; backward replays short decoded chunks in a mirrored time
/// base and maps the result back to source time.
enum PlayerTrackingDirection: Sendable {
    case forward, backward
}

/// Legacy persisted mask settings. Retained only to decode existing projects;
/// the tracking API has one mechanism with optional body-mask output.
enum PlayerTrackingEngine: String, Codable, Sendable, CaseIterable {
    case v1, v2

    var title: String { self == .v1 ? "Track" : "Track with mask" }
    var label: String { self == .v1 ? "Player tracking" : "Player tracking + body mask" }
}

/// Identity status is independent of segmentation quality.
enum PlayerTrackingPhase: String, Sendable {
    case following, occluded, offscreen, searching
    var label: String {
        switch self {
        case .following: "Following player"
        case .occluded: "Player hidden · checking identity"
        case .offscreen: "Player offscreen · identity retained"
        case .searching: "Searching · identity unconfirmed"
        }
    }
}

/// Published while a pass runs, so the editor can follow the tracked frame and
/// keep everything confirmed so far if the user stops.
struct PlayerTrackingCheckpoint: Sendable {
    /// Source time of the most recently examined frame. The playhead follows this.
    var time: Double
    /// 0…1 over the requested range.
    var fraction: Double
    /// Everything confirmed so far, in source time, ready to persist as-is.
    /// Nil on a pure progress tick between checkpoints.
    var motion: PlayerMotion?
    var phase: PlayerTrackingPhase = .following
}

/// The result of one pass. `stopped` means the user asked it to stop, so the
/// motion is a complete, usable partial track rather than a failure.
struct PlayerTrackingOutcome: Sendable {
    var motion: PlayerMotion
    var stopped = false
}

/// Follow the selected image region through the clip. This tracker has its own
/// visual identity; it does not depend on IDs from separate detection passes.
enum SelectedPlayerTracking {
    /// One incremental pass in either direction. Samples are published as they
    /// are produced; cancelling the surrounding task stops at the current frame
    /// and returns everything confirmed up to there instead of throwing.
    static func track(url: URL, seed: CGRect, from start: Double, to requestedEnd: Double,
                      direction: PlayerTrackingDirection = .forward,
                      allowRecovery: Bool = true,
                      prior: PlayerMotion? = nil,
                      includeBodyMasks: Bool = false,
                      confirmedSeed: Bool = false,
                      checkpoint: @escaping @Sendable (PlayerTrackingCheckpoint) -> Void) async throws -> PlayerTrackingOutcome {
        var prior = prior
        if confirmedSeed {
            let reference = try await PlayerAppearancePrinter.reference(url: url, box: seed, at: start)
            var memory = prior?.identity ?? PlayerIdentityMemory()
            memory.confirm(reference)
            var prepared = prior ?? PlayerMotion(samples: [])
            prepared.identity = memory; prepared.jerseyProfile = memory.jersey
            prior = prepared
        }
        switch direction {
        case .forward: return try await runForward(url: url, seed: seed, from: start, to: requestedEnd, allowRecovery: allowRecovery, prior: prior, includeBodyMasks: includeBodyMasks, checkpoint: checkpoint)
        case .backward: return try await runBackward(url: url, seed: seed, from: start, to: requestedEnd, prior: prior, includeBodyMasks: includeBodyMasks, checkpoint: checkpoint)
        }
    }

    /// Fraction-only convenience kept for callers that cannot use partial results.
    static func track(url: URL, seed: CGRect, from start: Double, to requestedEnd: Double,
                      allowRecovery: Bool = true,
                      prior: PlayerMotion? = nil,
                      includeBodyMasks: Bool = false,
                      confirmedSeed: Bool = false,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> PlayerMotion {
        let outcome = try await track(url: url, seed: seed, from: start, to: requestedEnd, direction: .forward,
                                      allowRecovery: allowRecovery, prior: prior, includeBodyMasks: includeBodyMasks, confirmedSeed: confirmedSeed) { progress($0.fraction) }
        if outcome.stopped { throw CancellationError() }
        return outcome.motion
    }

    /// Follow a player backwards from `start` to the earlier `end`.
    static func trackBackward(url: URL, seed: CGRect, from start: Double, to end: Double,
                              prior: PlayerMotion? = nil,
                              includeBodyMasks: Bool = false,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> PlayerMotion {
        let outcome = try await track(url: url, seed: seed, from: start, to: end, direction: .backward, prior: prior, includeBodyMasks: includeBodyMasks) { progress($0.fraction) }
        if outcome.stopped { throw CancellationError() }
        return outcome.motion
    }

    /// Decode settings shared by both directions. The long side is already well
    /// below any source we ship; measured on device, decoding 4K to 720 saves
    /// about a millisecond a frame, so this is not where the time goes.
    private static func decodeSettings(_ naturalSize: CGSize) -> [String: Any] {
        let scale = min(1, 1280 / max(naturalSize.width, naturalSize.height))
        return [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: max(2, Int(naturalSize.width * scale / 2) * 2),
            kCVPixelBufferHeightKey as String: max(2, Int(naturalSize.height * scale / 2) * 2)
        ]
    }

    private static func runForward(url: URL, seed: CGRect, from start: Double, to requestedEnd: Double,
                                   allowRecovery: Bool, prior: PlayerMotion?, includeBodyMasks: Bool,
                                   checkpoint: @escaping @Sendable (PlayerTrackingCheckpoint) -> Void) async throws -> PlayerTrackingOutcome {
        let end = prior?.repairEnd(from: start, to: requestedEnd) ?? requestedEnd
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw AnalysisError.noVideoTrack }
        let naturalSize = try await video.load(.naturalSize)
        let frameRate = Double(try await video.load(.nominalFrameRate))
        let orientation = AnalysisEngine.orientation(for: try await video.load(.preferredTransform))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: decodeSettings(naturalSize))
        output.alwaysCopiesSampleData = false; reader.add(output)
        guard reader.startReading() else { throw AnalysisError.reader(reader.error?.localizedDescription ?? "Cannot open video") }
        defer { reader.cancelReading() }
        return try run(seed: seed, from: start, to: end, allowRecovery: allowRecovery, prior: prior, orientation: orientation,
                       includeBodyMasks: includeBodyMasks,
                       interval: PlayerTrackingLimits.samplingInterval(sourceFrameRate: frameRate),
                       checkpoint: { motion, time, fraction, phase in
            checkpoint(.init(time: time, fraction: fraction, motion: motion, phase: phase))
        }) {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed { throw AnalysisError.reader(reader.error?.localizedDescription ?? "Video decoding failed") }
                return nil
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return (nil, 0) }
            return (buffer, CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
    }

    /// Frames are decoded in short chunks that are replayed in reverse, in a
    /// mirrored time base (`t' = seed − t`), through the same per-frame identity
    /// logic; the result is mapped back to source time so it can be joined in
    /// front of the existing track.
    private static func runBackward(url: URL, seed: CGRect, from start: Double, to end: Double, prior: PlayerMotion?,
                                    includeBodyMasks: Bool,
                                    checkpoint: @escaping @Sendable (PlayerTrackingCheckpoint) -> Void) async throws -> PlayerTrackingOutcome {
        let end = prior?.repairStart(from: start, to: end) ?? end
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw AnalysisError.noVideoTrack }
        let naturalSize = try await video.load(.naturalSize)
        let frameRate = Double(try await video.load(.nominalFrameRate))
        let orientation = AnalysisEngine.orientation(for: try await video.load(.preferredTransform))
        let settings = decodeSettings(naturalSize)
        let chunk = 0.5
        var chunkEnd = start
        var queue: [(CVPixelBuffer, Double)] = []
        var seedMemory = PlayerMotion(samples: [])
        seedMemory.identity = prior?.identity; seedMemory.jerseyProfile = prior?.jerseyProfile
        let outcome = try run(seed: seed, from: 0, to: start - end, allowRecovery: true, prior: seedMemory, orientation: orientation,
                              includeBodyMasks: includeBodyMasks,
                              interval: PlayerTrackingLimits.samplingInterval(sourceFrameRate: frameRate),
                              checkpoint: { motion, time, fraction, phase in
            checkpoint(.init(time: start - time, fraction: fraction, motion: motion.map { unmirror($0, seed: start, prior: prior) }, phase: phase))
        }) {
            while queue.isEmpty {
                guard chunkEnd > end + 0.0005 else { return nil }
                let chunkStart = max(end, chunkEnd - chunk)
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = CMTimeRange(start: CMTime(seconds: chunkStart, preferredTimescale: 600), end: CMTime(seconds: chunkEnd, preferredTimescale: 600))
                let output = AVAssetReaderTrackOutput(track: video, outputSettings: settings)
                output.alwaysCopiesSampleData = false; reader.add(output)
                guard reader.startReading() else { throw AnalysisError.reader(reader.error?.localizedDescription ?? "Cannot open video") }
                var frames: [(CVPixelBuffer, Double)] = []
                while let sample = output.copyNextSampleBuffer() {
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                    let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    // The seed frame itself was already seen by the forward pass.
                    if seconds < start - 0.0005 { frames.append((buffer, start - seconds)) }
                }
                if reader.status == .failed { throw AnalysisError.reader(reader.error?.localizedDescription ?? "Video decoding failed") }
                reader.cancelReading()
                queue = frames.reversed()
                chunkEnd = chunkStart
            }
            return queue.removeFirst()
        }
        return .init(motion: unmirror(outcome.motion, seed: start, prior: prior), stopped: outcome.stopped)
    }

    /// Map a mirrored pass back into source time.
    private static func unmirror(_ mirrored: PlayerMotion, seed start: Double, prior: PlayerMotion?) -> PlayerMotion {
        var result = mirrored
        result.samples = mirrored.samples.map { .init(time: start - $0.time, box: $0.box, silhouette: $0.silhouette) }.reversed()
        result.gaps = mirrored.gaps.map { $0.map { (start - $0.upperBound)...(start - $0.lowerBound) }.sorted { $0.lowerBound < $1.lowerBound } }
        result.inferred = nil
        result.correctionTimes = [start]
        // Losing the player going backwards means the track starts later; it
        // is not a terminal loss in source time.
        if let lost = mirrored.lostAt {
            let earliest = start - lost
            result.samples.removeAll { $0.time < earliest }
            result.gaps = result.gaps?.filter { $0.lowerBound >= earliest }
            result.lostAt = nil
        }
        result.jerseyProfile = mirrored.jerseyProfile ?? prior?.jerseyProfile
        result.identity = mirrored.identity ?? prior?.identity
        return result
    }

    private static func run(seed: CGRect, from start: Double, to end: Double, allowRecovery: Bool, prior: PlayerMotion?,
                            orientation: CGImagePropertyOrientation, includeBodyMasks: Bool, interval: Double,
                            checkpoint: @escaping @Sendable (PlayerMotion?, Double, Double, PlayerTrackingPhase) -> Void,
                            nextFrame: () throws -> (CVPixelBuffer?, Double)?) throws -> PlayerTrackingOutcome {
        let tracker = VisionPlayerTracker(seed: flip(seed))
        defer { tracker.finish() }
        // Optional EdgeTAM masks. The tracker below owns identity and position;
        // the segmenter only answers "which pixels are this player", and the
        // state machine decides what any of it is allowed to teach.
        let segmenter: PlayerTemporalSegmenter? = includeBodyMasks ? try EdgeTAMSegmenter() : nil
        var machine = PlayerTrackMachine(startingAt: start)
        var stabilizer = PlayerMaskStabilizer()
        /// The segmenter needs re-prompting after any break in continuity.
        var needsPrompt = true
        var segmentationROI: PlayerROI?
        var lastSegmentation = -Double.infinity
        /// This frame's shape, once the segmenter and stabiliser have run.
        var silhouette: PlayerSilhouette?
        let detector = try SportsPlayerDetector()
        let numbers = ShirtNumberReader()
        let printer = PlayerAppearancePrinter()
        let poseReader = PlayerPoseReader()
        /// Skeletons for the current detection frame, and the tracked player's
        /// own. Read at detection cadence, not every frame: ~10 ms each.
        var poses: [PlayerPose] = []
        var playerPose: PlayerPose?
        var lastNumberRead = -Double.infinity
        var lastPrint = -Double.infinity
        var leftFrame = false
        var exitSide: PlayerExitSide?
        var recentHeights: [CGFloat] = []
        /// While two bodies share the box nothing is learned; when they part,
        /// the body that comes out must still match the memory.
        var mergedSince: Double?

        var result = PlayerMotion(samples: [.init(time: start, box: seed)], correctionTimes: [start])
        result.gapBridging = PlayerMotion.defaultGapBridging
        result.hidesUncertainPositions = true
        result.automaticallyInterpolatesTinyGaps = true
        var profile = PlayerJerseyProfile.resuming(prior?.jerseyProfile)
        var memory = PlayerIdentityMemory.resuming(prior?.identity, jersey: prior?.jerseyProfile)
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
        var completeBody: CGRect? = PlayerBodyExtent.isCropped(seed) ? nil : seed
        var lastReport = start
        var lastDetection = start - 1
        var needsIdentityCheck = false
        var weakIdentitySince: Double?
        var lastInteractionTime = -Double.infinity
        var trustedMotion: (box: CGRect, time: Double, trajectory: PlayerTrackingTrajectory, buffer: CVPixelBuffer)?
        var previousTime = start
        var missingSince: Double?
        var lastGoodBuffer: CVPixelBuffer?
        var cameraReference: (buffer: CVPixelBuffer, time: Double, box: CGRect)?
        var nextCameraReference: (buffer: CVPixelBuffer, time: Double, box: CGRect)?
        var recoveryPlayerVelocity: CGPoint?
        var sceneCamera = IncrementalSceneCamera()
        var sceneActive = false
        var trustedFrame: CameraFeatureRegistration.Frame?
        var trustedVelocity: CGPoint?
        var bodyVisibleInOcclusion = false
        var holdingOcclusion = false
        var firstFrame = true
        let imageContext = CIContext(options: [.cacheIntermediates: false])
        var stop = false, stopped = false
        var lastProcessed: Double?
        var lastCheckpoint = CFAbsoluteTimeGetCurrent()
        func snapshot() -> PlayerMotion {
            var motion = result
            motion.jerseyProfile = profile.examples.isEmpty ? prior?.jerseyProfile : profile
            motion.identity = memory.jersey.examples.isEmpty ? prior?.identity : memory
            motion.engine = includeBodyMasks ? .v2 : .v1
            return motion
        }
        func rememberExitSide(from box: CGRect, at time: Double) {
            let extent = completeBody.map { PlayerBodyExtent.estimate(visible: box, reference: $0) } ?? box
            exitSide = PlayerExitSide.detect(box) ?? PlayerExitSide.detect(extent)
            leftFrame = exitSide != nil
            if let exitSide {
                PlayerTrackingLimits.trace?(String(format: "%.3f player exit side=%@", time, String(describing: exitSide)))
            }
        }
        // One pool per frame. Without it Vision and CoreMedia temporaries pile up
        // for the whole pass: a five-minute clip reached 2.2 GB and was killed.
        while !stop {
            try autoreleasepool {
            guard let frame = try nextFrame() else { stop = true; return }
            // Stopping keeps everything confirmed so far; it is not a failure.
            if Task.isCancelled { stop = true; stopped = true; return }
            guard let buffer = frame.0 else { return }
            let seconds = frame.1
            // Sample at a bounded rate. 60 fps footage costs twice as much as
            // 30 fps for no extra accuracy, and every gate here was tuned at 30.
            if let last = lastProcessed, seconds - last < interval - 0.002 { return }
            lastProcessed = seconds
            silhouette = nil
            playerPose = nil
            holdingOcclusion = false
            if seconds - lastReport >= 0.15 {
                lastReport = seconds
                let now = CFAbsoluteTimeGetCurrent()
                let due = now - lastCheckpoint >= 0.4
                if due { lastCheckpoint = now }
                checkpoint(due ? snapshot() : nil, seconds, min(1, (seconds - start) / max(0.01, end - start)),
                           missingSince == nil ? .following : leftFrame ? .offscreen : seconds - missingSince! > PlayerTrackingLimits.maximumRecoverySeconds ? .searching : .occluded)
            }
            if firstFrame {
                firstFrame = false
                // The user's selection defines identity, never the first nearby
                // detector result. Existing tracks retain their original anchor.
                if profile.examples.isEmpty, !PlayerBodyExtent.isCropped(seed),
                   let jersey = PlayerJerseySignature.sample(buffer, box: seed, orientation: orientation) {
                    profile.learn(jersey, clear: true)
                }
                if memory.jersey.examples.isEmpty { memory.learn(PlayerObservation.observe(buffer, box: seed, orientation: orientation, among: []), clear: true) }
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
            if missingSince == nil, !profile.examples.isEmpty,
               let shirt = PlayerJerseySignature.sample(buffer, box: completeBody.map { PlayerBodyExtent.estimate(visible: box, reference: $0, expected: predicted) } ?? box,
                                                        orientation: orientation, region: playerPose?.torso),
               profile.similarity(to: shirt) < 0.45 {
                PlayerTrackingLimits.trace?(String(format: "%.3f optical jersey mismatch %.2f", seconds, profile.similarity(to: shirt)))
                reliable = false
            }
            if !reliable, observation == nil, missingSince == nil { PlayerTrackingLimits.trace?(String(format: "%.3f no optical observation", seconds)) }
            else if !reliable, missingSince == nil, let observation {
                PlayerTrackingLimits.trace?(String(format: "%.3f optical unreliable conf=%.2f disp=%.3f size=%.2fx%.2f", seconds, observation.confidence, displacement, box.width / previous.width, box.height / previous.height))
            }
            // The optical tracker can slide onto a body in contact. Kit chroma
            // and tone say so even when the hue histogram cannot, and a box that
            // has grown well past the player's usual width is two bodies.
            // Kit, tone and embedding cues need a clean detector box, so they
            // are checked at detection frames, never on the jittering optical box.
            // A box that has grown into two bodies is an occlusion: keep
            // following, but learn nothing until the bodies part.
            if reliable, missingSince == nil, mergedSince == nil, PlayerTrackingLimits.isMerged(box, recentHeights: recentHeights) {
                mergedSince = seconds
                PlayerTrackingLimits.trace?(String(format: "%.3f optical box merged h=%.3f", seconds, box.height))
            }
            let neededRecovery = !reliable
            let recoveryAge = missingSince.map { seconds - $0 } ?? 0
            let dormant = recoveryAge > PlayerTrackingLimits.maximumRecoverySeconds
            let needsReidentification = neededRecovery && (dormant || (missingSince == nil ? PlayerPresence.leftFrame(previous) : leftFrame))
            var recoveryCamera: CameraTransform?
            var cameraReturnPosition: CGRect?
            var preferHold = false
            if neededRecovery, !allowRecovery { result.lostAt = seconds; stop = true; return }
            // Once a plausible return is found, confirm it while that partial
            // view is still visible instead of waiting another dormant interval.
            let confirmingReturn = neededRecovery && recovery.expected(at: seconds, camera: nil, maximumInterval: 0.6) != nil
            let partialBody = completeBody.map {
                PlayerBodyExtent.estimate(visible: box, reference: $0).height > box.height * 1.1
            } ?? false
            let detectionInterval = neededRecovery
                ? PlayerTrackingSearch.recoveryInterval(confirming: confirmingReturn, exited: exitSide != nil, dormant: dormant)
                : needsIdentityCheck ? 0.08 : partialBody || box.maxY > 0.92 || box.minX < 0.08 || box.maxX > 0.92 ? 0.1 : !profile.isConfirmed ? 0.12 : 0.3
            let detectionDue = seconds - lastDetection >= detectionInterval
            // Chain scene motion from the last trusted frame. A single warp
            // from that frame to now fails once the pan leaves the overlap,
            // which left the search stuck on the exit edge.
            let sceneUncertain = neededRecovery || mergedSince != nil || weakIdentitySince != nil
            if sceneUncertain {
                if !sceneActive {
                    sceneCamera.reset()
                    if let trustedFrame {
                        _ = sceneCamera.observe(trustedFrame, at: trustedMotion?.time ?? previousTime)
                    }
                    sceneActive = true
                }
                if let frame = CameraMotionTracking.sceneFrame(buffer, orientation: orientation, context: imageContext),
                   let camera = sceneCamera.observe(frame, at: seconds) {
                    recoveryCamera = camera
                    let originBox = trustedMotion?.box ?? previous
                    let originTime = trustedMotion?.time ?? previousTime
                    let shift = camera.point(CGPoint(x: 0.5, y: 0.5)).map { hypot($0.x - 0.5, $0.y - 0.5) } ?? 1
                    let velocity = shift < 0.08 ? (trustedVelocity ?? recoveryPlayerVelocity) : nil
                    if let projected = PlayerSceneProjection.box(originBox, at: seconds, originTime: originTime, camera: camera, velocity: velocity) {
                        cameraReturnPosition = projected
                        if neededRecovery { predicted = projected }
                    }
                }
            } else {
                sceneActive = false
            }
            // Optical tracking can gradually shrink to the shirt. Re-anchor to
            // a full-body sports detection so rings remain under the feet.
            if detectionDue {
                if neededRecovery, let observed = recovery.expected(at: seconds, camera: recoveryCamera,
                                                                     maximumInterval: dormant ? 0.6 : 0.3) {
                    predicted = observed
                }
                if ProcessInfo.processInfo.thermalState == .critical { throw AnalysisError.thermal }
                lastDetection = seconds
                var detected = try detector.playerBoxes(in: buffer, orientation: orientation)
                // Always inspect the remembered edge, even if another player
                // matches elsewhere or the predicted position is offscreen.
                if let searchSide = neededRecovery ? exitSide : partialBody ? PlayerExitSide.detect(box) : nil {
                    let edge = PlayerTrackingSearch.edgeRegion(searchSide, near: previous)
                    let focused = try detector.playerBoxes(in: buffer, orientation: orientation,
                                                           region: edge, minimumConfidence: 0.12)
                    for candidate in focused where !detected.contains(where: { PlayerTracker.overlap($0, candidate) > 0.5 }) {
                        detected.append(candidate)
                    }
                }
                // Kit colour read from a fixed slice of the box drifts onto
                // grass and neighbours as the box loosens; pose says where the
                // shirt actually is. Identity is only as good as that sample.
                poses = poseReader.poses(in: buffer, orientation: orientation)
                var observations: [PlayerObservation] = []
                func permitsReturn(_ observation: PlayerObservation) -> Bool {
                    PlayerTrackingSearch.allowsReturn(observation.box, through: exitSide,
                        cameraPosition: cameraReturnPosition,
                        strongIdentity: memory.recognizesReturn(observation) ||
                            (memory.recognizesAutomaticReturn(observation) && (memory.similarity(to: observation) ?? 0) >= 0.9),
                        exitPosition: previous)
                }
                func identities(_ boxes: [CGRect]) -> [PlayerIdentityAssociation.Candidate] {
                    observations = boxes.map { candidateBox in
                        PlayerObservation.observe(buffer, box: candidateBox, orientation: orientation, among: boxes,
                                                  pose: PlayerPoseReader.match(candidateBox, among: poses),
                                                  // Retain body proportions after an absence too:
                                                  // a bottom-edge return may show only head and shirt.
                                                  // The stale position must not infer an interior occlusion.
                                                  bodyExtent: completeBody.map { PlayerBodyExtent.estimate(visible: candidateBox, reference: $0, expected: dormant ? nil : predicted) })
                    }
                    if PlayerTrackingLimits.trace != nil {
                        for seen in observations where abs(seen.box.midX - predicted.midX) < 0.15 && abs(seen.box.maxY - predicted.maxY) < 0.12 {
                            PlayerTrackingLimits.trace?(String(format: "%.3f cues x=%.3f feet=%.3f jersey=%.2f chroma=%.2f total=%.2f crowded=%d", seconds,
                                                               seen.box.midX, seen.box.maxY, seen.jersey.map { profile.similarity(to: $0) } ?? -1,
                                                               seen.chroma.flatMap { memory.chroma?.similarity(to: $0) } ?? -1,
                                                               memory.similarity(to: seen) ?? -1, seen.crowded ? 1 : 0))
                        }
                    }
                    // Feature prints for the few bodies near the prediction:
                    // that is where a same-kit neighbour could be mistaken.
                    // A player who walked off the picture is exactly the one
                    // whose return has to be recognised from appearance alone,
                    // so the embeddings are computed after a frame exit too.
                    if needsReidentification {
                        // A number is useful when it can be read, but May 11
                        // demonstrates that a small player can produce no OCR
                        // evidence at all. Enrich the same shortlisted bodies
                        // with the automatically learned appearance gallery so
                        // temporal recovery can work without a manual pick.
                        for index in observations.indices where !observations[index].crowded
                            && observations[index].box.height >= 0.04
                            && (memory.similarity(to: observations[index]) ?? 0) >= 0.6 {
                            if memory.number.confirmed != nil,
                               observations[index].box.height >= PlayerRosterTracking.minimumNumberHeight {
                                observations[index].number = numbers.read(buffer, box: observations[index].box, orientation: orientation)
                            }
                            let extent = completeBody.map {
                                PlayerBodyExtent.estimate(visible: observations[index].box, reference: $0, expected: dormant ? nil : predicted)
                            }
                            printer.enrich(&observations[index], buffer: buffer, orientation: orientation, bodyExtent: extent)
                        }
                    }
                    // Generic whole-body prints change sharply during a turn.
                    // Use them to qualify re-identification, not as a veto on
                    // continuous optical motion with compatible kit/head cues.
                    // Clear accepted frames can still teach the gallery below.
                    for index in observations.indices { observations[index].time = seconds }
                    if PlayerTrackingLimits.trace != nil {
                        for seen in observations {
                            PlayerTrackingLimits.trace?(String(format: "%.3f identity x=%.3f y=%.3f w=%.3f h=%.3f score=%.2f automatic=%d edge=%d allowed=%d upper=%.2f", seconds, seen.box.midX, seen.box.maxY, seen.box.width, seen.box.height, memory.similarity(to: seen) ?? -1, memory.recognizesAutomaticReturn(seen) ? 1 : 0, exitSide.map { memory.recognizesEdgeReturn(seen, through: $0) } == true ? 1 : 0, permitsReturn(seen) ? 1 : 0, seen.upperBodyPrint.flatMap { memory.upperBodyGallery?.similarity(to: $0) } ?? -1))
                        }
                    }
                    return observations.enumerated().compactMap { index, observation in
                        guard !neededRecovery || permitsReturn(observation) else { return nil }
                        // Interior occlusions retain local temporal support.
                        // After an exit, every confirmation needs identity
                        // evidence: continuity of a newcomer is not ours.
                        let supportsPending = !leftFrame && (recovery.expected(at: seconds, camera: recoveryCamera, maximumInterval: 0.3).map {
                            PlayerIdentityAssociation.isContinuous(observation.box, from: $0) &&
                                !observation.crowded && !memory.conflicts(with: observation) &&
                                (memory.similarity(to: observation) ?? 0) >= 0.82
                        } ?? false)
                        guard !needsReidentification || memory.recognizesReturn(observation) ||
                            memory.recognizesAutomaticReturn(observation) || supportsPending else { return nil }
                        return observation.candidate(tag: index)
                    }
                }
                // Kit plus skin/hair and socks tone: the same cues the roster uses.
                let appearance: (PlayerIdentityAssociation.Candidate) -> CGFloat? = { candidate in
                    memory.similarity(to: observations[candidate.tag]).map { CGFloat($0) }
                }
                var candidates = identities(detected)
                // A live optical observation is more current than the fitted
                // trajectory, especially while a cropped player turns.
                let associationExpected = reliable ? box : predicted
                if !neededRecovery {
                    candidates.removeAll { !PlayerIdentityAssociation.isContinuous($0.box, from: box) }
                }
                var ranked = PlayerIdentityAssociation.ranked(candidates, expected: associationExpected,
                    optical: reliable ? box : nil, profile: profile, recovering: neededRecovery, recoveryAge: recoveryAge,
                    exitSide: exitSide, bodyReference: completeBody, appearance: appearance)
                var recoveryMatch: PlayerIdentityAssociation.Match?
                var match: PlayerIdentityAssociation.Match? = neededRecovery ? nil : PlayerIdentityAssociation.choose(
                    candidates, expected: associationExpected, optical: reliable ? box : nil, profile: profile,
                    recovering: neededRecovery, recoveryAge: recoveryAge, bodyReference: completeBody, requiredMargin: 0.16, appearance: appearance)
                // A local crop gives distant players more model pixels. Only
                // retry a missed association; retain the same identity gates.
                if ((match == nil && !neededRecovery) || (neededRecovery && ranked.isEmpty)),
                   let region = PlayerTrackingSearch.region(around: predicted) {
                    // The full-frame pass keeps a conservative cutoff to avoid
                    // flooding identity matching with false positives. A
                    // focused edge crop has much more model pixels for a small
                    // partial return, so let identity and temporal confirmation
                    // reject the extra weak boxes instead.
                    let focused = try detector.playerBoxes(in: buffer, orientation: orientation, region: region,
                                                           minimumConfidence: neededRecovery ? 0.12 : 0.18)
                    for candidate in focused where !detected.contains(where: { PlayerTracker.overlap($0, candidate) > 0.5 }) {
                        detected.append(candidate)
                    }
                    candidates = identities(detected)
                    if !neededRecovery {
                        candidates.removeAll { !PlayerIdentityAssociation.isContinuous($0.box, from: box) }
                    }
                    ranked = PlayerIdentityAssociation.ranked(candidates, expected: associationExpected,
                        optical: reliable ? box : nil, profile: profile, recovering: neededRecovery, recoveryAge: recoveryAge,
                        exitSide: exitSide, bodyReference: completeBody, appearance: appearance)
                    if !neededRecovery {
                        match = PlayerIdentityAssociation.choose(candidates, expected: associationExpected,
                            optical: reliable ? box : nil, profile: profile, recovering: neededRecovery, recoveryAge: recoveryAge,
                            bodyReference: completeBody, requiredMargin: 0.16, appearance: appearance)
                    }
                }
                if neededRecovery {
                    // The fallback must enter the SAME confirmation update.
                    // Calling accept([]) first erased its previous sighting.
                    if ranked.isEmpty, dormant, profile.isConfirmed,
                       let index = PlayerPresence.findAnywhere(observations, memory: memory,
                            minimum: leftFrame ? 0.9 : 0.85, margin: leftFrame ? 0.15 : 0.1,
                            automaticAppearance: true, plausible: { candidate in
                                if exitSide != nil {
                                    return observations.contains { $0.box == candidate && permitsReturn($0) }
                                }
                                return hypot(candidate.midX - predicted.midX, candidate.maxY - predicted.maxY)
                                    <= 0.12 + 0.3 * min(recoveryAge, 6)
                            }) {
                        ranked = [.init(candidate: observations[index].candidate(tag: index), score: 1)]
                    }
                    // Keep the best few detector candidates alive across
                    // recovery frames. A candidate is committed only after it
                    // wins temporal support, not merely because it was closest
                    // on this one frame.
                    recoveryMatch = recovery.accept(ranked, at: seconds, camera: recoveryCamera,
                                                     requiredObservations: needsReidentification ? 3 : 2,
                                                     maximumInterval: 0.3, toleratesMiss: true)
                    match = recoveryMatch
                }
                let anchor = cameraReturnPosition ?? previous
                bodyVisibleInOcclusion = mergedSince != nil || detected.contains { PlayerTracker.overlap($0, anchor) > 0.12 }
                if let match {
                    let hasNearbyRival = observations.enumerated().contains { index, other in
                        index != match.candidate.tag && (memory.similarity(to: other) ?? 0) >= 0.74 &&
                        abs(other.box.midX - match.candidate.box.midX) < max(other.box.width, match.candidate.box.width) * 1.5 &&
                        abs(other.box.maxY - match.candidate.box.maxY) < max(other.box.height, match.candidate.box.height) * 0.5
                    }
                    // A marginal detector match needs another observation
                    // before optical drift can carry it onto an opponent.
                    // Use the detected torso: fixed bands on an optical crop
                    // change with pose and must not drive this decision.
                    // Both appearance cues must be weak. A distant shirt can
                    // fluctuate by itself during a turn or tackle; oversampling
                    // that noise prematurely discards valid optical motion.
                    needsIdentityCheck = (memory.similarity(to: observations[match.candidate.tag]) ?? 1) < 0.74 &&
                        (match.candidate.jersey.map { profile.similarity(to: $0) } ?? 1) < 0.78
                    if needsIdentityCheck {
                        if weakIdentitySince == nil { weakIdentitySince = seconds }
                    } else { weakIdentitySince = nil }
                    PlayerTrackingLimits.trace?(String(format: "%.3f match score=%.2f crowded=%d confirmed=%d recovering=%d", seconds, match.score, match.candidate.crowded ? 1 : 0, profile.isConfirmed ? 1 : 0, neededRecovery ? 1 : 0))
                    let merged = (!neededRecovery || mergedSince != nil) && PlayerTrackingLimits.isMerged(match.candidate.box, recentHeights: recentHeights)
                    if match.candidate.crowded || merged { lastInteractionTime = seconds }
                    if merged, mergedSince == nil {
                        mergedSince = seconds
                        PlayerTrackingLimits.trace?(String(format: "%.3f merged box h=%.3f: following without learning", seconds, match.candidate.box.height))
                    }
                    if !merged, mergedSince != nil, memory.isConfirmed,
                       (memory.similarity(to: observations[match.candidate.tag]) ?? 0) < 0.75 {
                        // The bodies parted and this one is not our player.
                        PlayerTrackingLimits.trace?(String(format: "%.3f body out of the merge fails identity (%.2f): hiding", seconds, memory.similarity(to: observations[match.candidate.tag]) ?? 0))
                        mergedSince = nil
                        reliable = false
                    } else if match.candidate.crowded && !profile.isConfirmed {
                        reliable = false
                    } else if needsIdentityCheck && (merged || match.candidate.crowded) {
                        // The detector box is shared or the kit no longer matches.
                        // Keep the camera-moved body instead of stepping onto the neighbour.
                        preferHold = true
                        lastInteractionTime = seconds
                    } else if !neededRecovery || recoveryMatch != nil {
                        box = match.candidate.box
                        // Refine here as well, so optical and detector frames
                        // contribute boxes of the same convention: mixing tight
                        // and loose boxes would make the samples pulse.
                        playerPose = PlayerPoseReader.match(box, among: poses)
                        tracker.reseed(flip(box))
                        // Only a RECOVERY is a discontinuity worth re-prompting
                        // for. This branch also runs on every routine detection
                        // frame, and re-prompting there would throw the memory
                        // bank away several times a second, breaking temporal
                        // mask continuity.
                        if neededRecovery { needsPrompt = true }
                        // The detector box belongs to THIS frame. Prime Vision
                        // here, before a fast pan moves the player next frame.
                        _ = try tracker.track(buffer, orientation: orientation)
                        reliable = true
                        if !merged, mergedSince != nil { mergedSince = nil }
                        if !neededRecovery, mergedSince == nil, !PlayerPresence.leftFrame(box), seconds - start >= 0.15, let jersey = match.candidate.jersey {
                            profile.learn(jersey, clear: !match.candidate.crowded && !hasNearbyRival)
                            var observation = observations[match.candidate.tag]
                            // Read the number hard at the start, then sparsely.
                            //
                            // The seconds just after the user's tap are the best
                            // view of this player there will ever be, and a
                            // confirmed number is the only cue that separates
                            // team-mates in one kit when he has to be found
                            // again later. Measured on the May 11 clip, one read
                            // every 0.8 s gave three attempts before the player
                            // left the frame and never confirmed a number, so
                            // the whole-frame search had nothing decisive to go
                            // on. Once confirmed, the sparse cadence is enough
                            // to keep it honest.
                            let establishing = memory.number.confirmed == nil && seconds - start < 4
                            if !observation.crowded, box.height >= PlayerRosterTracking.minimumNumberHeight,
                               seconds - lastNumberRead >= (establishing ? 0.12 : 0.8) {
                                lastNumberRead = seconds
                                observation.number = numbers.read(buffer, box: box, orientation: orientation)
                            }
                            if !observation.crowded, box.height >= PlayerAppearanceGallery.minimumBodyHeight, seconds - lastPrint >= 0.5, observation.print == nil {
                                lastPrint = seconds
                                printer.enrich(&observation, buffer: buffer, orientation: orientation)
                            }
                            memory.learn(observation, clear: !match.candidate.crowded && !hasNearbyRival)
                        }
                    }
                } else {
                    PlayerTrackingLimits.trace?(String(format: "%.3f no match among %d candidates (recovering=%d)", seconds, candidates.count, neededRecovery ? 1 : 0))
                    if !neededRecovery, ranked.isEmpty { recovery.reset() }
                    // A nearby incompatible/ambiguous body is an occlusion, not
                    // permission to keep the optical tracker on that other body.
                    if !neededRecovery, let overlapping = candidates.first(where: { PlayerTracker.overlap($0.box, box) > 0.25 }) {
                        let score = memory.similarity(to: observations[overlapping.tag]) ?? 0
                        needsIdentityCheck = true
                        if weakIdentitySince == nil { weakIdentitySince = seconds }
                        // One marginal crop is not a different player. Keep
                        // optical continuity briefly, without learning from it.
                        if score < 0.45 || seconds - (weakIdentitySince ?? seconds) >= 0.22 {
                            reliable = false
                            preferHold = true
                            lastInteractionTime = seconds
                        }
                    }
                }
            }
            if let seen = observation.map({ flip($0.boundingBox) }),
               PlayerTracker.overlap(seen, cameraReturnPosition ?? previous) > 0.2 {
                bodyVisibleInOcclusion = true
            }
            // A neighbour covering part of the body keeps the marker on the
            // last trusted player, moved with the camera, for at most a second.
            // Off screen, or fully hidden, the marker stays gone until a real
            // detection confirms the same player.
            let weakLongEnough = weakIdentitySince.map { seconds - $0 >= 0.22 } ?? false
            if let trusted = trustedMotion, preferHold || (weakLongEnough && seconds - lastInteractionTime <= 1) {
                let shift = recoveryCamera?.point(CGPoint(x: 0.5, y: 0.5)).map { hypot($0.x - 0.5, $0.y - 0.5) } ?? 1
                let velocity = shift < 0.08 ? trustedVelocity : nil
                if let held = PlayerOcclusionHold.box(trusted: trusted.box, trustedTime: trusted.time, at: seconds,
                                                      camera: recoveryCamera, velocity: velocity,
                                                      bodyStillVisible: bodyVisibleInOcclusion || mergedSince != nil) {
                    PlayerTrackingLimits.trace?(String(format: "%.3f occlusion hold from %.3f", seconds, trusted.time))
                    result.samples.removeAll { $0.time > trusted.time }
                    box = held
                    reliable = true
                    holdingOcclusion = true
                    needsPrompt = true
                    tracker.reseed(flip(held))
                    _ = try? tracker.track(buffer, orientation: orientation)
                } else if weakLongEnough || preferHold {
                    PlayerTrackingLimits.trace?(String(format: "%.3f occlusion lost: recover from %.3f", seconds, trusted.time))
                    reliable = false
                    previous = trusted.box; previousTime = trusted.time
                    trajectory = trusted.trajectory; lastGoodBuffer = trusted.buffer
                    result.samples.removeAll { $0.time > trusted.time }
                    missingSince = trusted.time.nextUp
                    leftFrame = PlayerPresence.leftFrame(trusted.box)
                    if leftFrame { rememberExitSide(from: trusted.box, at: trusted.time) } else { exitSide = nil }
                    cameraReference = nil; nextCameraReference = nil; recoveryPlayerVelocity = nil
                    recovery = PlayerRecoveryConfirmation()
                    weakIdentitySince = nil
                    bodyVisibleInOcclusion = false
                }
            }
            if !reliable {
                needsPrompt = true
                stabilizer.reset()
                if missingSince == nil {
                    missingSince = previousTime.nextUp
                    leftFrame = PlayerPresence.leftFrame(previous)
                    rememberExitSide(from: previous, at: previousTime)
                }
                // A short, explicitly hidden gap gives the detector a chance to
                // reacquire. Never display predicted positions as confirmed motion.
                if !allowRecovery {
                    result.lostAt = missingSince; stop = true; return
                }
                return
            }
            if let missing = missingSince {
                // Offline confirmation validates the earlier sightings too.
                // Keep their actual source-frame coordinates, not a frozen
                // copy of the final box or an extrapolation across the absence.
                let sightings = recovery.confirmedSamples.filter { $0.time >= missing && $0.time < seconds }
                for sighting in sightings {
                    let extent = completeBody.map {
                        PlayerBodyExtent.estimate(visible: sighting.box, reference: $0)
                    } ?? sighting.box
                    result.samples.append(.init(time: sighting.time, box: extent))
                }
                let returnTime = sightings.first?.time ?? seconds
                if missing < returnTime {
                    result.gaps = (result.gaps ?? []) + [missing...returnTime.nextDown]
                }
                missingSince = nil
                leftFrame = false
                exitSide = nil
                trajectory = PlayerTrackingTrajectory()
                // A short loss during a merge keeps the merge state: the body
                // that reappears still has to prove it is ours once alone.
                if mergedSince == nil || seconds - missing > 1.5 { recentHeights = []; mergedSince = nil }
                cameraReference = nil; nextCameraReference = nil
                weakIdentitySince = nil
            }
            if neededRecovery { result.recoveryCount = (result.recoveryCount ?? 0) + 1 }

            // Segmentation decorates confirmed motion at 15 Hz. It never
            // changes association, full-body scale or foot position.
            if let segmenter, seconds - lastSegmentation >= 1.0 / 15 - 0.002 {
                lastSegmentation = seconds
                let bufferWidth = CGFloat(CVPixelBufferGetWidth(buffer))
                let bufferHeight = CGFloat(CVPixelBufferGetHeight(buffer))
                let rotated = orientation == .left || orientation == .right
                    || orientation == .leftMirrored || orientation == .rightMirrored
                let aspect = rotated ? bufferHeight / max(1, bufferWidth) : bufferWidth / max(1, bufferHeight)
                // Memory features have spatial coordinates. Keep the crop fixed
                // until the body needs more room, then prompt a fresh bank.
                if segmentationROI?.comfortablyContains(box) != true {
                    segmentationROI = PlayerROI.around(box, aspect: aspect)
                    needsPrompt = true
                }
                if let roi = segmentationROI {
                    if needsPrompt { machine.correct(at: seconds); stabilizer.reset() }
                    let produced = needsPrompt
                        ? try? segmenter.begin(frame: buffer, orientation: orientation, roi: roi, prompt: box)
                        : try? segmenter.next(frame: buffer, orientation: orientation, roi: roi)
                    let agrees = produced.map {
                        PlayerTracker.overlap($0.box, box) > 0.3 && $0.box.width > 0.003 && $0.box.height > 0.008
                    } ?? false
                    let confidence: Float = agrees ? produced?.confidence ?? 0 : 0
                    machine.advance(confidence: confidence, at: seconds)
                    if agrees, machine.state.producesMask {
                        silhouette = stabilizer.stabilize(measured: produced?.silhouette, box: box,
                                                          confidence: confidence, state: machine.state)
                    }
                    needsPrompt = !agrees || !machine.state.producesMask
                    PlayerTrackingLimits.trace?(String(format: "%.3f mask quality=%.2f state=%@", seconds, confidence, machine.state.rawValue))
                }
            }
            if seconds > start + 0.001 {
                // Effects anchor to the bottom of the stored box, so the foot
                // line is corrected here — and only here. The tracker keeps the
                // detector's own box for its gates, which were tuned on it.
                let extent = completeBody.map { PlayerBodyExtent.estimate(visible: box, reference: $0, expected: predicted) } ?? box
                let grounded = playerPose?.grounding(extent) ?? extent
                result.samples.append(.init(time: seconds, box: grounded, silhouette: silhouette))
            }
            if mergedSince == nil, seconds - start >= 0.15 || seconds == start { recentHeights.append(box.height); if recentHeights.count > 30 { recentHeights.removeFirst() } }
            trajectory.append(.init(time: seconds, box: box))
            if !holdingOcclusion, !needsIdentityCheck, mergedSince == nil {
                trustedMotion = (box, seconds, trajectory, buffer)
                trustedVelocity = trajectory.velocity()
                trustedFrame = CameraMotionTracking.sceneFrame(buffer, orientation: orientation, context: imageContext)
            }
            previous = box
            let inferredPartial = completeBody.map {
                PlayerBodyExtent.estimate(visible: box, reference: $0, expected: predicted).height > box.height * 1.1
            } ?? false
            if !holdingOcclusion, !PlayerBodyExtent.isCropped(box), !inferredPartial, mergedSince == nil,
               box.maxY < min(0.94, 1 - max(0.025, box.height * 0.2)) { completeBody = box }
            previousTime = seconds
            lastGoodBuffer = buffer
            recoveryPlayerVelocity = nil
            if nextCameraReference == nil || seconds - (nextCameraReference?.time ?? seconds) >= 0.35 {
                cameraReference = nextCameraReference
                nextCameraReference = (buffer, seconds, box)
            }
            }
        }
        if let missingSince { result.lostAt = missingSince }
        let motion = snapshot()
        checkpoint(motion, lastProcessed ?? start, stopped ? min(1, ((lastProcessed ?? start) - start) / max(0.01, end - start)) : 1,
                   missingSince == nil ? .following : leftFrame ? .offscreen : .searching)
        return .init(motion: motion, stopped: stopped)
    }
    private static func flip(_ box: CGRect) -> CGRect { CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height) }
}
