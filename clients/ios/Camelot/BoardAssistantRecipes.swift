import Foundation

/// Football-correct layouts the assistant chooses by name. The on-device model is good at picking
/// what a coach means and poor at inventing coordinates, so positions are worked out here.
extension BoardAssistantDraft {
    static let drills = ["rondo", "possession square", "small-sided game", "attack vs defence"]
    static let setPieces = ["corner", "free kick", "penalty", "throw-in", "goal kick", "kick-off"]
    static let zones = ["left wing", "right wing", "centre", "left half-space", "right half-space",
                        "our box", "their box", "our half", "their half", "final third", "middle third"]
    static let spots = ["near post", "far post", "penalty spot", "edge of the box", "six-yard box",
                        "left wing", "right wing", "centre circle", "their goal", "our goal"]

    // MARK: Drills

    @discardableResult
    func drill(_ kind: String, attackers: Int, defenders: Int, size: Double?) -> String {
        let (length, width) = pitchSize
        let key = kind.lowercased()
        var a = min(10, max(1, attackers)), d = min(8, max(0, defenders))
        if let counts = Self.counts(in: request) { a = min(10, max(1, counts.0)); d = min(8, max(0, counts.1)) }
        if key.contains("small") {
            let side = min(length * 0.8, max(20, size ?? 40)), across = min(width * 0.9, side * 0.65)
            let centre = (along: length / 2, across: width / 2)
            markArea(fromAlong: centre.along - side / 2, fromAcross: centre.across - across / 2,
                     toAlong: centre.along + side / 2, toAcross: centre.across + across / 2)
            addEquipment("mini goal", at: [(centre.along - side / 2, centre.across), (centre.along + side / 2, centre.across)])
            addPlayers(team: "home", Self.rows(count: a, along: centre.along - side * 0.3...centre.along - side * 0.06, across: centre.across, spread: across * 0.8))
            addPlayers(team: "away", Self.rows(count: max(1, d), along: centre.along + side * 0.06...centre.along + side * 0.3, across: centre.across, spread: across * 0.8))
            addEquipment("ball", at: [(centre.along, centre.across)])
            return "Small-sided game: \(a) v \(max(1, d)) on a \(Int(side)) × \(Int(across)) m pitch with mini goals."
        }
        if key.contains("attack") {
            addPlayers(team: "home", Self.rows(count: a, along: length - 30...length - 22, across: width / 2, spread: 36))
            if d > 0 {
                addPlayers(team: "keeper", [.init(along: length - 1, across: width / 2)])
                addPlayers(team: "away", Self.rows(count: d, along: length - 16...length - 12, across: width / 2, spread: 30))
            }
            addEquipment("ball", at: [(length - 26, width / 2)])
            return "Attack vs defence: \(a) attackers against \(d) defenders near their box."
        }
        // Rondo and possession: attackers around the edge of a square, defenders inside.
        let side = max(6, min(min(length, width) * 0.9, size ?? (key.contains("possession") ? 25 : 12)))
        let centre = (along: length / 2, across: width / 2)
        addGrid(centreAlong: centre.along, centreAcross: centre.across, length: side, width: side)
        let edge = (0..<a).map { index -> PlayerSpot in
            // Walk the perimeter, starting in the middle of the near side.
            let t = (Double(index) / Double(a) * 4 + 0.5).truncatingRemainder(dividingBy: 4)
            let half = side / 2, offset = (t - floor(t) - 0.5) * side
            switch Int(t) {
            case 0: return .init(along: centre.along - half, across: centre.across + offset)
            case 1: return .init(along: centre.along + offset, across: centre.across + half)
            case 2: return .init(along: centre.along + half, across: centre.across - offset)
            default: return .init(along: centre.along - offset, across: centre.across - half)
            }
        }
        addPlayers(team: "home", edge)
        if d > 0 {
            let inside = (0..<d).map { index -> PlayerSpot in
                let angle = Double(index) / Double(d) * 2 * .pi
                let radius = d == 1 ? 0 : side * 0.15
                return .init(along: centre.along + cos(angle) * radius, across: centre.across + sin(angle) * radius)
            }
            addPlayers(team: "away", inside)
        }
        if let first = edge.first { addEquipment("ball", at: [(first.along + 1, first.across)]) }
        return "\(key.contains("possession") ? "Possession square" : "Rondo"): \(a) v \(d) in a \(Int(side)) × \(Int(side)) m square."
    }

    /// "5v2", "4 v 4", "3 against 2": the numbers the coach typed.
    static func counts(in text: String) -> (Int, Int)? {
        guard let match = text.lowercased().firstMatch(of: /(\d+)\s*(?:v|vs|versus|against|on)\.?\s*(\d+)/),
              let a = Int(match.1), let d = Int(match.2) else { return nil }
        return (a, d)
    }

    /// `count` players in up to two rows between `along`, spread evenly across.
    static func rows(count: Int, along: ClosedRange<Double>, across centre: Double, spread: Double) -> [PlayerSpot] {
        let perRow = count <= 4 ? count : Int((Double(count) / 2).rounded(.up))
        return (0..<count).map { index in
            let row = index / max(1, perRow), inRow = index % max(1, perRow)
            let rowCount = row == 0 ? perRow : count - perRow
            let across = rowCount <= 1 ? centre : centre - spread / 2 + spread * Double(inRow) / Double(rowCount - 1)
            let depth = count <= perRow ? (along.lowerBound + along.upperBound) / 2 : (row == 0 ? along.lowerBound : along.upperBound)
            return .init(along: depth, across: across)
        }
    }

    // MARK: Set pieces (we attack the goal at along = length)

    @discardableResult
    func setPiece(_ kind: String, side: String) -> String {
        let (length, width) = pitchSize
        let left = !side.lowercased().contains("right")
        setPieceSide = left ? 0 : width
        let key = kind.lowercased()
        let mid = width / 2, toward: Double = left ? -1 : 1
        if key.contains("corner") {
            let corner = (along: length - 0.5, across: left ? 0.5 : width - 0.5)
            addPlayers(team: "home", [.init(along: corner.along, across: corner.across, label: "Taker"),
                                      .init(along: length - 5, across: mid + toward * 4, label: "Near-post runner"),
                                      .init(along: length - 6, across: mid - toward * 5, label: "Far-post runner"),
                                      .init(along: length - 11, across: mid),
                                      .init(along: length - 12, across: mid - toward * 8),
                                      .init(along: length - 19, across: mid + toward * 5, label: "Edge")])
            addPlayers(team: "keeper", [.init(along: length - 1, across: mid)])
            addPlayers(team: "away", [.init(along: length - 1, across: mid + toward * 3.6), .init(along: length - 4, across: mid + toward * 3),
                                      .init(along: length - 5, across: mid - toward * 4), .init(along: length - 9, across: mid),
                                      .init(along: length - 10, across: mid - toward * 7), .init(along: length - 16, across: mid + toward * 4)])
            addEquipment("ball", at: [corner])
            return "Corner from the \(left ? "left" : "right"). " + roster(.home)
        }
        if key.contains("free") {
            let ball = (along: length - 24, across: mid + toward * 8)
            addPlayers(team: "home", [.init(along: ball.along - 1.5, across: ball.across, label: "Taker"),
                                      .init(along: length - 13, across: mid - 6), .init(along: length - 13, across: mid + 2),
                                      .init(along: length - 14, across: mid + 9), .init(along: length - 20, across: mid - toward * 12)])
            // A four-man wall 9.15 m from the ball, square to the goal.
            let dx = length - ball.along, dy = mid - ball.across, norm = max(0.1, hypot(dx, dy))
            let wall = (along: ball.along + dx / norm * 9.15, across: ball.across + dy / norm * 9.15)
            addPlayers(team: "away", (0..<4).map { .init(along: wall.along, across: wall.across + (Double($0) - 1.5) * 0.8) }
                       + [.init(along: length - 12, across: mid - 5), .init(along: length - 12, across: mid + 4)])
            addPlayers(team: "keeper", [.init(along: length - 1, across: mid - toward * 1.5)])
            addEquipment("ball", at: [ball])
            return "Free kick with a four-man wall. " + roster(.home)
        }
        if key.contains("penalty") {
            addPlayers(team: "home", [.init(along: length - 12.5, across: mid, label: "Taker")]
                       + [-14.0, -7, 7, 14].map { .init(along: length - 19, across: mid + $0) })
            addPlayers(team: "keeper", [.init(along: length - 0.5, across: mid)])
            addPlayers(team: "away", [-10.5, 0, 10.5].map { .init(along: length - 18.5, across: mid + $0) })
            addEquipment("ball", at: [(length - 11, mid)])
            return "Penalty with players waiting on the edge of the box."
        }
        if key.contains("throw") {
            let line = left ? 0.0 : width, into: Double = left ? 1 : -1, along = length * 0.65
            addPlayers(team: "home", [.init(along: along, across: line, label: "Thrower"), .init(along: along + 8, across: line + into * 4),
                                      .init(along: along - 6, across: line + into * 7), .init(along: along + 2, across: line + into * 14)])
            addPlayers(team: "away", [.init(along: along + 9, across: line + into * 6), .init(along: along - 4, across: line + into * 9),
                                      .init(along: along + 4, across: line + into * 16)])
            return "Throw-in on the \(left ? "left" : "right"). " + roster(.home)
        }
        if key.contains("goal") {
            addPlayers(team: "keeper", [.init(along: 5.5, across: mid)])
            addPlayers(team: "home", [.init(along: 10, across: mid - 14, number: 5, label: "CB"), .init(along: 10, across: mid + 14, number: 4, label: "CB"),
                                      .init(along: 26, across: 4, number: 3, label: "FB"), .init(along: 26, across: width - 4, number: 2, label: "FB"),
                                      .init(along: 20, across: mid, number: 6, label: "Pivot"), .init(along: 38, across: mid - 12, number: 10),
                                      .init(along: 38, across: mid + 12, number: 8), .init(along: 52, across: 6, number: 11),
                                      .init(along: 52, across: width - 6, number: 7), .init(along: 56, across: mid, number: 9)])
            addEquipment("ball", at: [(6.5, mid)])
            return "Goal kick, centre-backs split wide. " + roster(.home)
        }
        // Kick-off: two shapes in their own halves.
        placeFormation("4-4-2", team: "home")
        placeFormation("4-4-2", team: "away")
        addEquipment("ball", at: [(length / 2, mid)])
        return "Kick-off with both teams in a 4-4-2."
    }

    /// "Home players: 1 Taker, 2 Near-post runner, 3": what the model can refer to afterwards.
    func roster(_ side: BoardTeamSide) -> String {
        let players = document.teamElements(side).filter { $0.kind == .player }.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
        guard !players.isEmpty else { return "" }
        return "\(side.title) players: " + players.map { player in
            [player.number.map(String.init), player.label.isEmpty ? nil : player.label].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: ", ") + "."
    }

    // MARK: Zones

    @discardableResult
    func markZone(_ area: String, label: String?) -> String {
        let (l, w) = pitchSize
        let box = (l: 16.5, w: min(w, 40.3))
        let rect: (Double, Double, Double, Double) = switch area.lowercased() {
        case "left wing": (l * 0.35, l * 0.85, 0, w * 0.22)
        case "right wing": (l * 0.35, l * 0.85, w * 0.78, w)
        case "left half-space": (l * 0.5, l * 0.85, w * 0.2, w * 0.38)
        case "right half-space": (l * 0.5, l * 0.85, w * 0.62, w * 0.8)
        case "our box": (0, box.l, (w - box.w) / 2, (w + box.w) / 2)
        case "their box": (l - box.l, l, (w - box.w) / 2, (w + box.w) / 2)
        case "our half": (0, l / 2, 0, w)
        case "their half": (l / 2, l, 0, w)
        case "final third": (l * 2 / 3, l, 0, w)
        case "middle third": (l / 3, l * 2 / 3, 0, w)
        default: (l * 0.35, l * 0.7, w * 0.3, w * 0.7)
        }
        return markArea(fromAlong: rect.0, fromAcross: rect.2, toAlong: rect.1, toAcross: rect.3, label: label ?? area.capitalized)
    }

    // MARK: Movements between named players and spots

    /// A player ("home 9", "away 4", "keeper") or a named spot, in metres.
    func location(of name: String) -> (along: Double, across: Double)? {
        let (l, w) = pitchSize
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        let doc = document
        if let match = key.firstMatch(of: /(home|away|our|their)\D*(\d+)/), let number = Int(match.2) {
            let side: BoardTeamSide = match.1 == "away" || match.1 == "their" ? .away : .home
            if let element = doc.teamElements(side).first(where: { $0.number == number }) { return Self.metres(of: element.position, on: doc.fieldType) }
            return nil
        }
        if let labelled = doc.elements.first(where: { !$0.label.isEmpty && $0.kind.isPerson && key.contains($0.label.lowercased()) }) {
            return Self.metres(of: labelled.position, on: doc.fieldType)
        }
        if key.contains("keeper") || key.contains("goalkeeper") {
            let away = key.contains("their") || key.contains("away")
            if let element = doc.elements.first(where: { $0.kind == .goalkeeper && (away ? $0.position.x > 0.5 : $0.position.x < 0.5) }) {
                return Self.metres(of: element.position, on: doc.fieldType)
            }
        }
        let near: Double = setPieceSide == 0 ? -1 : 1
        return switch key {
        case "near post": (l - 1, w / 2 + near * 3.6)
        case "far post": (l - 1, w / 2 - near * 3.6)
        case "penalty spot": (l - 11, w / 2)
        case "edge of the box": (l - 18, w / 2)
        case "six-yard box": (l - 4, w / 2)
        case "left wing": (l * 0.7, w * 0.08)
        case "right wing": (l * 0.7, w * 0.92)
        case "centre circle": (l / 2, w / 2)
        case "their goal": (l, w / 2)
        case "our goal": (0, w / 2)
        default: nil
        }
    }

    @discardableResult
    func drawMovement(_ kind: String, from: String, to: String) -> String {
        guard let start = location(of: from) else { return "Unknown start \(from). Use a listed player (home 2) or a spot." }
        guard let end = location(of: to) else { return "Unknown end \(to). Use a listed player (home 2) or a spot." }
        return drawMovement(kind, fromAlong: start.along, fromAcross: start.across, toAlong: end.along, toAcross: end.across)
    }

    static func metres(of point: BoardPoint, on field: BoardFieldType) -> (along: Double, across: Double) {
        let size = size(of: field)
        return field == .footballHalf ? (point.y * size.along, (1 - point.x) * size.across) : (point.x * size.along, point.y * size.across)
    }
}
