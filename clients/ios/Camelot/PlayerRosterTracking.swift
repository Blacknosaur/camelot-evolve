@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Vision

/// A saved player handed to the roster pass. A confirmed identity is trusted
/// for recognition; the motion only says where the player stood at the start.
struct PlayerRosterPrior: Sendable {
    let id: UUID
    let motion: PlayerMotion
    let memory: PlayerIdentityMemory?
}

struct PlayerRosterResult: Sendable {
    struct Entry: Sendable {
        let id: UUID
        let motion: PlayerMotion
        let memory: PlayerIdentityMemory
        let isNew: Bool
    }
    var entries: [Entry] = []
    var detectionFrames = 0
    var peakVisible = 0
    var elapsed = 0.0
}

/// One decode of the clip follows every player at once. Each remembered player
/// keeps a kit signature, a voted shirt number and a camera-relative last
/// position, so a body that leaves the picture or hides behind a teammate can
/// be recognised on return without the effect jumping to someone else. Twenty
/// players share the detector, the camera estimate and the exclusivity check;
/// twenty separate single-player passes would decode the clip twenty times.
enum PlayerRosterTracking {
    /// Bound concurrent detection work; historical fragments must not prevent
    /// a genuinely new player from being tracked later in a long clip.
    static let maximumActiveIdentities = 48
    static let detectionInterval = 1.0 / 15
    /// Shirt numbers are read from a zoomed torso crop, so bodies from about
    /// 8 % of the frame tall are worth trying.
    static let minimumNumberHeight: CGFloat = 0.08

    static func track(url: URL, from start: Double, to end: Double, priors: [PlayerRosterPrior],
                      camera: AnnotationCameraMotion?, progress: @escaping @Sendable (Double) -> Void) async throws -> PlayerRosterResult {
        let began = Date()
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
        let detector = try SportsPlayerDetector()
        let numbers = ShirtNumberReader()
        let printer = PlayerAppearancePrinter()
        let imageContext = CIContext(options: [.cacheIntermediates: false])
        var roster = RosterState(start: start, priors: priors)
        var lastBuffer: CVPixelBuffer?
        var lastTime = start, lastDetection = start - 1, lastReport = start
        var detectionFrames = 0, peakVisible = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if seconds - lastReport >= 0.15 { lastReport = seconds; progress(min(1, (seconds - start) / max(0.01, end - start))) }
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .critical { throw AnalysisError.thermal }
            let interval = thermal == .serious ? 1.0 / 8 : detectionInterval
            guard seconds - lastDetection >= interval - 0.002 else { continue }
            try autoreleasepool {
            var step: CameraTransform?
            var absolute: CameraTransform?
            if let camera, let current = camera.transform(at: seconds) {
                absolute = current
                if let lastBuffer, lastBuffer !== buffer, let previous = camera.transform(at: lastTime),
                   abs(previous.matrix.determinant) > 0.00001 {
                    step = CameraTransform(current.matrix * previous.matrix.inverse)
                }
            } else if let lastBuffer {
                // Without a clip camera track, register every detection frame:
                // predictions must not inherit a pan as player velocity.
                step = try? CameraMotionTracking.register(previous: lastBuffer, current: buffer, orientation: orientation, context: imageContext)
            }
            let boxes = try detector.playerBoxes(in: buffer, orientation: orientation)
            func observe(_ box: CGRect, among all: [CGRect]) -> PlayerObservation {
                PlayerObservation.observe(buffer, box: box, orientation: orientation, among: all)
            }
            var observations = boxes.map { observe($0, among: boxes) }
            for index in observations.indices { observations[index].time = seconds }
            // Prints only where identity is in question: bodies nobody visible
            // owns (candidates for a returning player), a few per frame.
            if roster.identities.contains(where: { !$0.isProvisional && $0.recovering && $0.memory.gallery?.isReady == true }) {
                let active = roster.activeBoxes
                var printed = 0
                for index in observations.indices where printed < 4 {
                    let box = observations[index].box
                    guard !observations[index].crowded, !active.contains(where: { PlayerTracker.overlap($0, box) > 0.3 }) else { continue }
                    printed += 1
                    observations[index].print = printer.print(buffer, box: box, orientation: orientation)
                }
            }
            // A blurred or distant body the full-frame pass missed is often
            // found by a zoomed crop, as in single-player tracking. Without it
            // a same-kit neighbour could pass the recovery gates instead.
            let focused: (CGRect, [CGRect]) -> [PlayerObservation] = { expected, known in
                guard let region = PlayerTrackingSearch.region(around: expected),
                      let found = try? detector.playerBoxes(in: buffer, orientation: orientation, region: region) else { return [] }
                let fresh = found.filter { candidate in !known.contains { PlayerTracker.overlap($0, candidate) > 0.5 } }
                return fresh.map { observe($0, among: known + fresh) }
            }
            // A missing player with a known number can be told apart from a
            // same-kit teammate on return. Read only bodies nobody visible owns.
            var reads = 0
            if roster.wantsNumberReads {
                let active = roster.activeBoxes
                for index in observations.indices where reads < 3 {
                    let box = observations[index].box
                    guard !observations[index].crowded, box.height >= minimumNumberHeight,
                          !active.contains(where: { PlayerTracker.overlap($0, box) > 0.3 }) else { continue }
                    reads += 1
                    observations[index].number = numbers.read(buffer, box: box, orientation: orientation)
                }
            }
            let accepted = roster.step(time: seconds, camera: step, absolute: absolute, observations: observations, focused: focused)
            peakVisible = max(peakVisible, roster.identities.filter { !$0.isProvisional && !$0.recovering }.count)
            var printsLearned = 0
            for (id, observation) in accepted where printsLearned < 3 {
                guard let identity = roster.identities.firstIndex(where: { $0.id == id }), !observation.crowded,
                      !roster.identities[identity].isProvisional, seconds - roster.identities[identity].lastPrint >= 1 else { continue }
                printsLearned += 1
                roster.identities[identity].lastPrint = seconds
                if let print = printer.print(buffer, box: observation.box, orientation: orientation) {
                    var references = roster.identities[identity].memory.gallery ?? PlayerAppearanceGallery()
                    references.add(print, at: seconds)
                    roster.identities[identity].memory.gallery = references
                }
            }
            for (id, observation) in accepted where reads < 4 {
                let box = observation.box
                guard let identity = roster.identities.firstIndex(where: { $0.id == id }),
                      roster.identities[identity].wantsNumberRead(at: seconds), !observation.crowded,
                      box.height >= minimumNumberHeight else { continue }
                reads += 1
                roster.identities[identity].lastNumberRead = seconds
                if let text = numbers.read(buffer, box: box, orientation: orientation) { roster.identities[identity].memory.number.vote(text) }
            }
            detectionFrames += 1
            lastBuffer = buffer; lastTime = seconds; lastDetection = seconds
            }
        }
        if reader.status == .failed { throw AnalysisError.reader(reader.error?.localizedDescription ?? "Video decoding failed") }
        progress(1)
        var result = PlayerRosterResult(detectionFrames: detectionFrames, peakVisible: peakVisible, elapsed: Date().timeIntervalSince(began))
        result.entries = roster.finish()
        return result
    }
}

/// Per-pass roster state: every remembered player plus provisional bodies that
/// may become players once their kit is confirmed and nobody else claims them.
struct RosterState {
    struct Identity {
        let id: UUID
        var memory: PlayerIdentityMemory
        var isProvisional: Bool
        var isNew: Bool
        var hits = 0
        var clearHits = 0
        var firstSeen: Double?
        var trajectory = PlayerTrackingTrajectory()
        var previous: CGRect?
        /// Last confirmed box in screen space, never camera-warped.
        var lastSeen: CGRect?
        var previousTime: Double
        var missingSince: Double?
        var confirmation = PlayerRecoveryConfirmation()
        var samples: [PlayerMotionSample] = []
        var gaps: [ClosedRange<Double>] = []
        var recoveries = 0
        var lastNumberRead = -Double.infinity
        var lastPrint = -Double.infinity
        var recentHeights: [CGFloat] = []
        var mergedSince: Double?
        var savedMotion: PlayerMotion?

        var recovering: Bool { missingSince != nil }
        func recoveryAge(at time: Double) -> Double { missingSince.map { time - $0 } ?? 0 }
        func wantsNumberRead(at time: Double) -> Bool { !recovering && time - lastNumberRead >= 0.8 }

        func expectation(at time: Double) -> PlayerRosterAssociation.Expectation {
            // A rerun has source-time observations throughout the clip. Use
            // those positions when available, including a player's late entry.
            // Appearance and exclusive ownership still gate every assignment.
            if let savedMotion, let first = savedMotion.samples.first?.time, let last = savedMotion.samples.last?.time,
               time >= first, time <= last, !savedMotion.isMissing(at: time), let box = savedMotion.box(at: time) {
                return .init(id: id, box: box, memory: memory, recovering: false, recoveryAge: 0)
            }
            return .init(id: id, box: trajectory.predicted(at: time) ?? previous, memory: memory,
                  recovering: recovering, recoveryAge: recoveryAge(at: time), alternative: recovering ? lastSeen : nil,
                  isProvisional: isProvisional)
        }
    }

    var identities: [Identity] = []
    let start: Double

    init(start: Double, priors: [PlayerRosterPrior]) {
        self.start = start
        for prior in priors {
            let memory = PlayerIdentityMemory.resuming(prior.memory, jersey: prior.motion.jerseyProfile)
            // An unconfirmed saved kit cannot recognise anyone safely; that
            // player keeps its old track and may be corrected by hand.
            guard memory.isConfirmed else { continue }
            var identity = Identity(id: prior.id, memory: memory, isProvisional: false, isNew: false, previousTime: start)
            identity.savedMotion = prior.motion.observedOnly
            if let box = prior.motion.box(at: start) {
                identity.previous = box
            } else {
                // Recognise on appearance anywhere, with dormant strictness.
                identity.missingSince = start - PlayerTrackingLimits.maximumRecoverySeconds - 1
            }
            identities.append(identity)
        }
    }

    var needsCameraRegistration: Bool { identities.contains { !$0.isProvisional && $0.recovering } }
    var wantsNumberReads: Bool { identities.contains { !$0.isProvisional && $0.recovering && $0.memory.number.confirmed != nil } }
    var activeBoxes: [CGRect] { identities.compactMap { $0.recovering || $0.isProvisional ? nil : $0.previous } }

    /// Returns accepted (identity id, observation) pairs. Ids, not indices:
    /// provisional bodies may be dropped, and focused searches add observations.
    mutating func step(time: Double, camera: CameraTransform?, absolute: CameraTransform?,
                       observations: [PlayerObservation],
                       focused: (CGRect, [CGRect]) -> [PlayerObservation] = { _, _ in [] }) -> [(UUID, PlayerObservation)] {
        var observations = observations
        if let camera {
            for index in identities.indices {
                identities[index].trajectory.applyCamera(camera)
                if let previous = identities[index].previous,
                   let feet = camera.point(.init(x: previous.midX, y: previous.maxY)), abs(feet.x) < 4, abs(feet.y) < 4 {
                    identities[index].previous = CGRect(x: feet.x - previous.width / 2, y: feet.y - previous.height,
                                                        width: previous.width, height: previous.height)
                }
            }
        }
        var expectations = identities.map { $0.expectation(at: time) }
        if let offset = PlayerRosterAssociation.crowdOffset(expectations, observations: observations) {
            PlayerTrackingLimits.trace?(String(format: "%.3f ROSTER crowd offset %.3f,%.3f", time, offset.x, offset.y))
            expectations = expectations.map { expectation in
                guard expectation.recovering, !expectation.dormant, let box = expectation.box else { return expectation }
                return .init(id: expectation.id, box: box.offsetBy(dx: offset.x, dy: offset.y), memory: expectation.memory,
                             recovering: true, recoveryAge: expectation.recoveryAge, alternative: expectation.alternative,
                             isProvisional: expectation.isProvisional)
            }
        }
        var result = PlayerRosterAssociation.assign(expectations, observations: observations)
        // Players that just dropped out get a zoomed search around their
        // prediction before anyone else may claim a nearby body.
        let searches = identities.filter { identity in
            !identity.isProvisional && result.assignment(for: identity.id) == nil &&
                (identity.recovering ? identity.recoveryAge(at: time) < 1 : true)
        }.sorted { $0.previousTime > $1.previousTime }.prefix(3)
        var added = false
        for identity in searches {
            guard let expectation = expectations.first(where: { $0.id == identity.id }), let expected = expectation.box else { continue }
            var regions = [expected]
            if let alternative = expectation.alternative, hypot(alternative.midX - expected.midX, alternative.maxY - expected.maxY) > max(0.02, expected.width) {
                regions.append(alternative)
            }
            for region in regions {
                let found = focused(region, observations.map(\.box))
                if !found.isEmpty { observations += found; added = true }
            }
        }
        if added { result = PlayerRosterAssociation.assign(expectations, observations: observations) }
        var accepted: [(UUID, PlayerObservation)] = []
        for index in identities.indices {
            guard let assignment = result.assignment(for: identities[index].id) else {
                if PlayerTrackingLimits.trace != nil, !identities[index].isProvisional,
                   let expected = expectations.first(where: { $0.id == identities[index].id })?.box {
                    let nearby = observations.filter { hypot($0.box.midX - expected.midX, $0.box.maxY - expected.maxY) < max(0.06, expected.height) }
                    let cues = nearby.map { String(format: "%.3f,%.3f=%.2f crowded=%d", $0.box.midX, $0.box.maxY,
                                                  identities[index].memory.similarity(to: $0) ?? -1, $0.crowded ? 1 : 0) }.joined(separator: ";")
                    PlayerTrackingLimits.trace?(String(format: "%.3f ROSTER %@ missing ambiguous=%d near=%@", time,
                                                       String(identities[index].id.uuidString.prefix(8)), result.ambiguous.contains(identities[index].id) ? 1 : 0, cues))
                }
                if identities[index].missingSince == nil { identities[index].missingSince = identities[index].previousTime.nextUp }
                _ = identities[index].confirmation.accept(nil, at: time)
                continue
            }
            var observation = observations[assignment.observation]
            let merged = (!identities[index].recovering || identities[index].mergedSince != nil) && PlayerTrackingLimits.isMerged(observation.box, recentHeights: identities[index].recentHeights)
            if merged {
                // Someone passed in front: one box, two bodies. Follow it but
                // learn nothing; the body that comes out must still match.
                if identities[index].mergedSince == nil { identities[index].mergedSince = time }
                observation.crowded = true
            } else if identities[index].mergedSince != nil {
                if identities[index].memory.isConfirmed, (identities[index].memory.similarity(to: observation) ?? 0) < 0.75 {
                    PlayerTrackingLimits.trace?(String(format: "%.3f ROSTER %@ body out of merge fails identity: hiding", time, String(identities[index].id.uuidString.prefix(8))))
                    identities[index].mergedSince = nil
                    identities[index].missingSince = identities[index].previousTime.nextUp
                    continue
                }
                identities[index].mergedSince = nil
            }
            let wasRecovering = identities[index].recovering
            PlayerTrackingLimits.trace?(String(format: "%.3f ROSTER %@ assign score=%.2f at %.3f,%.3f w%.3f recovering=%d age=%.2f expected=%@", time, String(identities[index].id.uuidString.prefix(8)), assignment.score, observation.box.midX, observation.box.maxY, observation.box.width, wasRecovering ? 1 : 0, identities[index].recoveryAge(at: time), expectations.first { $0.id == identities[index].id }?.box.map { String(format: "%.3f,%.3f", $0.midX, $0.maxY) } ?? "-"))
            if wasRecovering {
                let recoveryAge = identities[index].recoveryAge(at: time)
                let dormant = recoveryAge > PlayerTrackingLimits.maximumRecoverySeconds
                guard identities[index].confirmation.accept(observation.box, at: time, camera: absolute,
                                                            requiredObservations: dormant ? 3 : 2,
                                                            maximumInterval: dormant ? 0.6 : 0.3) else { continue }
                if let missing = identities[index].missingSince, missing >= start {
                    identities[index].gaps.append(missing...time.nextDown)
                }
                identities[index].missingSince = nil
                identities[index].trajectory = PlayerTrackingTrajectory()
                if identities[index].mergedSince == nil || recoveryAge > 1.5 {
                    identities[index].recentHeights = []; identities[index].mergedSince = nil
                }
                identities[index].recoveries += 1
            } else if observation.crowded, !identities[index].memory.isConfirmed {
                // A provisional body inside an overlap may be the wrong one.
                identities[index].missingSince = identities[index].previousTime.nextUp
                continue
            }
            identities[index].samples.append(.init(time: time, box: observation.box))
            if !merged, !PlayerPresence.leftFrame(observation.box) { identities[index].recentHeights.append(observation.box.height); if identities[index].recentHeights.count > 20 { identities[index].recentHeights.removeFirst() } }
            identities[index].trajectory.append(.init(time: time, box: observation.box))
            identities[index].previous = observation.box
            identities[index].lastSeen = observation.box
            identities[index].previousTime = time
            identities[index].hits += 1
            if !observation.crowded { identities[index].clearHits += 1 }
            if identities[index].firstSeen == nil { identities[index].firstSeen = time }
            if !wasRecovering {
                identities[index].memory.learn(observation, clear: !observation.crowded && !result.contested.contains(assignment.observation))
            }
            if !wasRecovering, !observation.crowded, !PlayerPresence.leftFrame(observation.box) {
                accepted.append((identities[index].id, observation))
            }
        }
        var activeCount = identities.filter { !$0.recovering || $0.recoveryAge(at: time) <= PlayerTrackingLimits.maximumRecoverySeconds }.count
        for (index, observation) in observations.enumerated() where !result.claimed.contains(index) {
            guard activeCount < PlayerRosterTracking.maximumActiveIdentities, observation.jersey != nil, !observation.crowded,
                  observation.box.minX > 0.005, observation.box.maxX < 0.995,
                  observation.box.minY > 0.005, observation.box.maxY < 0.995,
                  !identities.contains(where: { identity in
                      (!identity.recovering || identity.recoveryAge(at: time) <= PlayerTrackingLimits.maximumRecoverySeconds) &&
                          (identity.previous.map { PlayerTracker.overlap($0, observation.box) > 0.3 } ?? false)
                  }) else { continue }
            var identity = Identity(id: UUID(), memory: PlayerIdentityMemory(), isProvisional: true, isNew: true, previousTime: time)
            identity.memory.learn(observation, clear: true)
            identity.samples = [.init(time: time, box: observation.box)]
            identity.trajectory.append(.init(time: time, box: observation.box))
            identity.previous = observation.box
            identity.lastSeen = observation.box
            identity.hits = 1; identity.clearHits = 1; identity.firstSeen = time
            identities.append(identity)
            activeCount += 1
        }
        var dropped: Set<UUID> = []
        for index in identities.indices where identities[index].isProvisional {
            let identity = identities[index]
            if identity.recovering, time - (identity.missingSince ?? time) > 0.5 { dropped.insert(identity.id); continue }
            if !identity.memory.isConfirmed, time - (identity.firstSeen ?? time) > 4 { dropped.insert(identity.id); continue }
            guard identity.memory.isConfirmed, identity.clearHits >= 6, time - (identity.firstSeen ?? time) >= 0.5,
                  let assignment = result.assignment(for: identity.id), !result.contested.contains(assignment.observation) else { continue }
            // Late re-identification: a body followed clearly for half a
            // second is compared with the missing players before it becomes
            // a new one. A blurred pan then returns the same roster, not twins.
            if let owner = returningOwner(of: identity, at: time) {
                PlayerTrackingLimits.trace?(String(format: "%.3f ROSTER merge body at %.3f,%.3f into %@", time, identity.previous?.midX ?? -1, identity.previous?.maxY ?? -1, String(identities[owner].id.uuidString.prefix(8))))
                merge(provisional: index, into: owner)
                dropped.insert(identity.id)
                continue
            }
            identities[index].isProvisional = false
        }
        identities.removeAll { dropped.contains($0.id) }
        return accepted
    }

    /// Join a new tracklet only with motion continuity or an individually
    /// recognized return. Squad size and the number of missing teammates are
    /// never evidence that two bodies are the same person.
    private func returningOwner(of body: Identity, at time: Double) -> Int? {
        guard let box = body.previous, let anchor = body.memory.jersey.examples.first else { return nil }
        func observation(_ identity: Identity, box: CGRect) -> PlayerObservation {
            PlayerObservation(box: box, jersey: identity.memory.jersey.examples.first,
                              shorts: identity.memory.shorts.examples.first, number: identity.memory.number.confirmed,
                              chroma: identity.memory.chroma?.examples.first, print: identity.memory.gallery?.prints.last)
        }
        var seen = observation(body, box: box)
        seen.jersey = anchor
        var ranked: [(index: Int, score: CGFloat)] = []
        for (index, identity) in identities.enumerated()
        where !identity.isProvisional && identity.recovering && identity.memory.isConfirmed {
            guard let missing = identity.missingSince, (body.firstSeen ?? time) > missing else { continue }
            let expected = identity.expectation(at: time)
            if let match = PlayerRosterAssociation.matches(for: expected, observations: [seen]).first {
                ranked.append((index, match.score))
            }
        }
        ranked.sort { $0.score > $1.score }
        guard let best = ranked.first,
              ranked.count == 1 || best.score - ranked[1].score >= PlayerIdentityAssociation.margin(recovering: true, dormant: true) else { return nil }
        let owner = identities[best.index], expected = owner.expectation(at: time)
        for rival in identities where rival.isProvisional && rival.id != body.id {
            guard let rivalBox = rival.previous, let missing = owner.missingSince,
                  (rival.firstSeen ?? time) > missing else { continue }
            if let match = PlayerRosterAssociation.matches(for: expected, observations: [observation(rival, box: rivalBox)]).first,
               match.score >= best.score - PlayerIdentityAssociation.margin(recovering: true, dormant: expected.dormant) { return nil }
        }
        return best.index
    }

    private mutating func merge(provisional index: Int, into owner: Int) {
        let body = identities[index]
        if let missing = identities[owner].missingSince, let first = body.samples.first?.time, first > missing, missing >= start {
            identities[owner].gaps.append(missing...first.nextDown)
        }
        identities[owner].missingSince = nil
        identities[owner].samples = (identities[owner].samples + body.samples).sorted { $0.time < $1.time }
        identities[owner].trajectory = body.trajectory
        identities[owner].previous = body.previous
        identities[owner].lastSeen = body.lastSeen
        identities[owner].previousTime = body.previousTime
        identities[owner].hits += body.hits
        identities[owner].clearHits += body.clearHits
        identities[owner].recoveries += 1
        identities[owner].confirmation = PlayerRecoveryConfirmation()
    }

    func finish() -> [PlayerRosterResult.Entry] {
        identities.compactMap { identity in
            guard !identity.isProvisional, identity.samples.count >= 2 else { return nil }
            var motion = PlayerMotion(samples: identity.samples)
            motion.lostAt = identity.missingSince.flatMap { $0 > (identity.samples.last?.time ?? start) ? $0 : nil }
            motion.gaps = identity.gaps.isEmpty ? nil : identity.gaps
            motion.recoveryCount = identity.recoveries > 0 ? identity.recoveries : nil
            motion.trackID = identity.id
            motion.jerseyProfile = identity.memory.jersey
            motion.gapBridging = PlayerMotion.defaultGapBridging
            motion.hidesUncertainPositions = true
            return .init(id: identity.id, motion: motion, memory: identity.memory, isNew: identity.isNew)
        }
    }
}

/// Sparse back-number reads on the torso. Fast recognition without language
/// correction; anything that is not one or two digits is discarded.
final class ShirtNumberReader {
    private let request: VNRecognizeTextRequest
    private let context = CIContext(options: [.cacheIntermediates: false])

    init() {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.1
        self.request = request
    }

    /// Crop the torso and scale it up before recognition: digits on a distant
    /// player are a dozen pixels tall in the frame, too small for the model.
    func read(_ buffer: CVPixelBuffer, box: CGRect, orientation: CGImagePropertyOrientation) -> String? {
        let region = CGRect(x: box.minX + box.width * 0.1, y: box.minY + box.height * 0.1,
                            width: box.width * 0.8, height: box.height * 0.45)
        let clamped = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0.01, clamped.height > 0.01 else { return nil }
        let source = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let extent = source.extent
        let crop = CGRect(x: extent.minX + clamped.minX * extent.width, y: extent.minY + (1 - clamped.maxY) * extent.height,
                          width: clamped.width * extent.width, height: clamped.height * extent.height).integral
        guard crop.width >= 4, crop.height >= 4 else { return nil }
        let scale = min(6, max(1, 160 / crop.height))
        let scaled = source.cropped(to: crop).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return nil }
        let candidates = (request.results ?? []).compactMap { observation -> (String, Float)? in
            guard let best = observation.topCandidates(1).first, best.confidence >= 0.5 else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return PlayerNumberVotes.isShirtNumber(text) ? (text, best.confidence) : nil
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }
}
