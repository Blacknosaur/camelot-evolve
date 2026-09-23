import CoreGraphics
import Foundation

/// Segmentation continuity for a body already accepted by the identity tracker.
/// Mask quality controls visual output; it cannot establish player identity.
enum PlayerTrackingState: String, Codable, Sendable, CaseIterable {
    /// Clear view, high confidence. The only state that may teach identity.
    case tracking
    /// Something is over part of the player. Keep following, learn nothing.
    case partiallyOccluded
    /// The player is behind something. Position is predicted, not observed.
    case occluded
    /// Position is no longer predictable; candidates are being evaluated.
    case searching
    /// A candidate passed the identity gates. One frame of grace before the
    /// segmenter is re-prompted and normal tracking resumes.
    case reacquired
    /// Given up. Only an explicit user correction restarts the track.
    case lost

    /// Is the player's position still believed, even if unobserved?
    var isFollowing: Bool { self == .tracking || self == .partiallyOccluded || self == .reacquired }
    /// Should a mask be drawn for the user on this frame?
    var producesMask: Bool { self == .tracking || self == .partiallyOccluded || self == .reacquired }
}

/// What a frame is permitted to change, given how sure the tracker is.
///
/// The point of separating this from the state machine is that memory poisoning
/// is a *policy* failure, not a control-flow one: the bug is always "we learned
/// during an occlusion", and that is much easier to see, and to test, when the
/// permission is a value rather than a branch buried in a loop.
struct PlayerMemoryPolicy: Equatable, Sendable {
    /// Recent-appearance memory, which is allowed to drift with pose and light.
    var updatesWorkingMemory: Bool
    /// Long-term identity: kit, tone, embedding gallery, number. Poisoning this
    /// is unrecoverable within a pass, so it is the most guarded thing here.
    var updatesIdentityMemory: Bool

    static let learning = PlayerMemoryPolicy(updatesWorkingMemory: true, updatesIdentityMemory: true)
    static let adapting = PlayerMemoryPolicy(updatesWorkingMemory: true, updatesIdentityMemory: false)
    static let frozen = PlayerMemoryPolicy(updatesWorkingMemory: false, updatesIdentityMemory: false)
}

/// Confidence bands. Initial values only — they are meant to be tuned against
/// real football footage, and the benchmark exists to do exactly that.
enum PlayerTrackConfidence {
    /// Above this the observation is trusted enough to teach identity.
    nonisolated(unsafe) static var certain: Float = 0.90
    /// Above this the player is still being followed, but nothing is learned.
    nonisolated(unsafe) static var usable: Float = 0.70
    /// Frames of sustained low confidence before a partial occlusion is treated
    /// as a full one. One bad frame is noise; a run of them is an occlusion.
    nonisolated(unsafe) static var occlusionPatience = 3
    /// Seconds of searching before the track is abandoned.
    nonisolated(unsafe) static var searchHorizon = 2.5

    enum Band: Equatable { case certain, uncertain, failing }

    static func band(_ confidence: Float) -> Band {
        if confidence >= certain { return .certain }
        if confidence >= usable { return .uncertain }
        return .failing
    }
}

/// Pure mask-confidence hysteresis. The legacy learning-policy result is only
/// advisory; SelectedPlayerTracking separately gates all identity observations.
struct PlayerTrackMachine: Sendable {
    private(set) var state: PlayerTrackingState = .tracking
    /// Source time of the last frame the player was actually observed.
    private(set) var lastVisibleTime: Double
    /// Consecutive low-confidence frames, used to tell noise from occlusion.
    private var failingFrames = 0

    init(startingAt time: Double) { lastVisibleTime = time }

    /// One frame of evidence.
    ///
    /// `confidence` is predicted mask quality. `reacquired` is supplied only
    /// after an independent identity decision or explicit correction.
    @discardableResult
    mutating func advance(confidence: Float, at time: Double,
                          reacquired: Bool = false) -> PlayerMemoryPolicy {
        if state == .lost { return .frozen }
        if reacquired {
            state = .reacquired
            lastVisibleTime = time
            failingFrames = 0
            // A reacquisition is a hypothesis that just passed its gates, not a
            // fact. It re-prompts the segmenter but teaches identity nothing:
            // if the gates were wrong, learning here would make the mistake
            // permanent.
            return .adapting
        }

        switch PlayerTrackConfidence.band(confidence) {
        case .certain:
            state = .tracking
            lastVisibleTime = time
            failingFrames = 0
            return .learning

        case .uncertain:
            lastVisibleTime = time
            failingFrames = 0
            // Still visible enough to follow, but a confident-looking mask
            // during a crossing is exactly how a tracker changes player.
            state = .partiallyOccluded
            return .adapting

        case .failing:
            failingFrames += 1
            if state == .searching || time - lastVisibleTime > PlayerTrackConfidence.searchHorizon {
                state = time - lastVisibleTime > PlayerTrackConfidence.searchHorizon ? .lost : .searching
            } else if failingFrames >= PlayerTrackConfidence.occlusionPatience {
                state = .occluded
            } else {
                state = .partiallyOccluded
            }
            return .frozen
        }
    }

    /// The recovery search could not place the player this frame.
    mutating func search(at time: Double) {
        guard state != .lost else { return }
        state = time - lastVisibleTime > PlayerTrackConfidence.searchHorizon ? .lost : .searching
    }

    /// An explicit user correction: the one thing that outranks the machine.
    mutating func correct(at time: Double) {
        state = .tracking
        lastVisibleTime = time
        failingFrames = 0
    }
}
