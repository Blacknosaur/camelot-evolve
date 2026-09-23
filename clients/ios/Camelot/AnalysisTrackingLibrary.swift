import Foundation
import CoreGraphics

enum PlayerTrackingTeam: String, Codable, CaseIterable, Identifiable, Sendable {
    case teamA, teamB, referee, unassigned
    var id: Self { self }
    var title: String {
        switch self {
        case .teamA: "Team A"
        case .teamB: "Team B"
        case .referee: "Referee"
        case .unassigned: "Unassigned"
        }
    }
}

/// Clip-owned source-time tracks survive deleting an effect. Annotations retain
/// render-ready snapshots for existing preview/export and backwards compatibility.
struct AnalysisTrackingLibrary: Codable, Equatable, Sendable {
    struct Player: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var motion: PlayerMotion
        /// Roster memory (kit, shorts, shirt number). Nil for tracks made by
        /// older passes; the next roster pass learns one when it recognises them.
        var identity: PlayerIdentityMemory? = nil
        /// Explicit assignment; never infer team membership from a track ID.
        var team: PlayerTrackingTeam? = nil
        var assignedTeam: PlayerTrackingTeam { team ?? .unassigned }

        var number: String? { identity?.number.confirmed }
        var kitColor: AnnotationColor? {
            guard let color = identity?.kitColor, color.count == 3 else { return nil }
            return .init(red: Double(color[0]), green: Double(color[1]), blue: Double(color[2]))
        }
    }
    var players: [Player] = []
    var cameras: [AnnotationCameraMotion] = []
    /// Older camera snapshots stay available for backwards-compatible bindings.
    /// Only this clip-wide track is offered for new camera-following effects.
    var sharedCameraID: UUID? = nil

    var sharedCamera: AnnotationCameraMotion? {
        if let sharedCameraID, let camera = cameras.first(where: { $0.trackID == sharedCameraID }) { return camera }
        return cameras.max { $0.coveredDuration < $1.coveredDuration }
    }

    /// Drawing snapshots deliberately omit identity. Every tracking entry point
    /// must restore the clip-owned memory before resuming a bound effect.
    func resuming(_ motion: PlayerMotion) -> PlayerMotion {
        guard let player = players.first(where: { $0.id == motion.trackID }), let memory = player.identity else { return motion }
        var result = motion
        result.identity = memory
        if !memory.jersey.examples.isEmpty { result.jerseyProfile = memory.jersey }
        return result
    }

    func player(matching box: CGRect, at time: Double) -> Player? {
        let candidates = players.compactMap { track -> (Player, CGFloat)? in
            guard let tracked = track.motion.box(at: time) else { return nil }
            let overlap = PlayerTracker.overlap(tracked, box)
            return overlap > 0.55 ? (track, overlap) : nil
        }.sorted { $0.1 > $1.1 }
        guard let best = candidates.first,
              candidates.count == 1 || best.1 > candidates[1].1 * 1.4 else { return nil }
        return best.0
    }

    /// User-confirmed fragments may be linked unless both tracks locate the
    /// person in different places at the same source time. Check both sample
    /// grids, including manual frames, rather than only the track endpoints.
    func canLinkPlayer(_ sourceID: UUID, to targetID: UUID) -> Bool {
        guard sourceID != targetID,
              let source = players.first(where: { $0.id == sourceID }),
              let target = players.first(where: { $0.id == targetID }),
              !source.motion.samples.isEmpty, !target.motion.samples.isEmpty,
              source.assignedTeam == .unassigned || target.assignedTeam == .unassigned || source.assignedTeam == target.assignedTeam else { return false }
        let a = source.motion.observedOnly, b = target.motion.observedOnly
        for sample in a.samples + b.samples {
            guard let left = a.box(at: sample.time), let right = b.box(at: sample.time) else { continue }
            if PlayerTracker.overlap(left, right) < 0.5 { return false }
        }
        return true
    }

    func camera(at time: Double) -> AnnotationCameraMotion? {
        guard let camera = sharedCamera, camera.transform(at: time) != nil else { return nil }
        return camera
    }
}

extension PlayerMotion {
    var observedOnly: Self {
        var result = self
        result.inferred = nil; result.smoothing = 0; result.hidesUncertainPositions = true
        return result
    }

    /// The user established that both tracks describe the same person. Keep
    /// both sets of observations; a gap remains only where neither saw them.
    func linkingObservations(from source: Self) -> Self {
        guard let first = (samples + source.samples).map(\.time).min(),
              let last = (samples + source.samples).map(\.time).max() else { return self }
        var result = self
        let targetSamples = samples.filter { !isMissing(at: $0.time) }
        let targetTimes = Set(targetSamples.map(\.time))
        result.samples = (targetSamples + source.samples.filter { !source.isMissing(at: $0.time) && !targetTimes.contains($0.time) }).sorted { $0.time < $1.time }
        for time in source.anchors ?? [] where !(anchors ?? []).contains(time) {
            if let manual = source.samples.first(where: { abs($0.time - time) < 1 / 600 }),
               let index = result.samples.firstIndex(where: { abs($0.time - time) < 1 / 600 }) {
                result.samples[index] = manual
            }
        }
        let missingA = observedOnly.missingIntervals(in: first...last)
        let missingB = source.observedOnly.missingIntervals(in: first...last)
        let gaps = missingA.flatMap { a in
            missingB.compactMap { b -> ClosedRange<Double>? in
                let start = max(a.lowerBound, b.lowerBound), end = min(a.upperBound, b.upperBound)
                return start <= end ? start...end : nil
            }
        }.sorted { $0.lowerBound < $1.lowerBound }
        result.gaps = gaps.isEmpty ? nil : gaps
        result.lostAt = [self, source].filter { $0.samples.last?.time == last }.allSatisfy { $0.lostAt != nil } ? last.nextUp : nil
        result.anchors = Array(Set((anchors ?? []) + (source.anchors ?? []))).sorted()
        result.correctionTimes = Array(Set((correctionTimes ?? []) + (source.correctionTimes ?? []))).sorted()
        result.recoveryCount = (recoveryCount ?? 0) + (source.recoveryCount ?? 0)
        result.inferred = nil; result.hidesUncertainPositions = true
        return result
    }

    var correctionTime: Double? {
        guard let lostAt else { return nil }
        return samples.last(where: { $0.time < lostAt })?.time ?? samples.first?.time ?? lostAt
    }
    func repairEnd(from start: Double, to end: Double) -> Double {
        min(end, ((correctionTimes ?? []) + (anchors ?? [])).filter { $0 > start + 1 / 600 }.min() ?? end)
    }

    func repairStart(from start: Double, to end: Double) -> Double {
        max(end, ((correctionTimes ?? []) + (anchors ?? [])).filter { $0 < start - 1 / 600 }.max() ?? end)
    }

    /// Splice only the completed repair, never truncate the saved future. Missing
    /// intervals outside that section and subsequent explicit picks survive.
    func continuing(with motion: Self, from start: Double) -> Self {
        let boundary = repairEnd(from: start, to: .infinity)
        let replacement = motion.samples.filter { $0.time >= start && $0.time < boundary }
        guard let finish = replacement.last?.time else { return self }
        let range = start...finish
        var result = self
        let before = samples.filter { $0.time < start }, after = samples.filter { $0.time > finish }
        result.samples = before + replacement + after
        var unavailable = gaps ?? []
        if let lostAt, let last = samples.last?.time, lostAt <= last { unavailable.append(lostAt...last) }
        var intervals = unavailable.flatMap { gap -> [ClosedRange<Double>] in
            guard gap.overlaps(range) else { return [gap] }
            var pieces: [ClosedRange<Double>] = []
            if gap.lowerBound < start { pieces.append(gap.lowerBound...start.nextDown) }
            if gap.upperBound > finish { pieces.append(finish.nextUp...gap.upperBound) }
            return pieces
        }
        intervals += (motion.gaps ?? []).compactMap { gap in
            let lower = max(start, gap.lowerBound), upper = min(finish, gap.upperBound)
            return lower <= upper ? lower...upper : nil
        }
        // Never interpolate across a previously untracked interval between runs.
        if let last = before.last?.time, start - last > 0.12 {
            let lower = lostAt.flatMap { $0 > last && $0 < start ? $0 : nil } ?? last.nextUp
            intervals.append(lower...start.nextDown)
        }
        if let next = after.first?.time, next - finish > 0.12 { intervals.append(finish.nextUp...next.nextDown) }
        let hasConfirmedFuture = after.contains { sample in
            (lostAt.map { sample.time < $0 } ?? true) && !(gaps?.contains { $0.contains(sample.time) } ?? false)
        }
        result.lostAt = hasConfirmedFuture ? lostAt : motion.lostAt
        if !hasConfirmedFuture, result.lostAt == nil, !after.isEmpty { result.lostAt = finish.nextUp }
        result.gaps = intervals.sorted { $0.lowerBound < $1.lowerBound }
        var anchors = correctionTimes ?? samples.first.map { [$0.time] } ?? []
        anchors.removeAll { abs($0 - start) < 1 / 60 }
        anchors.append(start)
        result.correctionTimes = anchors.sorted()
        result.recoveryCount = (recoveryCount ?? 0) + (motion.recoveryCount ?? 0)
        result.jerseyProfile = motion.jerseyProfile ?? jerseyProfile
        result.identity = motion.identity ?? identity
        // Hand placements inside the repaired section are superseded by the
        // new confirmed tracking; bridged positions are rebuilt when stored.
        let placed = (self.anchors ?? []).filter { !range.contains($0) }
        result.anchors = placed.isEmpty ? nil : placed
        result.inferred = nil
        result.gapBridging = gapBridging ?? motion.gapBridging
        result.hidesUncertainPositions = motion.hidesUncertainPositions ?? hidesUncertainPositions
        result.automaticallyInterpolatesTinyGaps = motion.automaticallyInterpolatesTinyGaps ?? automaticallyInterpolatesTinyGaps
        return result
    }

    /// Replace only the completed backward section. Earlier manual selections
    /// and tracking outside this pass survive, just as they do for a forward fix.
    func prepending(_ earlier: Self, seed start: Double) -> Self {
        let boundary = repairStart(from: start, to: -.infinity)
        let replacement = earlier.samples.filter { $0.time > boundary && $0.time < start }
        guard let first = replacement.first?.time, let last = replacement.last?.time else { return self }
        let range = first...last
        // The backward pass observes its seed too. A cleared redo range must
        // not leave a tiny missing interval between its last earlier sample
        // and that seed. Actual missing intervals from the pass are re-added.
        let coveredEnd = earlier.samples.last.map { abs($0.time - start) < 1 / 600 ? start : last } ?? last
        let covered = first...coveredEnd
        var result = self
        result.samples = samples.filter { $0.time < first } + replacement + samples.filter { $0.time >= start }
        var intervals = (gaps ?? []).flatMap { gap -> [ClosedRange<Double>] in
            guard gap.overlaps(covered) else { return [gap] }
            var remaining: [ClosedRange<Double>] = []
            if gap.lowerBound < first { remaining.append(gap.lowerBound...first.nextDown) }
            if gap.upperBound > coveredEnd { remaining.append(coveredEnd.nextUp...gap.upperBound) }
            return remaining
        }
        intervals += (earlier.gaps ?? []).compactMap { gap in
            let lower = max(first, gap.lowerBound), upper = min(coveredEnd, gap.upperBound)
            return lower <= upper ? lower...upper : nil
        }
        if let previous = samples.last(where: { $0.time < first }), first - previous.time > 0.12 {
            intervals.append(previous.time.nextUp...first.nextDown)
        }
        if let next = samples.first(where: { $0.time >= start }), next.time - last > 0.12 {
            intervals.append(last.nextUp...next.time.nextDown)
        }
        result.gaps = intervals.isEmpty ? nil : intervals.sorted { $0.lowerBound < $1.lowerBound }
        result.correctionTimes = Array(Set((correctionTimes ?? []).filter { !range.contains($0) } + [start])).sorted()
        result.anchors = (anchors ?? []).filter { !range.contains($0) }
        if result.anchors?.isEmpty == true { result.anchors = nil }
        result.inferred = nil
        result.hidesUncertainPositions = earlier.hidesUncertainPositions ?? hidesUncertainPositions
        result.automaticallyInterpolatesTinyGaps = earlier.automaticallyInterpolatesTinyGaps ?? automaticallyInterpolatesTinyGaps
        result.recoveryCount = (recoveryCount ?? 0) + (earlier.recoveryCount ?? 0)
        result.jerseyProfile = jerseyProfile ?? earlier.jerseyProfile
        result.identity = earlier.identity ?? identity
        return result
    }

    func bound(at time: Double, smoothing: Double? = nil) -> Self? {
        var result = self
        result.smoothing = smoothing ?? self.smoothing
        guard let box = result.box(at: time) else { return nil }
        result.referenceBox = box
        return result
    }
}

extension CompositionClip {
    /// Rebind one layer without mutating either source track or its sibling
    /// effects. Preserve appearance and timing, including its player-relative offset.
    mutating func followSavedPlayer(_ player: AnalysisTrackingLibrary.Player, layerID: UUID, at time: Double) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == layerID }),
              annotations[index].isLocked != true, annotations[index].linkedPlayers == nil else { return false }
        var mark = annotations[index]
        let smoothing = mark.playerMotion?.smoothing ?? (mark.tool == .text ? 0.95 : nil)
        guard let bound = player.motion.bound(at: time, smoothing: smoothing), let box = bound.reference else { return false }
        let oldBox = mark.playerMotion?.box(at: time) ?? mark.playerMotion?.reference
        mark.makeStatic(at: time)
        if let oldBox {
            mark.points = mark.points.map { .init(x: $0.x + box.midX-oldBox.midX, y: $0.y + box.maxY-oldBox.maxY) }
        }
        mark.playerMotion = bound
        mark.playerMotion?.trackID = player.id
        mark.playerMotion?.smoothing = smoothing
        mark.playerEffectGroupID = UUID()
        annotations[index] = mark
        return true
    }

    /// Promote legacy baked tracks once, without running Vision again.
    mutating func importAnnotationTracks() {
        for index in annotations.indices {
            if var motion = annotations[index].playerMotion, motion.trackID == nil {
                motion.trackID = annotations[index].id
                annotations[index].playerMotion = motion
                storePlayerTrack(motion)
            }
            if let links = annotations[index].linkedPlayers {
                for anchor in links.indices where links[anchor].trackID == nil {
                    var motion = links[anchor]; motion.trackID = UUID()
                    annotations[index].linkedPlayers?[anchor] = motion
                    storePlayerTrack(motion)
                }
            }
            if var motion = annotations[index].cameraMotion {
                motion.trackID = motion.trackID ?? annotations[index].id
                annotations[index].cameraMotion = motion
                if trackingLibrary?.cameras.contains(where: { $0.trackID == motion.trackID }) != true { storeCameraTrack(motion) }
            }
            if var motion = annotations[index].trajectoryCameraMotion {
                motion.trackID = motion.trackID ?? annotations[index].id
                annotations[index].trajectoryCameraMotion = motion
                if trackingLibrary?.cameras.contains(where: { $0.trackID == motion.trackID }) != true { storeCameraTrack(motion) }
            }
        }
        // Field-only projects previously never promoted their saved camera pass.
        if var camera = groundCalibration?.cameraMotion {
            camera.trackID = camera.trackID ?? id
            groundCalibration?.cameraMotion = camera
            if trackingLibrary?.cameras.contains(where: { $0.trackID == camera.trackID }) != true { storeCameraTrack(camera) }
        }
        refreshSharedCameraBindings()
    }

    var cameraTrackingRange: ClosedRange<Double> {
        // Trimming must not discard the source frame on which saved geometry
        // was authored. Usually all these references are already inside the clip.
        var references = annotations.compactMap { $0.cameraMotion?.referenceTime ?? $0.cameraMotion?.samples.first?.time ?? $0.groundReferenceTime }
        if let ground = groundCalibration, !ground.fixedCamera { references.append(ground.referenceTime) }
        let finite = references.filter { $0.isFinite && $0 >= 0 }
        return min(startSeconds, finite.min() ?? startSeconds)...max(endSeconds, finite.max() ?? endSeconds)
    }
    var hasFullCameraTrack: Bool { trackingLibrary?.sharedCamera?.covers(cameraTrackingRange) == true }

    /// A failed rerun cannot erase a longer usable pass. New full-clip tracking
    /// refreshes all consumers, regardless of which old UI created their track.
    @discardableResult
    mutating func storeSharedCameraTrack(_ motion: AnnotationCameraMotion) -> Bool {
        if let old = trackingLibrary?.sharedCamera, !motion.covers(cameraTrackingRange),
           old.coveredDuration > motion.coveredDuration { return false }
        var source = motion; source.trackID = source.trackID ?? UUID(); source.referenceTime = nil
        storeCameraTrack(source)
        trackingLibrary?.sharedCameraID = source.trackID
        refreshSharedCameraBindings()
        rebridgePlayerTracks()
        return true
    }

    /// Bridged positions depend on the clip camera; rebuild them for every
    /// saved player and each drawing that follows one.
    mutating func rebridgePlayerTracks() {
        for player in trackingLibrary?.players ?? [] {
            var motion = player.motion; motion.trackID = player.id
            storePlayerTrack(motion)
        }
    }

    /// Fold a roster pass into the saved players. Recognised players keep
    /// their id and name; a pass that saw much less of a player than the saved
    /// track keeps the old track. Bodies the pass discovered become new players.
    @discardableResult
    mutating func mergeRoster(_ result: PlayerRosterResult) -> (tracked: Int, new: Int) {
        var tracked = 0, added = 0
        for entry in result.entries {
            var motion = entry.motion; motion.trackID = entry.id
            if let existing = trackingLibrary?.players.first(where: { $0.id == entry.id }) {
                if motion.samples.count * 2 < existing.motion.samples.count {
                    // Keep the fuller saved track, but remember the confirmed kit.
                    if let index = trackingLibrary?.players.firstIndex(where: { $0.id == entry.id }) {
                        trackingLibrary?.players[index].identity = entry.memory
                    }
                    continue
                }
                motion.gapBridging = existing.motion.gapBridging ?? motion.gapBridging
                // Automatic roster updates may not erase hand-confirmed frames.
                for time in existing.motion.anchors ?? [] {
                    if let sample = existing.motion.samples.first(where: { abs($0.time - time) < 1 / 600 }) {
                        motion.place(sample.box, at: time)
                    }
                }
            } else { added += 1 }
            tracked += 1
            storePlayerTrack(motion, identity: entry.memory)
        }
        return (tracked, added)
    }

    /// Hand-place a saved player where tracking never confirmed it. Drawings
    /// that follow the player pick the placement up through the shared track.
    mutating func placePlayerSample(trackID: UUID, box: CGRect, at time: Double) -> Bool {
        guard let player = trackingLibrary?.players.first(where: { $0.id == trackID }) else { return false }
        var motion = player.motion; motion.trackID = trackID
        motion.place(box, at: time)
        storePlayerTrack(motion)
        return true
    }

    func canRemovePlayerTrack(_ id: UUID) -> Bool {
        !annotations.contains { mark in
            mark.playerMotion?.trackID == id || mark.linkedPlayers?.contains { $0.trackID == id } == true
        }
    }

    mutating func removePlayerTrack(_ id: UUID) -> Bool {
        guard canRemovePlayerTrack(id) else { return false }
        trackingLibrary?.players.removeAll { $0.id == id }
        return true
    }

    @discardableResult
    mutating func assignPlayerTeam(_ team: PlayerTrackingTeam, to id: UUID) -> Bool {
        guard let index = trackingLibrary?.players.firstIndex(where: { $0.id == id }),
              trackingLibrary?.players[index].assignedTeam != team else { return false }
        trackingLibrary?.players[index].team = team == .unassigned ? nil : team
        return true
    }

    @discardableResult
    mutating func linkPlayerTrack(_ sourceID: UUID, to targetID: UUID) -> Bool {
        guard let library = trackingLibrary, library.canLinkPlayer(sourceID, to: targetID),
              let source = library.players.first(where: { $0.id == sourceID }),
              let target = library.players.first(where: { $0.id == targetID }) else { return false }
        var combined = target.motion.linkingObservations(from: source.motion)
        combined.trackID = targetID
        for index in annotations.indices {
            if annotations[index].playerMotion?.trackID == sourceID { annotations[index].playerMotion?.trackID = targetID }
            if let links = annotations[index].linkedPlayers {
                annotations[index].linkedPlayers = links.map { motion in
                    var updated = motion
                    if updated.trackID == sourceID { updated.trackID = targetID }
                    return updated
                }
            }
        }
        storePlayerTrack(combined, identity: target.identity ?? source.identity)
        if target.assignedTeam == .unassigned { assignPlayerTeam(source.assignedTeam, to: targetID) }
        trackingLibrary?.players.removeAll { $0.id == sourceID }
        return true
    }

    /// Per-drawing limit on how long an effect follows a bridged position.
    /// Source tracks are unchanged; siblings keep their own limit.
    mutating func setGapBridging(_ seconds: Double, layerID: UUID) {
        guard let index = annotations.firstIndex(where: { $0.id == layerID }), annotations[index].isLocked != true else { return }
        annotations[index].playerMotion?.gapBridging = seconds
        annotations[index].playerMotion?.hidesUncertainPositions = seconds <= 0
        if let links = annotations[index].linkedPlayers {
            annotations[index].linkedPlayers = links.map { var motion = $0; motion.gapBridging = seconds; motion.hidesUncertainPositions = seconds <= 0; return motion }
        }
    }

    mutating func refreshSharedCameraBindings() {
        guard let shared = trackingLibrary?.sharedCamera else { return }
        if let ground = groundCalibration, !ground.fixedCamera,
           shared.transform(at: ground.referenceTime) != nil {
            groundCalibration?.cameraMotion = shared
        }
        for index in annotations.indices {
            if let old = annotations[index].cameraMotion {
                let reference = old.referenceTime ?? old.samples.first?.time ?? annotations[index].start
                if shared.transform(at: reference) != nil {
                    var bound = shared; bound.referenceTime = reference
                    annotations[index].cameraMotion = bound
                }
            }
            if annotations[index].cameraMotion == nil, annotations[index].grounded == true,
               annotations[index].supportsGrounding, annotations[index].playerMotion == nil,
               annotations[index].linkedPlayers == nil, annotations[index].keyframes.isEmpty,
               groundCalibration?.fixedCamera == false {
                let reference = annotations[index].groundReferenceTime ?? annotations[index].start
                if shared.transform(at: reference) != nil {
                    var bound = shared; bound.referenceTime = reference
                    annotations[index].cameraMotion = bound
                }
            }
            if annotations[index].trajectoryCameraMotion != nil { annotations[index].trajectoryCameraMotion = shared }
        }
    }

    mutating func storePlayerTrack(_ motion: PlayerMotion, identity: PlayerIdentityMemory? = nil) {
        guard let id = motion.trackID else { return }
        var library = trackingLibrary ?? .init()
        var source = motion; source.referenceBox = nil; source.smoothing = nil
        let learned = identity ?? motion.identity
        source.identity = nil
        source = source.bridged(camera: library.sharedCamera)
        if let index = library.players.firstIndex(where: { $0.id == id }) {
            library.players[index].motion = source
            if let learned { library.players[index].identity = learned }
        } else {
            library.players.append(.init(id: id, name: "Player \(library.players.count + 1)", motion: source, identity: learned))
        }
        trackingLibrary = library
        func refreshed(_ old: PlayerMotion) -> PlayerMotion {
            guard old.trackID == id else { return old }
            var updated = source
            updated.referenceBox = old.reference
            updated.smoothing = old.smoothing
            updated.gapBridging = old.gapBridging ?? source.gapBridging
            return updated
        }
        // A lock protects authored geometry/timing, not shared source tracking.
        for index in annotations.indices {
            if let old = annotations[index].playerMotion { annotations[index].playerMotion = refreshed(old) }
            if let links = annotations[index].linkedPlayers { annotations[index].linkedPlayers = links.map(refreshed) }
        }
    }

    mutating func storeCameraTrack(_ motion: AnnotationCameraMotion) {
        guard let id = motion.trackID else { return }
        var library = trackingLibrary ?? .init()
        var source = motion; source.referenceTime = nil
        if let index = library.cameras.firstIndex(where: { $0.trackID == id }) { library.cameras[index] = source }
        else { library.cameras.append(source) }
        trackingLibrary = library
        for index in annotations.indices where annotations[index].cameraMotion?.trackID == id {
            var updated = source
            updated.referenceTime = annotations[index].cameraMotion?.referenceTime
            annotations[index].cameraMotion = updated
        }
        for index in annotations.indices where annotations[index].trajectoryCameraMotion?.trackID == id {
            annotations[index].trajectoryCameraMotion = source
        }
        if groundCalibration?.cameraMotion?.trackID == id { groundCalibration?.cameraMotion = source }
    }
}
