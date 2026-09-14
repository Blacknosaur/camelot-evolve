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
        cameras.last { $0.transform(at: time) != nil }
    }
}

extension PlayerMotion {
    var correctionTime: Double? {
        guard let lostAt else { return nil }
        return samples.last(where: { $0.time < lostAt })?.time ?? samples.first?.time ?? lostAt
    }
    /// Preserve confirmed history and explicit missing intervals when correcting
    /// one identity. Attached effects keep their own bind pose when stored.
    func continuing(with motion: Self, from start: Double) -> Self {
        var result = self
        result.samples = samples.filter { $0.time < start } + motion.samples
        result.lostAt = motion.lostAt
        var intervals = gaps?.filter { $0.lowerBound < start }.map { $0.lowerBound...min($0.upperBound, start.nextDown) } ?? []
        if let lostAt, lostAt < start { intervals.append(lostAt...start.nextDown) }
        result.gaps = intervals + (motion.gaps ?? [])
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
            if var motion = annotations[index].cameraMotion, motion.trackID == nil {
                motion.trackID = annotations[index].id
                annotations[index].cameraMotion = motion
                storeCameraTrack(motion)
            }
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
