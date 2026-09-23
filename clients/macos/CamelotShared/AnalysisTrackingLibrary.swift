import Foundation
import CoreGraphics

/// Clip-owned source-time tracks survive deleting an effect. Annotations retain
/// render-ready snapshots for existing preview/export and backwards compatibility.
struct AnalysisTrackingLibrary: Codable, Equatable, Sendable {
    struct Player: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var motion: PlayerMotion
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

    func camera(at time: Double) -> AnnotationCameraMotion? {
        guard let camera = sharedCamera, camera.transform(at: time) != nil else { return nil }
        return camera
    }
}

extension PlayerMotion {
    var correctionTime: Double? {
        guard let lostAt else { return nil }
        return samples.last(where: { $0.time < lostAt })?.time ?? samples.first?.time ?? lostAt
    }
    func repairEnd(from start: Double, to end: Double) -> Double {
        min(end, correctionTimes?.filter { $0 > start + 1 / 60 }.min() ?? end)
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
        return true
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

    mutating func storePlayerTrack(_ motion: PlayerMotion) {
        guard let id = motion.trackID else { return }
        var library = trackingLibrary ?? .init()
        var source = motion; source.referenceBox = nil; source.smoothing = nil
        if let index = library.players.firstIndex(where: { $0.id == id }) { library.players[index].motion = source }
        else { library.players.append(.init(id: id, name: "Player \(library.players.count + 1)", motion: source)) }
        trackingLibrary = library
        func refreshed(_ old: PlayerMotion) -> PlayerMotion {
            guard old.trackID == id else { return old }
            var updated = source
            updated.referenceBox = old.reference
            updated.smoothing = old.smoothing
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
