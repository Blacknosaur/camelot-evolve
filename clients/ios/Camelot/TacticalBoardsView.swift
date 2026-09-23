import SwiftData
import SwiftUI

/// The Boards tab: every tactical board on this device, independent of projects.
struct TacticalBoardsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TacticalBoard.updatedAt, order: .reverse) private var boards: [TacticalBoard]
    @State private var editingBoard: TacticalBoard?
    @State private var renamingBoard: TacticalBoard?
    @State private var deletingBoard: TacticalBoard?
    @State private var boardName = ""
    @State private var searchText = ""
    /// Set when an action was refused because the board's stored data cannot be read.
    @State private var unopenable: BoardLoadError?

    var body: some View {
        NavigationStack {
            AdaptiveLayout { layout in
                Group {
                    if boards.isEmpty {
                        emptyState
                    } else if filteredBoards.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        grid(columns: max(2, layout.gridColumns + (layout.isLandscape ? 1 : 0)))
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Boards")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search boards")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    newBoardMenu {
                        Label("New board", systemImage: "plus")
                    }
                    .accessibilityIdentifier("boards-new")
                }
            }
        }
        .fullScreenCover(item: $editingBoard) { TacticalBoardView(board: $0) }
        .alert("Rename board", isPresented: Binding(get: { renamingBoard != nil }, set: { if !$0 { renamingBoard = nil } }), presenting: renamingBoard) { board in
            TextField("Board name", text: $boardName)
            Button("Save") {
                let trimmed = boardName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { board.name = trimmed; board.updatedAt = .now; try? modelContext.save() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this board?", isPresented: Binding(get: { deletingBoard != nil }, set: { if !$0 { deletingBoard = nil } }), titleVisibility: .visible, presenting: deletingBoard) { board in
            Button("Delete board", role: .destructive) { delete(board) }
            Button("Cancel", role: .cancel) { deletingBoard = nil }
        } message: { _ in
            Text("The board and its animation are removed from this device. This cannot be undone.")
        }
        .alert("Can't open this board", isPresented: Binding(get: { unopenable != nil }, set: { if !$0 { unopenable = nil } }), presenting: unopenable) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text("\(error.message) Its saved data is left untouched.")
        }
    }

    private var filteredBoards: [TacticalBoard] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return boards }
        return boards.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.field.title.localizedCaseInsensitiveContains(query) }
    }

    private func newBoardMenu(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            Section("New board") {
                ForEach(BoardFieldType.allCases, id: \.self) { field in
                    Button(field.title, systemImage: field.symbol) { createBoard(field) }
                }
            }
        } label: {
            label()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No boards yet", systemImage: "sportscourt")
        } description: {
            Text("Sketch set pieces, drills and patterns of play. Animate them and share as images or videos.")
        } actions: {
            newBoardMenu {
                Label("New board", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, Theme.Space.xl)
                    .frame(minHeight: 50)
                    .background(Theme.brand, in: .capsule)
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("boards-new-empty")
        }
    }

    private func grid(columns: Int) -> some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.md), count: columns), spacing: Theme.Space.md) {
                if searchText.isEmpty {
                    newBoardMenu { NewBoardTile() }
                        .accessibilityIdentifier("boards-new-tile")
                }
                ForEach(filteredBoards) { board in
                    Button { editingBoard = board } label: { TacticalBoardCard(board: board) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("board-card")
                        .contextMenu {
                            Button("Open", systemImage: "pencil.and.outline") { editingBoard = board }
                            Button("Rename", systemImage: "pencil") { boardName = board.name; renamingBoard = board }
                            Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(board) }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) { deletingBoard = board }
                        }
                }
            }
            .padding(Theme.Space.lg)
        }
    }

    private func createBoard(_ field: BoardFieldType) {
        var document = BoardDocument()
        document.fieldType = field
        let board = TacticalBoard(name: nextName(), document: document)
        modelContext.insert(board)
        try? modelContext.save()
        editingBoard = board
    }

    private func nextName() -> String {
        var base = "Board"
        #if DEBUG
        // UI tests name boards from creation, so cleanup finds them even if a later step fails.
        if ProcessInfo.processInfo.arguments.contains("-uiTestBoards") { base = DebugSeeding.uiTestBoardPrefix + "Board" }
        #endif
        let names = Set(boards.map(\.name))
        var index = boards.count + 1
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func duplicate(_ board: TacticalBoard) {
        // Duplicating a board that cannot be read would quietly make an empty copy of it.
        do {
            try board.duplicate(into: modelContext)
            try? modelContext.save()
        } catch {
            unopenable = error as? BoardLoadError ?? .unreadable
        }
    }

    private func delete(_ board: TacticalBoard) {
        deletingBoard = nil
        board.delete(from: modelContext)
        try? modelContext.save()
    }
}

/// Dashed tile that opens the field picker.
private struct NewBoardTile: View {
    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .frame(width: 48, height: 48)
                .background(Theme.brand.opacity(0.12), in: .circle)
            Text("New board").font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(Theme.brand)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 150)
        .background(.background.opacity(0.5), in: .rect(cornerRadius: Theme.Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.brand.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .contentShape(.rect(cornerRadius: Theme.Radius.large))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New board")
    }
}

/// Thumbnail card; the preview is the PNG the editor writes on close (rendered here when missing).
private struct TacticalBoardCard: View {
    let board: TacticalBoard
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color(white: 0.08)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: board.field.symbol).font(.title2).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.large, topTrailingRadius: Theme.Radius.large))
            VStack(alignment: .leading, spacing: 3) {
                Text(board.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text("\(board.field.title) · \(friendlyDate(board.updatedAt))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm + 2)
        }
        .card()
        .contentShape(.rect(cornerRadius: Theme.Radius.large))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(board.name), \(board.field.title), \(friendlyDate(board.updatedAt))")
        .accessibilityAddTraits(.isButton)
        .task(id: board.updatedAt) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        let url = board.thumbnailURL
        let field = board.field, isTop = BoardViewAngle(rawValue: board.viewAngle)?.is3D != true
        if let cached = await Task.detached(priority: .utility, operation: { UIImage(contentsOfFile: url.path(percentEncoded: false)).map { isTop ? Self.croppedToPitch($0, field: field) : $0 } }).value {
            image = cached
            return
        }
        // No thumbnail yet (new renderer or never closed): draw one from the document.
        // An unreadable board keeps its placeholder icon rather than showing an empty pitch.
        guard let document = board.loadedDocument else { return }
        let legacy = board.allThumbnailURLs.filter { $0 != url }
        image = await Task.detached(priority: .utility) {
            try? TacticalBoardExporter.writeThumbnail(document: document, to: url)
            for old in legacy { try? FileManager.default.removeItem(at: old) }
            return UIImage(contentsOfFile: url.path(percentEncoded: false)).map { isTop ? Self.croppedToPitch($0, field: field) : $0 }
        }.value
    }

    /// Top-view thumbnails are letterboxed on the export background; crop to the pitch so the card
    /// image area is filled edge to edge. Mirrors the exporter's thumbnail layout (4% inset).
    nonisolated private static func croppedToPitch(_ image: UIImage, field: BoardFieldType) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let size = image.size
        let frame = BoardProjection(field: field, size: size, inset: min(size.width, size.height) * 0.04).surfaceFrame
        let trimmed = frame.insetBy(dx: frame.width * 0.02, dy: frame.height * 0.02)
        let pixels = CGRect(x: trimmed.minX * image.scale, y: trimmed.minY * image.scale, width: trimmed.width * image.scale, height: trimmed.height * image.scale).integral
        guard let cropped = cgImage.cropping(to: pixels) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }
}
