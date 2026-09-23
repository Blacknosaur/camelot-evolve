import SwiftUI

/// Compact, searchable sheet with every placeable board element grouped by category.
/// Picking an item arms its tool in the editor.
struct TacticalBoardLibrarySheet: View {
    let document: BoardDocument
    /// Recently used items shown in a row at the top.
    var recents: [BoardTool] = []
    let onPick: (BoardTool) -> Void
    /// A squad player to place (from `SquadPlacementSection`).
    let onPickTemplate: (BoardElement) -> Void
    /// Squad players placed in a formation (one undoable change in the editor).
    let onLineup: SquadLineupHandler
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var category: String?

    struct Category: Identifiable {
        let title: String
        let tools: [BoardTool]
        var id: String { title }
    }

    static let categories: [Category] = [
        Category(title: "Players", tools: [.home, .away, .keeper, .opponent]),
        Category(title: "Equipment", tools: [.cone, .tallCone, .domeCone, .marker, .pole, .hurdle, .ladder, .ring, .mannequin, .wall, .ball, .ballCart, .rebounder]),
        Category(title: "Goals", tools: [.goal, .miniGoal, .popUpGoal]),
        Category(title: "Markers", tools: [.flag, .stepMarker]),
        Category(title: "Lines", tools: [.line, .polyline, .zoneRect, .zoneEllipse, .polygon, .text]),
        Category(title: "Staff", tools: [.coach, .referee]),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.lg, pinnedViews: [.sectionHeaders]) {
                  Section {
                    if search.isEmpty && category == nil && !recents.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            Text("Recent").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, Theme.Space.xs)
                            HStack(spacing: Theme.Space.sm) {
                                ForEach(recents) { tool in tile(tool, idPrefix: "board-library-recent-") }
                            }
                        }
                    }
                    ForEach(filtered) { category in
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            Text(category.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, Theme.Space.xs)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: Theme.Space.sm)], spacing: Theme.Space.sm) {
                                ForEach(category.tools) { tool in tile(tool) }
                            }
                            if category.title == "Players" && search.isEmpty {
                                SquadPlacementSection(onPick: { player in onPickTemplate(document.element(for: player, at: .center)) }, document: document, onLineup: onLineup)
                            }
                        }
                    }
                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: search).padding(.top, Theme.Space.xl)
                    }
                  } header: {
                    categoryBar
                  }
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.bottom, Theme.Space.lg)
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search elements")
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.inkPanel)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("board-library-sheet")
    }

    /// Category filter chips, pinned under the search field so nothing needs long scrolling.
    private var categoryBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach([nil] + Self.categories.map(\.title), id: \.self) { title in
                    let isOn = category == title
                    Button { withAnimation(.snappy(duration: 0.2)) { category = title } } label: {
                        Text(title ?? "All").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).frame(minHeight: 34)
                            .background(isOn ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(.white.opacity(0.1)), in: .capsule)
                            .foregroundStyle(isOn ? .black : .white)
                            .frame(minHeight: Theme.tapTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityIdentifier("board-library-category-\(title ?? "All")")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .background(Theme.inkPanel)
    }

    private var filtered: [Category] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let scoped = category.map { title in Self.categories.filter { $0.title == title } } ?? Self.categories
        guard !query.isEmpty else { return scoped }
        return scoped.compactMap { category in
            let tools = category.tools.filter { $0.title.localizedCaseInsensitiveContains(query) || category.title.localizedCaseInsensitiveContains(query) }
            return tools.isEmpty ? nil : Category(title: category.title, tools: tools)
        }
    }

    private func tile(_ tool: BoardTool, idPrefix: String = "board-library-") -> some View {
        Button { onPick(tool) } label: {
            VStack(spacing: 4) {
                BoardLibraryPreview(element: Self.sample(for: tool, document: document), field: document.fieldType, style: document.fieldStyle)
                    .frame(height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                Text(tool.title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(.white)
            }
            .padding(5)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityIdentifier("\(idPrefix)\(tool.rawValue)")
    }

    /// A representative element for a tool's preview tile.
    static func sample(for tool: BoardTool, document: BoardDocument) -> BoardElement {
        let center = BoardPoint.center
        switch tool {
        case .home: return BoardElement(kind: .player, position: center, colorHex: document.homeColorHex, number: 7)
        case .away: return BoardElement(kind: .player, position: center, colorHex: document.awayColorHex, number: 9)
        case .keeper: return BoardElement(kind: .goalkeeper, position: center, colorHex: BoardPalette.keeper, number: 1)
        case .line:
            var line = BoardElement(kind: .line, position: BoardPoint(0.44, 0.54), points: [BoardPoint(0.56, 0.46)])
            line.lineStyle = BoardLineStyle()
            return line
        case .polyline:
            var line = BoardElement(kind: .polyline, position: BoardPoint(0.44, 0.55), points: [BoardPoint(0.5, 0.45), BoardPoint(0.56, 0.54)])
            line.lineStyle = BoardLineStyle(pattern: .dashed)
            return line
        case .zoneRect, .zoneEllipse:
            var zone = BoardElement(kind: .zone, position: BoardPoint(0.44, 0.44), points: [BoardPoint(0.56, 0.56)], colorHex: BoardPalette.keeper)
            zone.zoneShape = tool == .zoneEllipse ? .ellipse : .rectangle
            return zone
        case .polygon:
            return BoardElement(kind: .polygon, position: BoardPoint(0.44, 0.56), points: [BoardPoint(0.5, 0.43), BoardPoint(0.57, 0.53)], colorHex: BoardPalette.keeper)
        case .text: return BoardElement(kind: .text, position: center, label: "Aa")
        case .stepMarker: return BoardElement(kind: .stepMarker, position: center, colorHex: BoardRenderer.defaultColor(for: .stepMarker, document: document), number: 1)
        default:
            let kind = tool.pointKind ?? .cone
            var element = BoardElement(kind: kind, position: center, colorHex: BoardRenderer.defaultColor(for: kind, document: document))
            if kind == .wall { element.count = 4 }
            return element
        }
    }
}

/// Draws one element with `BoardRenderer`, zoomed so it fills the tile on its field style.
struct BoardLibraryPreview: View {
    let element: BoardElement
    let field: BoardFieldType
    let style: BoardFieldStyle

    var body: some View {
        Canvas { context, size in
            var document = BoardDocument()
            document.fieldType = field
            document.style = style
            document.elements = [element]
            let virtual = CGSize(width: 900, height: 600)
            // A tile shows one element a few dozen points across: painting the whole pitch behind it costs
            // a full surface bake and pushes the editor's canvas out of the cache. A flat fill reads the same.
            let renderer = BoardRenderer(document: document, drawsSurface: false)
            let projection = renderer.projection(size: virtual)
            let extent: CGFloat
            let center: CGPoint
            if element.kind.isPoint {
                center = projection.point(element.position)
                extent = max(renderer.pointRadius(element, projection: projection) * 2.7, projection.unit * 9)
            } else {
                let points = projection.points(element.allPoints)
                let box = points.dropFirst().reduce(CGRect(origin: points[0], size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
                center = CGPoint(x: box.midX, y: box.midY)
                extent = max(box.width, box.height) * 1.5
            }
            let scale = min(size.width, size.height) / max(1, extent)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(uiColor: style.previewColor)))
            context.withCGContext { cg in
                cg.translateBy(x: size.width / 2, y: size.height / 2)
                cg.scaleBy(x: scale, y: scale)
                cg.translateBy(x: -center.x, y: -center.y)
                renderer.draw(in: cg, size: virtual)
            }
        }
        .accessibilityHidden(true)
    }
}
