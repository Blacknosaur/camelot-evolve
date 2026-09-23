import Foundation

/// The pages the board's bottom bar opens while placing: what a coach reaches
/// for, in the order they reach for it. Everything else stays in the library.
enum BoardPalettePage: String, CaseIterable, Identifiable {
    case players, equipment, draw
    var id: String { rawValue }

    var title: String {
        switch self {
        case .players: "Players"
        case .equipment: "Equipment"
        case .draw: "Draw"
        }
    }

    var symbol: String {
        switch self {
        case .players: "person.2.fill"
        case .equipment: "cone.fill"
        case .draw: "arrow.up.right"
        }
    }

    var items: [BoardPaletteItem] {
        switch self {
        case .players:
            [.init(.home, "Home"), .init(.away, "Away"), .init(.keeper, "Keeper"), .init(.opponent, "Opponent"),
             .init(.ball, "Ball"), .init(.coach, "Coach"), .init(.referee, "Referee")]
        case .equipment:
            [.init(.cone, "Cone"), .init(.tallCone, "Tall cone"), .init(.domeCone, "Dome"), .init(.marker, "Marker"),
             .init(.pole, "Pole"), .init(.hurdle, "Hurdle"), .init(.ladder, "Ladder"), .init(.ring, "Ring"),
             .init(.mannequin, "Dummy"), .init(.wall, "Wall"), .init(.miniGoal, "Mini goal"), .init(.goal, "Goal"),
             .init(.popUpGoal, "Pop-up goal"), .init(.rebounder, "Rebounder"), .init(.flag, "Flag"),
             .init(.ballCart, "Ball bag"), .init(.stepMarker, "Step")]
        case .draw:
            [.init(.line, "Pass", lineStyle: .pass), .init(.line, "Run", lineStyle: .run), .init(.line, "Dribble", lineStyle: .dribble),
             .init(.polyline, "Path"), .init(.zoneRect, "Area"), .init(.zoneEllipse, "Round area"),
             .init(.polygon, "Shape"), .init(.text, "Text")]
        }
    }

    /// The item armed when the page opens, so the first tap on the pitch already does something.
    var defaultItem: BoardPaletteItem { items[0] }

    /// The page that offers `tool`, for items armed from the library.
    static func page(for tool: BoardTool) -> BoardPalettePage? {
        allCases.first { page in page.items.contains { $0.tool == tool } }
    }
}

/// One tile in a palette page. Lines carry the style they draw with.
struct BoardPaletteItem: Identifiable, Equatable {
    let tool: BoardTool
    let title: String
    var lineStyle: BoardLineStyle? = nil
    var id: String { "\(tool.rawValue)-\(title)" }

    init(_ tool: BoardTool, _ title: String, lineStyle: BoardLineStyle? = nil) {
        self.tool = tool; self.title = title; self.lineStyle = lineStyle
    }

    /// Accessibility identifier: `board-item-<tool>` or `board-item-line-<title>` for line presets.
    var identifier: String { lineStyle == nil ? "board-item-\(tool.rawValue)" : "board-item-line-\(title.lowercased())" }
}
