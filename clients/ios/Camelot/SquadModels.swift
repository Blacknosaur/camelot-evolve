import Foundation
import SwiftData
import SwiftUI

// MARK: - Persistence

/// A stored player in the coach's squad (the Squad tab). Boards link to players through
/// `BoardElement.playerID`; photos live on disk in `SquadPhotoStore`, keyed by `id`.
/// Enumerations are stored as raw strings so new cases never need a migration.
@Model
final class SquadPlayer {
    @Attribute(.unique) var id: UUID
    var name: String
    var number: Int?
    /// `SquadPosition` raw value.
    var position: String
    /// Detailed role such as "RB" or "CAM"; empty when not set.
    var role: String
    /// Squad or group name ("U12", "First team").
    var team: String
    /// `SquadFoot` raw value.
    var preferredFoot: String?
    var birthYear: Int?
    var heightCm: Int?
    /// The coach's own free text, written and read back in the player editor.
    var notes: String
    /// Kit colour override (6-digit hex); nil uses the board's team colour.
    var colorHex: String?
    /// Bumped whenever the photo changes, so views reload it.
    var photoVersion: Int
    /// Kept as part of the stored schema: nothing reads them yet, and dropping a stored property
    /// from a shipped `@Model` is a migration, not a cleanup.
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, number: Int? = nil, position: SquadPosition = .midfielder, role: String = "", team: String = "",
         preferredFoot: SquadFoot? = nil, birthYear: Int? = nil, heightCm: Int? = nil, notes: String = "", colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.number = number
        self.position = position.rawValue
        self.role = role
        self.team = team
        self.preferredFoot = preferredFoot?.rawValue
        self.birthYear = birthYear
        self.heightCm = heightCm
        self.notes = notes
        self.colorHex = colorHex
        photoVersion = 0
        createdAt = .now
        updatedAt = .now
    }

    var squadPosition: SquadPosition {
        get { SquadPosition(rawValue: position) ?? .midfielder }
        set { position = newValue.rawValue }
    }

    var foot: SquadFoot? {
        get { preferredFoot.flatMap(SquadFoot.init(rawValue:)) }
        set { preferredFoot = newValue?.rawValue }
    }

    /// Role when set, else the position's short code ("MF").
    var positionLabel: String { role.isEmpty ? squadPosition.shortTitle : role }

    var snapshot: SquadPlayerSnapshot {
        SquadPlayerSnapshot(id: id, name: name, number: number, position: squadPosition, colorHex: colorHex, role: role)
    }

    /// Removes the player and its photo. Boards keep their stored number and label.
    /// The photo file only goes once the deletion is stored, so a failed save never leaves a
    /// player behind with a missing face.
    @MainActor func delete(from modelContext: ModelContext) throws {
        let id = self.id
        modelContext.delete(self)
        try modelContext.save()
        SquadPhotoStore.delete(for: id)
    }

    /// A saved copy ("Name copy") with the same data and photo. The photo is written only after the
    /// copy itself is stored, so a failed save leaves no orphan file on disk.
    @MainActor func duplicate(in modelContext: ModelContext) throws -> SquadPlayer {
        let copy = SquadPlayer(name: "\(name) copy", number: nil, position: squadPosition, role: role, team: team, preferredFoot: foot,
                               birthYear: birthYear, heightCm: heightCm, notes: notes, colorHex: colorHex)
        let data = SquadPhotoStore.jpegData(for: id)
        if data != nil { copy.photoVersion = 1 }
        modelContext.insert(copy)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(copy)
            throw error
        }
        if let data { try? SquadPhotoStore.store(data, for: copy.id) }
        return copy
    }
}

enum SquadPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case goalkeeper, defender, midfielder, forward

    var id: String { rawValue }

    var title: String {
        switch self {
        case .goalkeeper: "Goalkeeper"
        case .defender: "Defender"
        case .midfielder: "Midfielder"
        case .forward: "Forward"
        }
    }

    var shortTitle: String {
        switch self {
        case .goalkeeper: "GK"
        case .defender: "DF"
        case .midfielder: "MF"
        case .forward: "FW"
        }
    }

    /// Common detailed roles offered as suggestions in the editor.
    var suggestedRoles: [String] {
        switch self {
        case .goalkeeper: ["GK"]
        case .defender: ["CB", "RB", "LB", "RWB", "LWB"]
        case .midfielder: ["CDM", "CM", "CAM", "RM", "LM"]
        case .forward: ["ST", "CF", "RW", "LW"]
        }
    }
}

enum SquadFoot: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, right, both
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Plain, thread-safe copy of the player data boards need.
struct SquadPlayerSnapshot: Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var number: Int?
    var position: SquadPosition
    var colorHex: String?
    /// Detailed role ("RB", "CAM"); orders players across their line.
    var role: String = ""

    /// Where the role plays across the pitch, from the team's right (0) to its left (1).
    /// Unknown or central roles are 0.5.
    var sideRank: Double { Self.sideRank(of: role) }

    static func sideRank(of role: String) -> Double {
        switch role.trimmingCharacters(in: .whitespaces).uppercased() {
        case "RB", "RWB", "RM", "RW": 0
        case "RCB": 0.25
        case "RCM": 0.3
        case "LCM": 0.7
        case "LCB": 0.75
        case "LB", "LWB", "LM", "LW": 1
        default: 0.5
        }
    }

    /// Short label drawn under the disc: the full name when short, else the last word ("Smith").
    var boardLabel: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12, let last = trimmed.split(separator: " ").last else { return trimmed }
        return String(last)
    }

    var elementKind: BoardElementKind { position == .goalkeeper ? .goalkeeper : .player }

    static func initials(of name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

// MARK: - Formations

enum BoardTeamSide: String, CaseIterable, Identifiable, Sendable {
    case home, away
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum SquadFormation: String, CaseIterable, Identifiable, Sendable {
    case f433 = "4-3-3", f442 = "4-4-2", f4231 = "4-2-3-1", f352 = "3-5-2", f343 = "3-4-3"

    var id: String { rawValue }
    var title: String { rawValue }

    /// Outfield lines from defence to attack.
    var lines: [Int] { rawValue.split(separator: "-").compactMap { Int($0) } }

    /// Eleven slots (keeper first), each with the position it suits and a spot in "team space":
    /// `depth` 0 is the own goal line and 1 the halfway line; `width` runs from the team's right (0)
    /// to its left (1), so within a line slots are listed right to left.
    var slots: [(position: SquadPosition, depth: Double, width: Double)] {
        var result: [(SquadPosition, Double, Double)] = [(.goalkeeper, 0.08, 0.5)]
        let lines = lines
        for (index, count) in lines.enumerated() {
            let position: SquadPosition = index == 0 ? .defender : index == lines.count - 1 ? .forward : .midfielder
            let depth = 0.3 + 0.62 * Double(index) / Double(max(1, lines.count - 1))
            let margin = count >= 5 ? 0.1 : count == 1 ? 0.5 : 0.16
            for slot in 0..<count {
                let width = count == 1 ? 0.5 : margin + (1 - 2 * margin) * Double(slot) / Double(count - 1)
                result.append((position, depth, width))
            }
        }
        return result
    }

    /// Shirt numbers for generic players, per slot (keeper first, then each line right to left):
    /// the classic convention, e.g. a back four is 2 (RB), 5, 4, 3 (LB) and a front three 7, 9, 11.
    var conventionalNumbers: [Int] {
        switch self {
        case .f433: [1, 2, 5, 4, 3, 8, 6, 10, 7, 9, 11]
        case .f442: [1, 2, 5, 4, 3, 7, 8, 6, 11, 9, 10]
        case .f4231: [1, 2, 5, 4, 3, 8, 6, 7, 10, 11, 9]
        case .f352: [1, 5, 4, 6, 2, 8, 7, 10, 3, 9, 11]
        case .f343: [1, 5, 4, 6, 2, 8, 10, 3, 7, 9, 11]
        }
    }
}

// MARK: - Board integration

extension BoardDocument {
    /// Board coordinates for a team-space spot, worked out in field space from the team's own goal
    /// (so it is right on screen in portrait and landscape alike). Field y grows downwards in metres:
    /// facing +x (home on full-size fields, defending x = 0) a team's right is +y; facing +y (home on
    /// the half pitch, defending y = 0) its right is -x. Away is the point mirrored through the
    /// centre, which also mirrors its right, so it stays in the other half (on the half pitch it is
    /// mirrored from the halfway line, attacking the goal).
    func lineupPoint(depth: Double, width: Double, side: BoardTeamSide = .home) -> BoardPoint {
        let home = fieldType == .footballHalf ? BoardPoint(width, 0.05 + depth * 0.85) : BoardPoint(0.03 + depth * 0.43, 1 - width)
        guard side == .away else { return home.clamped() }
        return BoardPoint(1 - home.x, 1 - home.y).clamped()
    }

    /// Kit colour of a side's outfield players.
    func colorHex(for side: BoardTeamSide) -> String { side == .home ? homeColorHex : awayColorHex }

    /// A board element for a squad player: kind, number, label and link, coloured with the player's
    /// kit colour or the side's colour (a home keeper defaults to the keeper colour).
    func element(for player: SquadPlayerSnapshot, at point: BoardPoint, side: BoardTeamSide = .home) -> BoardElement {
        let kind = player.elementKind
        let fallback = kind == .goalkeeper && side == .home ? BoardPalette.keeper : colorHex(for: side)
        var element = BoardElement(kind: kind, position: point, colorHex: player.colorHex ?? fallback, number: player.number, label: player.boardLabel)
        element.playerID = player.id
        return element
    }

    /// Players (outfield and keepers, the editor's Home/Away tools) already on the board for `side`.
    /// Home keepers wear the keeper colour; linked squad players in a custom kit count as home.
    /// When both kits are set to the same colour the colour says nothing, so the half of the field
    /// the element stands in decides instead (home defends the end `lineupPoint` places it at).
    func teamElements(_ side: BoardTeamSide) -> [BoardElement] {
        let sameKit = homeColorHex == awayColorHex
        return elements.filter { element in
            guard element.kind == .player || element.kind == .goalkeeper else { return false }
            guard !sameKit else { return defendsOwnEnd(element.position) == (side == .home) }
            switch side {
            case .away: return element.colorHex == awayColorHex
            case .home:
                return element.colorHex == homeColorHex || (element.kind == .goalkeeper && element.colorHex == BoardPalette.keeper)
                    || (element.playerID != nil && element.colorHex != awayColorHex)
            }
        }
    }

    /// True in the half home defends: the low end of the axis `lineupPoint` lays the formation out along.
    func defendsOwnEnd(_ point: BoardPoint) -> Bool {
        fieldType == .footballHalf ? point.y < 0.5 : point.x < 0.5
    }

    /// Squad players assigned to formation slots: each takes the first free slot of its own position
    /// (in selection order), and leftovers take the remaining slots in formation order. At most eleven.
    static func assignSlots(_ players: [SquadPlayerSnapshot], formation: SquadFormation) -> [Int: SquadPlayerSnapshot] {
        let slots = formation.slots
        var assigned = [Int: SquadPlayerSnapshot]()
        var remaining = Array(players.prefix(slots.count))
        for (index, slot) in slots.enumerated() {
            if let match = remaining.firstIndex(where: { $0.position == slot.position }) {
                assigned[index] = remaining.remove(at: match)
            }
        }
        for index in slots.indices where assigned[index] == nil && !remaining.isEmpty {
            assigned[index] = remaining.removeFirst()
        }
        // Within each line, seat players by role from the team's right to its left: the widest roles
        // choose first, each taking the free slot nearest its side; unknown roles end up central.
        var ordered = [Int: SquadPlayerSnapshot]()
        for line in Dictionary(grouping: slots.indices, by: { slots[$0].depth }).values {
            let lineSlots = line.sorted { slots[$0].width < slots[$1].width }
            var free = lineSlots
            let players = lineSlots.compactMap { assigned[$0] }
                .enumerated()
                .sorted { abs($0.element.sideRank - 0.5) > abs($1.element.sideRank - 0.5) || (abs($0.element.sideRank - 0.5) == abs($1.element.sideRank - 0.5) && $0.offset < $1.offset) }
                .map(\.element)
            for player in players {
                guard let best = free.min(by: { abs(slots[$0].width - player.sideRank) < abs(slots[$1].width - player.sideRank) }) else { break }
                ordered[best] = player
                free.removeAll { $0 == best }
            }
        }
        return ordered
    }

    /// Elements for a lineup. With `fillsEmptySlots`, every slot without a squad player (and not listed
    /// in `skipping`) gets a generic numbered player of that side wearing the slot's conventional
    /// number (`SquadFormation.conventionalNumbers`), or the lowest number not used by that side on the
    /// board or by the selection when that one is taken.
    func lineupElements(_ players: [SquadPlayerSnapshot], formation: SquadFormation, side: BoardTeamSide = .home,
                        fillsEmptySlots: Bool = false, skipping covered: Set<Int> = []) -> [BoardElement] {
        let slots = formation.slots
        let assigned = Self.assignSlots(players, formation: formation)
        var used = Set(teamElements(side).compactMap(\.number)).union(assigned.values.compactMap(\.number))
        func nextNumber(preferring preferred: Int) -> Int {
            var number = preferred
            if used.contains(number) { number = 1; while used.contains(number) { number += 1 } }
            used.insert(number)
            return number
        }
        return slots.indices.compactMap { index in
            let point = lineupPoint(depth: slots[index].depth, width: slots[index].width, side: side)
            if let player = assigned[index] { return element(for: player, at: point, side: side) }
            guard fillsEmptySlots, !covered.contains(index) else { return nil }
            let isKeeper = slots[index].position == .goalkeeper
            let color = isKeeper && side == .home ? BoardPalette.keeper : colorHex(for: side)
            return BoardElement(kind: isKeeper ? .goalkeeper : .player, position: point, colorHex: color,
                                number: nextNumber(preferring: formation.conventionalNumbers[index]))
        }
    }

    /// Formation slots already taken by `side`'s players: greedy nearest pairs of slot and player
    /// within `coverageMeters` (each player covers at most one slot).
    func coveredSlots(formation: SquadFormation, side: BoardTeamSide) -> Set<Int> {
        let slots = formation.slots
        let w = Double(fieldType.meters.width), h = Double(fieldType.meters.height)
        let team = teamElements(side)
        var pairs: [(slot: Int, player: Int, distance: Double)] = []
        for (slotIndex, slot) in slots.enumerated() {
            let point = lineupPoint(depth: slot.depth, width: slot.width, side: side)
            for (playerIndex, player) in team.enumerated() {
                let distance = hypot((player.position.x - point.x) * w, (player.position.y - point.y) * h)
                if distance <= coverageMeters { pairs.append((slotIndex, playerIndex, distance)) }
            }
        }
        var covered = Set<Int>(), usedPlayers = Set<Int>()
        for pair in pairs.sorted(by: { $0.distance < $1.distance }) where !covered.contains(pair.slot) && !usedPlayers.contains(pair.player) {
            covered.insert(pair.slot); usedPlayers.insert(pair.player)
        }
        return covered
    }

    /// "A few metres": 10% of the shorter side, at least 3 m (6.8 m on a full pitch).
    var coverageMeters: Double { max(3, 0.1 * Double(min(fieldType.meters.width, fieldType.meters.height))) }

    /// Generic players for the slots of `formation` that `side` has not covered yet. Existing elements never move.
    func fillRemainingElements(formation: SquadFormation, side: BoardTeamSide) -> [BoardElement] {
        lineupElements([], formation: formation, side: side, fillsEmptySlots: true, skipping: coveredSlots(formation: formation, side: side))
    }

    /// Appends elements in one document change, recording their poses in `frame` on animated boards.
    mutating func insertElements(_ added: [BoardElement], recordingFrame frame: Int?) {
        elements.append(contentsOf: added)
        guard let frame, isAnimated, keyframes.indices.contains(frame) else { return }
        for element in added { keyframes[frame].poses[element.id] = element.pose }
    }

    /// Copies number, label and goalkeeper/outfield kind from linked squad players that still exist.
    /// Elements whose player was deleted keep what they have. Returns whether anything changed.
    @discardableResult
    mutating func refreshSquadLinks(_ players: [UUID: SquadPlayerSnapshot]) -> Bool {
        var changed = false
        for index in elements.indices {
            guard let id = elements[index].playerID, let player = players[id] else { continue }
            var element = elements[index]
            element.number = player.number
            element.label = player.boardLabel
            if element.kind == .player || element.kind == .goalkeeper {
                if element.kind != player.elementKind, element.colorHex == (element.kind == .goalkeeper ? BoardPalette.keeper : homeColorHex), player.colorHex == nil {
                    element.colorHex = player.elementKind == .goalkeeper ? BoardPalette.keeper : homeColorHex
                }
                element.kind = player.elementKind
            }
            if element != elements[index] { elements[index] = element; changed = true }
        }
        return changed
    }
}

extension ModelContext {
    /// Every squad player as a thread-safe snapshot, keyed by id.
    func squadSnapshots() -> [UUID: SquadPlayerSnapshot] {
        let players = (try? fetch(FetchDescriptor<SquadPlayer>())) ?? []
        return Dictionary(players.map { ($0.id, $0.snapshot) }, uniquingKeysWith: { first, _ in first })
    }
}
