import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import simd

/// Persistent memory of one player for the whole clip: kit colours, a voted
/// shirt number and the confirmation state every tracking pass shares.
/// Identity lives with the saved player, not with any single drawing.
struct PlayerIdentityMemory: Codable, Equatable, Sendable {
    var jersey = PlayerJerseyProfile()
    var shorts = PlayerJerseyProfile()
    var number = PlayerNumberVotes()
    /// Mean torso colour of the first clear observation, for list swatches only.
    var kitColor: [Float]? = nil
    /// Skin/hair tone and legs/socks tone: what tells two same-kit players
    /// apart. Optional so memories saved before they existed still decode.
    var head: PlayerJerseyProfile? = nil
    var legs: PlayerJerseyProfile? = nil
    /// Torso chromaticity: separates kits the hue histogram merges under
    /// floodlights (blue vs white both read mostly "neutral").
    var chroma: PlayerJerseyProfile? = nil
    /// Learned look of the whole body (Vision feature prints), several references.
    var gallery: PlayerAppearanceGallery? = nil
    /// Like-for-like head/torso crops, also usable when the legs are offscreen.
    var upperBodyGallery: PlayerAppearanceGallery? = nil

    /// Explicit references survive automatic learning and are compared as whole views.
    var confirmedViews: [PlayerIdentityReference]? = nil

    var isConfirmed: Bool { jersey.isConfirmed || !(confirmedViews?.isEmpty ?? true) }

    mutating func confirm(_ observation: PlayerObservation, view: PlayerIdentityView = .unspecified) {
        guard observation.jersey != nil, !observation.crowded, !PlayerBodyExtent.isCropped(observation.box) else { return }
        var references = confirmedViews ?? []
        references.removeAll { abs($0.observation.time - observation.time) < 1 / 600 || (view != .unspecified && $0.view == view) }
        var compact = observation
        compact.print = observation.print?.map { ($0 * 1000).rounded() / 1000 }
        references.append(.init(view: view, observation: compact))
        // Keep named views. Only incidental picks age out.
        while references.count > 12 {
            references.remove(at: references.firstIndex { $0.view == .unspecified } ?? 0)
        }
        let knownNumber = number
        // A correction may follow a contaminated automatic track. Rebuild its
        // provisional cues from the explicit pick; retain other confirmed views.
        self = Self()
        learn(observation, clear: true)
        if let shirt = observation.jersey { jersey.confirm(shirt) }
        number = knownNumber
        if let read = observation.number { number.vote(read) }
        confirmedViews = references
        jersey.trusted = references.compactMap { $0.observation.jersey }
    }

    /// A saved player keeps its confirmed identity across passes. A provisional
    /// (single-frame) jersey may still be replaced by a cleaner observation.
    static func resuming(_ memory: Self?, jersey: PlayerJerseyProfile?) -> Self {
        var result = memory ?? Self()
        if result.jersey.examples.isEmpty, let jersey { result.jersey = jersey }
        result.jersey = PlayerJerseyProfile.resuming(result.jersey)
        if !result.isConfirmed {
            var provisional = Self()
            provisional.number.manual = result.number.manual
            return provisional
        }
        return result
    }

    /// Start a whole-clip rerun with a clean automatically learned appearance
    /// bank. Explicit number and named view references remain authoritative;
    /// provisional kit, tone and embedding cues may have been learned from a
    /// mistaken teammate in the previous pass.
    func restartingAutomaticLearning() -> Self {
        var result = Self()
        result.number = number
        result.confirmedViews = confirmedViews
        return result
    }

    /// Nil when the torso could not be read. Shorts refine a shirt match and a
    /// confirmed number is decisive; neither rescues a shirt mismatch.
    func similarity(to observed: PlayerObservation) -> Float? {
        var observation = observed
        // A matching head/torso view is evidence across leg poses and crops.
        // Do not let an incompatible whole-body crop veto that same visible
        // region; kit, number, head and leg-tone checks still apply below.
        if matchesUpperBody(observed) { observation.print = nil }
        guard let torso = observation.jersey, !jersey.examples.isEmpty else { return nil }
        if conflicts(with: observation) { return 0 }
        let automatic = learnedSimilarity(to: observation, torso: torso)
        let confirmed = confirmedViews?.compactMap { $0.similarity(to: observation) }.max()
        guard let references = confirmedViews, !references.isEmpty else { return automatic }
        // A confirmed kit always constrains the automatic bank. Safely learned
        // intermediate poses can support a turn between front/back references.
        guard references.contains(where: { $0.kitSimilarity(to: observation) >= 0.55 }) else { return 0 }
        var score = max(automatic, confirmed ?? 0)
        if observation.box.height >= PlayerAppearanceGallery.minimumBodyHeight, let print = observation.print {
            let explicit = references.compactMap { $0.observation.print }.map { PlayerAppearanceGallery.cosine($0, print) }.max()
            let learned = gallery?.similarity(to: print)
            if let likeness = [explicit, learned].compactMap({ $0 }).max() {
                if likeness < 0.5 { return 0 }
                if likeness < 0.6 { score *= 0.7 }
                score = min(score, 0.98 + 0.02 * max(0, likeness))
            }
        }
        // A learned shirt/body score must not erase readable head evidence.
        // Allow any confirmed view to explain lighting or a turned head.
        let compatible = references.filter { $0.kitSimilarity(to: observation) >= 0.55 }
        for (part, known) in [(observation.hair, compatible.compactMap { $0.observation.hair }),
                              (observation.skin, compatible.compactMap { $0.observation.skin })] {
            if let part, let agreement = known.map({ $0.similarity(to: part) }).max(), agreement < 0.55 { score *= 0.85 }
        }
        return score
    }

    private func learnedSimilarity(to observation: PlayerObservation, torso: PlayerJerseySignature) -> Float {
        var score = jersey.similarity(to: torso)
        // Cues combine as gates, not as a soft average: a body that clearly
        // fails any confirmed cue is someone else, whatever the others say.
        // Generic embeddings help reject mismatches, without proving identity.
        // Prints of very small bodies are noise; only sizeable ones count.
        if observation.box.height >= PlayerAppearanceGallery.minimumBodyHeight,
           let gallery, gallery.isReady, let print = observation.print, let likeness = gallery.similarity(to: print) {
            let gate = gallery.gate
            if likeness < gate - 0.1 { return 0 }
            if likeness < gate - 0.04 { score *= 0.5 }
            else if likeness < gate { score *= 0.8 }
            else if gallery.prints.count >= 6, likeness > gate + 0.1 { score = min(1, score + 0.04) }
        }
        if let chroma, chroma.isConfirmed, let sample = observation.chroma {
            let agreement = chroma.similarity(to: sample)
            if agreement < 0.5 { return 0 }
            if agreement < 0.65 { score *= 0.7 }
        }
        if let legs = observation.shorts, !shorts.examples.isEmpty {
            score = score * 0.85 + min(score, shorts.similarity(to: legs)) * 0.15
        }
        // Tone features separate same-kit teammates: a clear disagreement
        // costs a lot, agreement helps a little, unreadable ones do nothing.
        for (profile, tone) in [(head, observation.head), (legs, observation.legs)] {
            guard let profile, profile.isConfirmed, let tone else { continue }
            let agreement = profile.similarity(to: tone)
            if agreement < 0.4 { return 0 }
            if agreement < 0.55 { score *= 0.6 }
            else if agreement < 0.7 { score *= 0.85 }
            else if agreement > 0.88 { score = min(1, score + 0.03) }
        }
        if let mine = number.confirmed, let theirs = observation.number, mine == theirs { score = min(1, score + 0.1) }
        // Retain ordering when several matching kits would otherwise saturate
        // at 1. The calibrated rejection gates above remain unchanged; a generic
        // image embedding is not strong enough to replace those cues.
        if observation.box.height >= PlayerAppearanceGallery.minimumBodyHeight,
           let gallery, gallery.isReady, let print = observation.print,
           let likeness = gallery.similarity(to: print) {
            score = min(score, 0.98 + 0.02 * max(0, min(1, likeness)))
        }
        return score
    }

    static func chromaDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let sumA = max(0.05, a.x + a.y + a.z), sumB = max(0.05, b.x + b.y + b.z)
        let ca = a / sumA, cb = b / sumB
        return max(abs(ca.x - cb.x), max(abs(ca.y - cb.y), abs(ca.z - cb.z)))
    }

    func conflicts(with observation: PlayerObservation) -> Bool {
        guard let mine = number.confirmed, let theirs = observation.number else { return false }
        return mine != theirs
    }

    /// Once motion continuity is gone, a matching strip or generic image
    /// embedding is insufficient. The caller must also confirm this numbered
    /// body over several frames before restoring the saved identity.
    func recognizesReturn(_ observation: PlayerObservation) -> Bool {
        guard isConfirmed, !observation.crowded,
              let known = number.confirmed, observation.number == known else { return false }
        return (similarity(to: observation) ?? 0) >= 0.82
    }

    /// The exit edge narrows the search, but never proves identity. A matching
    /// shirt at that edge must pass the same identity checks as any return.
    func recognizesEdgeReturn(_ observation: PlayerObservation, through side: PlayerExitSide) -> Bool {
        side.isNearEdge(observation.box) &&
            (recognizesReturn(observation) || recognizesAutomaticReturn(observation))
    }

    /// Appearance-only return evidence for the selected-player tracker. This
    /// deliberately does not replace the roster's numbered whole-frame rule:
    /// a roster has to assign one body among many identities, while a selected
    /// player can require repeated agreement from the same candidate over time.
    func recognizesAutomaticReturn(_ observation: PlayerObservation) -> Bool {
        guard isConfirmed, !observation.crowded, !conflicts(with: observation),
              matchesUpperBody(observation),
              (similarity(to: observation) ?? 0) >= 0.82 else { return false }

        // Require one independent, non-shirt cue when it is available. A
        // missing face or lower body is normal at distance and must not reject
        // a valid return, but a clear disagreement should.
        let independentMatches = [
            head.flatMap { profile in observation.head.map { profile.similarity(to: $0) } },
            legs.flatMap { profile in observation.legs.map { profile.similarity(to: $0) } }
        ].compactMap { $0 }
        if !independentMatches.isEmpty {
            guard independentMatches.contains(where: { $0 >= 0.65 }) else { return false }
        }
        return true
    }

    private func matchesUpperBody(_ observation: PlayerObservation) -> Bool {
        guard let upperBodyGallery, upperBodyGallery.isReady,
              let print = observation.upperBodyPrint,
              let likeness = upperBodyGallery.similarity(to: print) else { return false }
        return likeness >= max(0.82, upperBodyGallery.gate)
    }

    mutating func learn(_ observation: PlayerObservation, clear: Bool) {
        guard clear, observation.isPartial != true, !observation.crowded, !PlayerPresence.leftFrame(observation.box),
              !conflicts(with: observation),
              !isConfirmed || (similarity(to: observation) ?? 0) >= 0.74 else { return }
        if let torso = observation.jersey {
            let unknown = jersey.examples.isEmpty
            jersey.learn(torso, clear: clear)
            if !jersey.examples.isEmpty, let color = observation.kitColor {
                if unknown || kitColor?.count != 3 { kitColor = [color.x, color.y, color.z] }
                else if clear, let mine = kitColor, Self.chromaDistance(SIMD3(mine[0], mine[1], mine[2]), color) < 0.06 {
                    // Slow running mean keeps the swatch and chroma stable.
                    kitColor = [mine[0] * 0.9 + color.x * 0.1, mine[1] * 0.9 + color.y * 0.1, mine[2] * 0.9 + color.z * 0.1]
                }
            }
        }
        guard clear, !jersey.examples.isEmpty else { return }
        if let legs = observation.shorts { shorts.learn(legs, clear: true) }
        if let sample = observation.chroma { var profile = chroma ?? PlayerJerseyProfile(); profile.learn(sample, clear: true); chroma = profile }
        if let print = observation.print, observation.box.height >= PlayerAppearanceGallery.minimumBodyHeight {
            var references = gallery ?? PlayerAppearanceGallery(); references.add(print, at: observation.time); gallery = references
        }
        if let print = observation.upperBodyPrint {
            var references = upperBodyGallery ?? PlayerAppearanceGallery()
            references.add(print, at: observation.time); upperBodyGallery = references
        }
        if let tone = observation.head { var profile = head ?? PlayerJerseyProfile(); profile.learn(tone, clear: true); head = profile }
        if let tone = observation.legs { var profile = legs ?? PlayerJerseyProfile(); profile.learn(tone, clear: true); legs = profile }
        if let text = observation.number { number.vote(text) }
    }
}

/// Shirt numbers are read sparsely and noisily. A number counts only after
/// repeated agreeing reads; a single misread never renames a player.
struct PlayerNumberVotes: Codable, Equatable, Sendable {
    var counts: [String: Int] = [:]
    var manual: String? = nil
    static let minimumVotes = 3

    var total: Int { counts.values.reduce(0, +) }
    var confirmed: String? {
        if let manual, Self.isShirtNumber(manual) { return manual }
        guard let best = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }),
              best.value >= Self.minimumVotes, Double(best.value) >= Double(total) * 0.6 else { return nil }
        return best.key
    }

    mutating func vote(_ text: String) {
        guard Self.isShirtNumber(text) else { return }
        counts[text, default: 0] += 1
    }

    static func isShirtNumber(_ text: String) -> Bool {
        (1...2).contains(text.count) && text.allSatisfy(\.isNumber) && text != "0" && text != "00"
    }
}

/// Per-detection features of one frame. Not persisted.
struct PlayerObservation: Codable, Equatable, Sendable {
    var box: CGRect
    var jersey: PlayerJerseySignature? = nil
    var shorts: PlayerJerseySignature? = nil
    var kitColor: SIMD3<Float>? = nil
    var number: String? = nil
    var crowded = false
    var head: PlayerJerseySignature? = nil
    var legs: PlayerJerseySignature? = nil
    var chroma: PlayerJerseySignature? = nil
    /// Feature print of the body crop; computed only where it is worth it.
    var print: [Float]? = nil
    var time: Double = 0
    var hair: PlayerJerseySignature? = nil
    var skin: PlayerJerseySignature? = nil
    /// Inferred missing body area: do not learn this as a complete appearance.
    /// Optional for previously saved explicit references.
    var isPartial: Bool? = nil
    var upperBodyPrint: [Float]? = nil

    func candidate(tag: Int) -> PlayerIdentityAssociation.Candidate {
        .init(box: box, jersey: jersey, crowded: crowded, tag: tag)
    }

    /// Every appearance cue for one detector box. Tone cues need a body tall
    /// enough for the head and legs bands to hold real pixels.
    /// Optional masks or a crowding override support independently validated
    /// observations. Both current tracking modes use the same unmasked cues.
    static func observe(_ buffer: CVPixelBuffer, box: CGRect, orientation: CGImagePropertyOrientation, among all: [CGRect],
                        mask: PlayerPixelMask? = nil, crowded: Bool? = nil, pose: PlayerPose? = nil,
                        bodyExtent: CGRect? = nil) -> PlayerObservation {
        // Where pose found the shirt and shorts, sample those; otherwise fall
        // back to the fixed slices of the box.
        let body = bodyExtent ?? box
        let torso = PlayerJerseySignature.sampleColors(buffer, box: body, orientation: orientation, zone: .torso,
                                                       mask: mask, region: pose?.torso)
        let shorts = PlayerJerseySignature.sampleColors(buffer, box: body, orientation: orientation, zone: .shorts,
                                                        mask: mask, region: pose?.shorts)
        let tall = box.height >= 0.06
        // A masked band keeps only on-body points, so it needs fewer of them to
        // describe the kit than a band padded out with grass and neighbours.
        let enough = mask == nil ? 60 : 36
        return PlayerObservation(box: box,
                                 jersey: torso.count >= enough ? PlayerJerseySignature(colors: torso) : nil,
                                 shorts: shorts.count >= enough ? PlayerJerseySignature(colors: shorts) : nil,
                                 kitColor: PlayerJerseySignature.meanColor(torso),
                                 crowded: crowded ?? all.contains { rect in rect != box && PlayerTracker.overlap(rect, box) > 0.25 },
                                 head: tall ? PlayerJerseySignature.tone(buffer, box: body, orientation: orientation, zone: .head, mask: mask) : nil,
                                 legs: tall ? PlayerJerseySignature.tone(buffer, box: body, orientation: orientation, zone: .legs, mask: mask) : nil,
                                 chroma: torso.count >= enough ? PlayerJerseySignature(chromaOf: torso) : nil,
                                 isPartial: body.height > box.height * 1.1 || body.width > box.width * 1.1)
    }
}

/// A player who did not cross a picture edge is still somewhere in the frame.
enum PlayerExitSide: Equatable, Sendable {
    case left
    case right
    case top
    case bottom

    /// A return is allowed near the remembered edge while the body is still
    /// entering the frame. This is intentionally tighter than the soft score.
    func isNearEdge(_ box: CGRect) -> Bool {
        switch self {
        case .left: box.minX <= 0.20
        case .right: box.maxX >= 0.80
        case .top: box.minY <= 0.20
        case .bottom: box.maxY >= 0.80
        }
    }

    /// The edge through which a tracked player most plausibly left the image.
    /// The thresholds mirror `PlayerPresence.leftFrame`, while the amount of
    /// overflow makes a corner exit deterministic.
    static func detect(_ box: CGRect) -> Self? {
        let candidates: [(Self, CGFloat)] = [
            (.left, max(0, 0.02 - box.minX)),
            (.right, max(0, box.maxX - 0.98)),
            (.top, max(0, 0.01 - box.minY)),
            (.bottom, max(0, box.maxY - 0.97))
        ]
        guard let candidate = candidates.max(by: { lhs, rhs in lhs.1 < rhs.1 }), candidate.1 > 0 else {
            return nil
        }
        return candidate.0
    }

    /// A soft prior for a candidate re-entering through this edge. The score
    /// fades out by 40% of the image, so a real return that is already deeper
    /// in frame is still allowed and can win on identity or motion.
    func reentryScore(for box: CGRect) -> CGFloat {
        let distance: CGFloat
        switch self {
        case .left: distance = max(0, box.minX)
        case .right: distance = max(0, 1 - box.maxX)
        case .top: distance = max(0, box.minY)
        case .bottom: distance = max(0, 1 - box.maxY)
        }
        return max(0, min(1, 1 - distance / 0.4))
    }
}

enum PlayerPresence {
    /// Whether a last confirmed box was touching an edge, i.e. the player may
    /// have left the picture there.
    static func leftFrame(_ box: CGRect) -> Bool {
        box.minX < 0.02 || box.maxX > 0.98 || box.maxY > 0.97 || box.minY < 0.01
    }

    /// The whole-frame search for a player known to be present: the single
    /// lone body that matches every remembered cue clearly better than any
    /// other. Nil when nothing or more than one body qualifies.
    static func findAnywhere(_ observations: [PlayerObservation], memory: PlayerIdentityMemory,
                             minimum: Float = 0.85, margin: Float = 0.1,
                             automaticAppearance: Bool = false,
                             plausible: (CGRect) -> Bool = { _ in true }) -> Int? {
        // Generic feature prints can rank candidates, but cannot prove which
        // teammate returned in a roster. The selected-player path opts into
        // the stricter appearance-only rule and still requires uniqueness.
        guard memory.isConfirmed,
              automaticAppearance || memory.number.confirmed != nil else { return nil }
        var ranked: [(Int, Float)] = []
        for (index, observation) in observations.enumerated() where !observation.crowded && plausible(observation.box) {
            let recognized = automaticAppearance
                ? memory.recognizesAutomaticReturn(observation)
                : memory.recognizesReturn(observation)
            guard recognized,
                  let similarity = memory.similarity(to: observation), similarity >= minimum else { continue }
            ranked.append((index, similarity))
        }
        ranked.sort { $0.1 > $1.1 }
        guard let best = ranked.first, ranked.count == 1 || best.1 - ranked[1].1 >= margin else { return nil }
        return best.0
    }
}

/// One shared assignment for every remembered player in a frame. Each identity
/// ranks detections with the single-player gates; the roster then makes the
/// claims exclusive, so two players never share one body and a returning
/// player cannot take a body an active teammate clearly owns.
enum PlayerRosterAssociation {
    struct Expectation: Sendable {
        let id: UUID
        /// Predicted position in the current frame; nil when nothing is known
        /// beyond appearance (a saved player not visible when the pass began).
        let box: CGRect?
        let memory: PlayerIdentityMemory
        let recovering: Bool
        let recoveryAge: Double
        /// Where the player was last seen on screen. During a pan a player is
        /// either still in the scene (`box`, camera-relative) or moving with
        /// the camera (this box). When the two point at different same-kit
        /// bodies the frame is ambiguous and the player stays hidden.
        var alternative: CGRect? = nil
        /// A new, unconfirmed tracklet must not claim a returning saved body
        /// before the established identity has had its recovery check.
        var isProvisional = false

        var dormant: Bool { recovering && recoveryAge > PlayerTrackingLimits.maximumRecoverySeconds }
        /// The last known position left the picture: the player went out of
        /// view rather than behind someone. Re-entry can happen along an edge.
        var offscreen: Bool {
            guard let box else { return true }
            return box.midX < 0.01 || box.midX > 0.99 || box.maxY < 0.02 || box.minY > 0.98
        }
    }

    struct Assignment: Equatable, Sendable {
        let id: UUID
        let observation: Int
        let score: CGFloat
    }

    struct Result: Sendable {
        var assignments: [Assignment] = []
        /// Identities whose best candidate was too close to another choice.
        var ambiguous: Set<UUID> = []
        /// Observation indices that at least one identity could plausibly own,
        /// assigned or not. Only unclaimed bodies may start a new player.
        var claimed: Set<Int> = []
        /// Observation indices more than one identity passed the gates for.
        var contested: Set<Int> = []

        func assignment(for id: UUID) -> Assignment? { assignments.first { $0.id == id } }
    }

    struct Pair { let row: Int; let column: Int; let score: CGFloat }

    static func assign(_ expectations: [Expectation], observations: [PlayerObservation]) -> Result {
        var result = Result()
        var pairs: [Pair] = []
        var owners: [Int: Int] = [:]
        for (row, expectation) in expectations.enumerated() {
            for match in matches(for: expectation, observations: observations) {
                pairs.append(.init(row: row, column: match.column, score: match.score))
                owners[match.column, default: 0] += 1
            }
        }
        result.claimed = Set(owners.keys)
        result.contested = Set(owners.filter { $0.value > 1 }.map(\.key))
        pairs.sort { $0.score > $1.score }
        // Established visible players settle first, returning identities next,
        // and provisional tracklets last. A new fragment cannot block recovery.
        var takenRows: Set<Int> = [], takenColumns: Set<Int> = []
        for phase in 0..<3 {
            let rows = Set(expectations.indices.filter {
                let expected = expectations[$0]
                return (expected.isProvisional ? 2 : expected.recovering ? 1 : 0) == phase
            })
            var blockedRows: Set<Int> = [], blockedColumns: Set<Int> = []
            for pair in pairs where rows.contains(pair.row) {
                guard !takenRows.contains(pair.row), !takenColumns.contains(pair.column),
                      !blockedRows.contains(pair.row), !blockedColumns.contains(pair.column) else { continue }
                let expectation = expectations[pair.row]
                let margin = PlayerIdentityAssociation.margin(recovering: expectation.recovering, dormant: expectation.dormant)
                let rowRunner = pairs.filter { $0.row == pair.row && $0.column != pair.column && !takenColumns.contains($0.column) }.map(\.score).max() ?? 0
                let columnRunner = pairs.filter { $0.column == pair.column && $0.row != pair.row && rows.contains($0.row) && !takenRows.contains($0.row) }.map(\.score).max() ?? 0
                if pair.score - rowRunner >= margin, pair.score - columnRunner >= margin {
                    takenRows.insert(pair.row); takenColumns.insert(pair.column)
                    result.assignments.append(.init(id: expectation.id, observation: pair.column, score: pair.score))
                } else {
                    // Conservative, like the single-player tracker: an unclear
                    // frame hides the player instead of guessing a body.
                    blockedRows.insert(pair.row); blockedColumns.insert(pair.column)
                    result.ambiguous.insert(expectation.id)
                }
            }
        }
        return result
    }

    /// When several players drop out together (a blurred pan) and most of them
    /// moved with the camera, their predictions are all off by one common
    /// vector. A robust mode over same-kit, same-size displacement candidates
    /// recovers that vector; nothing is applied unless the crowd agrees.
    static func crowdOffset(_ expectations: [Expectation], observations: [PlayerObservation]) -> CGPoint? {
        let recovering = expectations.enumerated().filter { $0.element.recovering && !$0.element.dormant && $0.element.box != nil }
        guard recovering.count >= 3 else { return nil }
        var vectors: [(row: Int, offset: CGPoint)] = []
        for (row, expectation) in recovering {
            let box = expectation.box!
            for observation in observations where !observation.crowded {
                let ratio = observation.box.height / max(0.001, box.height)
                guard ratio > 0.7, ratio < 1.4, let similarity = expectation.memory.similarity(to: observation), similarity >= 0.7 else { continue }
                let offset = CGPoint(x: observation.box.midX - box.midX, y: observation.box.maxY - box.maxY)
                guard hypot(offset.x, offset.y) < 0.35 else { continue }
                vectors.append((row, offset))
            }
        }
        guard vectors.count >= 3 else { return nil }
        func support(_ centre: CGPoint) -> [(row: Int, offset: CGPoint)] {
            vectors.filter { hypot($0.offset.x - centre.x, $0.offset.y - centre.y) < 0.03 }
        }
        let best = vectors.map { support($0.offset) }.max { Set($0.map(\.row)).count < Set($1.map(\.row)).count } ?? []
        let voters = Set(best.map(\.row)).count
        guard voters >= max(4, Int((Double(recovering.count) * 0.6).rounded(.up))) else { return nil }
        let mean = CGPoint(x: best.map(\.offset.x).reduce(0, +) / CGFloat(best.count), y: best.map(\.offset.y).reduce(0, +) / CGFloat(best.count))
        // A common shift can only be as large as the crowd could have moved
        // in the time it was hidden.
        let longest = recovering.map(\.element.recoveryAge).max() ?? 0
        let magnitude = hypot(mean.x, mean.y)
        return magnitude > 0.015 && magnitude <= 0.08 + 0.2 * longest ? mean : nil
    }

    /// Gate-passing observations for one identity, best first. Visible players
    /// and short losses use the shared single-player gates; players that left
    /// the picture or were never seen match on appearance near the exit edge.
    static func matches(for expectation: Expectation, observations: [PlayerObservation]) -> [(column: Int, score: CGFloat)] {
        let memory = expectation.memory
        let appearance: (PlayerIdentityAssociation.Candidate) -> CGFloat? = { candidate in
            memory.similarity(to: observations[candidate.tag]).map { CGFloat($0) }
        }
        let candidates = observations.enumerated().map { $0.element.candidate(tag: $0.offset) }
        if let box = expectation.box, !expectation.dormant, !(expectation.recovering && expectation.offscreen) {
            let minimum = PlayerIdentityAssociation.minimumScore(recovering: expectation.recovering)
            func ranked(around expected: CGRect) -> [(column: Int, score: CGFloat)] {
                PlayerIdentityAssociation.ranked(candidates, expected: expected, optical: nil, profile: memory.jersey,
                                                 recovering: expectation.recovering, recoveryAge: expectation.recoveryAge,
                                                 appearance: appearance)
                    .filter { $0.score >= minimum }
                    .map { ($0.candidate.tag, $0.score) }
            }
            let primary = ranked(around: box)
            guard expectation.recovering, let alternative = expectation.alternative,
                  hypot(alternative.midX - box.midX, alternative.maxY - box.maxY) > max(0.02, box.width) else { return primary }
            let secondary = ranked(around: alternative)
            if let first = primary.first, let second = secondary.first, first.column != second.column { return [] }
            var merged: [Int: CGFloat] = [:]
            for match in primary + secondary { merged[match.column] = max(merged[match.column] ?? 0, match.score) }
            return merged.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
        }
        // Offscreen and long absences need individual evidence as well as
        // appearance and exclusive ownership of the returned body.
        guard expectation.recovering, memory.isConfirmed else { return [] }
        let anchor = expectation.box.map { CGPoint(x: min(1, max(0, $0.midX)), y: min(1, max(0, $0.maxY))) }
        // A player who left through an edge comes back near it. One who did
        // not is still in the picture: the search grows to the whole frame
        // the longer he stays missing.
        let reach = expectation.offscreen ? 0.4 : min(1.2, 0.3 + max(0, expectation.recoveryAge - 3) * 0.3)
        return candidates.compactMap { candidate -> (Int, CGFloat)? in
            guard memory.recognizesReturn(observations[candidate.tag]),
                  let similarity = appearance(candidate), similarity >= 0.82 else { return nil }
            var spatial: CGFloat = 0.5
            if let anchor, let box = expectation.box {
                let distance = hypot(candidate.box.midX - anchor.x, candidate.box.maxY - anchor.y)
                let ratio = candidate.box.height / max(0.001, box.height)
                guard distance <= reach, ratio > 0.5, ratio < 2 else { return nil }
                spatial = 1 - distance / reach
            }
            return (candidate.tag, similarity * 0.6 + spatial * 0.4)
        }.sorted { $0.1 > $1.1 }
    }
}
