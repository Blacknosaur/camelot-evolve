import Foundation

/// A copy of a board that the on-device assistant changes through its tools. Every operation is
/// plain Swift, so it is tested without a language model; `BoardAssistant` only exposes it as tools.
///
/// Positions are in metres, the way coaches describe them: `along` runs from our goal line (0)
/// towards the opponents' goal line, `across` from the left touchline (0) as seen from our goal.
/// The home team attacks along +along.
final class BoardAssistantDraft: @unchecked Sendable {
    private let lock = NSLock()
    private var board: BoardDocument
    let frame: Int?
    private var notes: [String] = []
    /// The coach's words. Explicit counts such as "5v2" win over the model's reading of them.
    var request = ""

    init(document: BoardDocument, recordingFrame frame: Int? = nil) {
        board = document
        self.frame = frame
    }

    var document: BoardDocument { lock.withLock { board } }
    /// One line per change, newest last: what the assistant actually did.
    var changes: [String] { lock.withLock { notes } }

    /// Length and width of the current pitch in metres, in the assistant's frame.
    var pitchSize: (along: Double, across: Double) {
        lock.withLock { Self.size(of: board.fieldType) }
    }

    static func size(of field: BoardFieldType) -> (along: Double, across: Double) {
        let meters = field.meters
        return field == .footballHalf ? (Double(meters.height), Double(meters.width)) : (Double(meters.width), Double(meters.height))
    }

    /// Board coordinates for a spot in metres. The half pitch runs down the screen with our goal at
    /// the top (y = 0) and our right at x = 0, so its left touchline is x = 1.
    static func point(along: Double, across: Double, on field: BoardFieldType) -> BoardPoint {
        let size = size(of: field)
        let a = along / max(1, size.along), c = across / max(1, size.across)
        return (field == .footballHalf ? BoardPoint(1 - c, a) : BoardPoint(a, c)).clamped()
    }

    // MARK: Operations (each returns a short result the model reads back)

    @discardableResult
    func setPitch(_ name: String) -> String {
        let field: BoardFieldType = switch name.lowercased() {
        case let value where value.contains("half"): .footballHalf
        case let value where value.contains("futsal"): .futsal
        case let value where value.contains("blank") || value.contains("empty"): .blank
        default: .footballFull
        }
        let size = Self.size(of: field)
        return change("Pitch: \(field.title)") { $0.fieldType = field }
            + " It is \(Int(size.along)) m long and \(Int(size.across)) m wide."
    }

    @discardableResult
    func placeFormation(_ formation: String, team: String) -> String {
        guard let shape = SquadFormation(rawValue: formation.trimmingCharacters(in: .whitespaces)) else {
            return "Unknown formation \(formation). Use one of \(SquadFormation.allCases.map(\.rawValue).joined(separator: ", "))."
        }
        let side: BoardTeamSide = team.lowercased().hasPrefix("away") || team.lowercased().hasPrefix("opp") ? .away : .home
        if document.teamElements(side).count >= 10 { return "The \(side.rawValue) team is already on the board." }
        let result = change("\(side.title) team in a \(shape.rawValue)") { doc in
            doc.insertElements(doc.lineupElements([], formation: shape, side: side, fillsEmptySlots: true), recordingFrame: frame)
        }
        // The model can only refer to players it knows: list the shirt numbers line by line.
        var numbers = shape.conventionalNumbers
        let keeper = numbers.removeFirst()
        var lines: [String] = []
        for count in shape.lines { lines.append(numbers.prefix(count).map(String.init).joined(separator: " ")); numbers.removeFirst(count) }
        return result + " \(side.rawValue) numbers: keeper \(keeper); " + lines.enumerated().map { index, line in
            (index == 0 ? "defence " : index == lines.count - 1 ? "attack " : "midfield ") + line + " (right to left)"
        }.joined(separator: "; ") + "."
    }

    struct PlayerSpot {
        var along: Double
        var across: Double
        var number: Int? = nil
        var label: String? = nil
    }

    @discardableResult
    func addPlayers(team: String, _ spots: [PlayerSpot]) -> String {
        guard !spots.isEmpty else { return "No positions given." }
        let key = team.lowercased()
        return change("\(spots.count) \(key) player\(spots.count == 1 ? "" : "s")") { doc in
            for spot in spots.prefix(22) {
                let point = Self.point(along: spot.along, across: spot.across, on: doc.fieldType)
                var element: BoardElement
                if key.hasPrefix("keeper") || key.hasPrefix("goal") {
                    element = BoardElement(kind: .goalkeeper, position: point, colorHex: BoardPalette.keeper,
                                           number: spot.number ?? doc.nextNumber(for: .goalkeeper, colorHex: BoardPalette.keeper))
                } else if key.hasPrefix("opponent") || key.hasPrefix("defender") {
                    element = BoardElement(kind: .opponent, position: point, colorHex: doc.awayColorHex)
                } else {
                    let color = key.hasPrefix("away") ? doc.awayColorHex : doc.homeColorHex
                    element = BoardElement(kind: .player, position: point, colorHex: color,
                                           number: spot.number ?? doc.nextNumber(for: .player, colorHex: color))
                }
                element.label = String((spot.label ?? "").prefix(24))
                // One at a time, so each new player takes the next free number.
                doc.insertElements([element], recordingFrame: frame)
            }
        }
    }

    /// Equipment names the assistant may use, mapped to board kinds.
    static let equipment: [String: BoardElementKind] = [
        "ball": .ball, "cone": .cone, "tall cone": .tallCone, "dome": .domeCone, "marker": .marker, "pole": .pole,
        "hurdle": .hurdle, "ladder": .ladder, "ring": .ring, "dummy": .mannequin, "mini goal": .miniGoal,
        "goal": .goal, "pop-up goal": .popUpGoal, "rebounder": .rebounder, "flag": .flag, "coach": .coach, "referee": .referee,
    ]

    @discardableResult
    func addEquipment(_ item: String, at spots: [(along: Double, across: Double)]) -> String {
        guard let kind = Self.equipment[item.lowercased()] ?? Self.equipment.first(where: { item.lowercased().contains($0.key) })?.value else {
            return "Unknown item \(item). Use one of \(Self.equipment.keys.sorted().joined(separator: ", "))."
        }
        guard !spots.isEmpty else { return "No positions given." }
        return change("\(spots.count) × \(item)") { doc in
            let added = spots.prefix(40).map { spot in
                BoardElement(kind: kind, position: Self.point(along: spot.along, across: spot.across, on: doc.fieldType),
                             colorHex: BoardRenderer.defaultColor(for: kind, document: doc))
            }
            doc.insertElements(Array(added), recordingFrame: frame)
        }
    }

    /// A rectangle marked with a cone at each corner, e.g. a rondo square.
    @discardableResult
    func addGrid(centreAlong: Double, centreAcross: Double, length: Double, width: Double, label: String? = nil) -> String {
        let halfL = max(1, length) / 2, halfW = max(1, width) / 2
        let corners = [(centreAlong - halfL, centreAcross - halfW), (centreAlong - halfL, centreAcross + halfW),
                       (centreAlong + halfL, centreAcross - halfW), (centreAlong + halfL, centreAcross + halfW)]
        markArea(fromAlong: centreAlong - halfL, fromAcross: centreAcross - halfW, toAlong: centreAlong + halfL, toAcross: centreAcross + halfW, label: label)
        addEquipment("cone", at: corners.map { (along: $0.0, across: $0.1) })
        return "Marked a \(Int(length)) × \(Int(width)) m grid with a cone at each corner."
    }

    @discardableResult
    func markArea(fromAlong: Double, fromAcross: Double, toAlong: Double, toAcross: Double, label: String? = nil) -> String {
        change("Area\(label.map { " \($0)" } ?? "")") { doc in
            let a = Self.point(along: fromAlong, across: fromAcross, on: doc.fieldType)
            let b = Self.point(along: toAlong, across: toAcross, on: doc.fieldType)
            let zone = BoardElement(kind: .zone, position: a, points: [b], colorHex: BoardPalette.keeper)
            var added = [zone]
            if let label, !label.isEmpty {
                added.append(BoardElement(kind: .text, position: BoardPoint((a.x + b.x) / 2, (a.y + b.y) / 2), label: String(label.prefix(24))))
            }
            doc.insertElements(added, recordingFrame: frame)
        }
    }

    /// A pass, run or dribble. Ends within a few metres of a player or item connect to it.
    @discardableResult
    func drawMovement(_ kind: String, fromAlong: Double, fromAcross: Double, toAlong: Double, toAcross: Double) -> String {
        let style: BoardLineStyle = switch kind.lowercased() {
        case let value where value.contains("run"): .run
        case let value where value.contains("dribble"): .dribble
        default: .pass
        }
        return change("\(kind.capitalized)") { doc in
            let start = Self.point(along: fromAlong, across: fromAcross, on: doc.fieldType)
            let end = Self.point(along: toAlong, across: toAcross, on: doc.fieldType)
            var line = BoardElement(kind: .line, position: start, points: [end])
            line.lineStyle = style
            if let from = Self.nearestPoint(to: start, in: doc) { line.position = from.position; line.startAttachment = from.id }
            if let to = Self.nearestPoint(to: end, in: doc, excluding: line.startAttachment) { line.points = [to.position]; line.endAttachment = to.id }
            doc.insertElements([line], recordingFrame: frame)
        }
    }

    private static func nearestPoint(to point: BoardPoint, in doc: BoardDocument, excluding excluded: UUID? = nil) -> BoardElement? {
        let meters = doc.fieldType.meters
        let limit = 4.0
        return doc.elements.filter { $0.kind.isPoint && $0.kind != .text && $0.id != excluded }
            .map { ($0, hypot(($0.position.x - point.x) * Double(meters.width), ($0.position.y - point.y) * Double(meters.height))) }
            .filter { $0.1 <= limit }
            .min { $0.1 < $1.1 }?.0
    }

    /// Side the last set piece was taken from, so "near post" and "far post" mean the right posts.
    var setPieceSide: Double = 0

    func change(_ note: String, _ body: (inout BoardDocument) -> Void) -> String {
        lock.withLock {
            body(&board)
            notes.append(note)
        }
        return "Done: \(note)."
    }
}
