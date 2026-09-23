import Foundation

/// What the Draw banner offers, in the order coaches reach for it. Lines carry
/// the style they draw with.
struct BoardPaletteItem: Identifiable, Equatable {
    let tool: BoardTool
    let title: String
    var lineStyle: BoardLineStyle? = nil
    var id: String { "\(tool.rawValue)-\(title)" }

    init(_ tool: BoardTool, _ title: String, lineStyle: BoardLineStyle? = nil) {
        self.tool = tool; self.title = title; self.lineStyle = lineStyle
    }

    /// Accessibility identifier: `board-draw-<tool>` or `board-draw-<title>` for line presets.
    var identifier: String { lineStyle == nil ? "board-draw-\(tool.rawValue)" : "board-draw-\(title.lowercased())" }

    static let drawItems: [BoardPaletteItem] = [
        .init(.line, "Pass", lineStyle: .pass), .init(.line, "Run", lineStyle: .run), .init(.line, "Dribble", lineStyle: .dribble),
        .init(.polyline, "Path"), .init(.zoneRect, "Area"), .init(.zoneEllipse, "Round area"),
        .init(.polygon, "Shape"), .init(.text, "Text"),
    ]

    static let drawTools: Set<BoardTool> = Set(drawItems.map(\.tool))
}
