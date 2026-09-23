import Foundation

/// The tags a coach can drop on a recording. Shared with the companion camera app.
enum EventKind: String, CaseIterable, Identifiable {
    case goal = "Goal"
    case shot = "Shot"
    case save = "Save"
    case foul = "Foul"
    case card = "Card"
    case note = "Note"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .goal: "soccerball"
        case .shot: "scope"
        case .save: "hand.raised"
        case .foul: "exclamationmark.triangle"
        case .card: "rectangle.portrait"
        case .note: "text.bubble"
        }
    }
    var defaultPreRoll: Double { self == .goal ? 15 : 10 }
    var defaultPostRoll: Double { self == .goal ? 5 : 10 }
}
