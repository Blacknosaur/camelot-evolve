import SwiftData
import SwiftUI

/// The Squad tab: stored players with photos, numbers and details, grouped by team.
struct SquadView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SquadPlayer.name) private var players: [SquadPlayer]
    @State private var searchText = ""
    @State private var teamFilter: String?
    @State private var editing: SquadEditorTarget?
    @State private var deleting: SquadPlayer?
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            AdaptiveLayout { layout in
                Group {
                    if players.isEmpty {
                        emptyState
                    } else if groups.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else if layout.gridColumns > 1 {
                        grid(columns: layout.gridColumns)
                    } else {
                        list
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Squad")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search players")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add player", systemImage: "plus") { editing = .new(team: teamFilter) }
                        .accessibilityIdentifier("squad-add")
                }
            }
        }
        .sheet(item: $editing) { target in
            SquadPlayerEditor(target: target)
        }
        .confirmationDialog("Delete this player?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { player in
            Button("Delete \(player.name)", role: .destructive) {
                deleting = nil
                do { try player.delete(from: modelContext) } catch { saveError = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("The player and their photo are removed from this device. Boards keep the number and name already placed.")
        }
        .alert("Could not save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: Data

    private var teams: [String] { Array(Set(players.map(\.team))).sorted(by: SquadView.teamOrder) }

    private var groups: [(team: String, players: [SquadPlayer])] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = players.filter { player in
            (teamFilter == nil || player.team == teamFilter)
                && (query.isEmpty || player.name.localizedCaseInsensitiveContains(query) || player.number.map { "\($0)" == query } == true
                    || player.positionLabel.localizedCaseInsensitiveContains(query))
        }
        return Dictionary(grouping: filtered, by: \.team)
            .map { (team: $0.key, players: $0.value.sorted(by: SquadView.numberOrder)) }
            .sorted { SquadView.teamOrder($0.team, $1.team) }
    }

    /// Named teams alphabetically, then players without a team. Every team list and default
    /// team filter uses this, so a lone untagged player never hides a real squad.
    nonisolated static func teamOrder(_ a: String, _ b: String) -> Bool {
        if a.isEmpty != b.isEmpty { return !a.isEmpty }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    static func numberOrder(_ a: SquadPlayer, _ b: SquadPlayer) -> Bool {
        switch (a.number, b.number) {
        case let (x?, y?) where x != y: x < y
        case (_?, nil): true
        case (nil, _?): false
        default: a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Views

    private var teamChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Space.sm) {
                SquadFilterChip(title: "All", isOn: teamFilter == nil) { teamFilter = nil }
                ForEach(teams, id: \.self) { team in
                    SquadFilterChip(title: team.isEmpty ? "No team" : team, isOn: teamFilter == team) { teamFilter = teamFilter == team ? nil : team }
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.sm)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("squad-team-filter")
    }

    private var list: some View {
        List {
            // The chips scroll with the content rather than sitting in a fixed inset, so the
            // navigation bar still collapses its large title into "Squad" as the list scrolls.
            if teams.count > 1 {
                teamChips
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(groups, id: \.team) { group in
                Section {
                    ForEach(group.players) { player in
                        Button { editing = .edit(player) } label: { SquadPlayerRow(player: player) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("squad-player")
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = player }.tint(.red)
                                Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(player) }.tint(.gray)
                            }
                            .contextMenu { menu(for: player) }
                    }
                } header: {
                    teamHeader(group.team, count: group.players.count)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func grid(columns: Int) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                if teams.count > 1 { teamChips.padding(.horizontal, -Theme.Space.lg) }
                ForEach(groups, id: \.team) { group in
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        teamHeader(group.team, count: group.players.count).padding(.horizontal, Theme.Space.xs)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.md), count: columns), spacing: Theme.Space.md) {
                            ForEach(group.players) { player in
                                Button { editing = .edit(player) } label: {
                                    SquadPlayerRow(player: player)
                                        .padding(Theme.Space.md)
                                        .card()
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("squad-player")
                                .contextMenu { menu(for: player) }
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.lg)
        }
    }

    private func teamHeader(_ team: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(team.isEmpty ? "No team" : team)
            Spacer()
            Text(count == 1 ? "1 player" : "\(count) players").monospacedDigit()
        }
    }

    @ViewBuilder
    private func menu(for player: SquadPlayer) -> some View {
        Button("Edit", systemImage: "pencil") { editing = .edit(player) }
        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(player) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = player }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No players yet", systemImage: "person.3")
        } description: {
            Text("Add your players with a photo, number and position, then drop them onto any board.")
        } actions: {
            Button { editing = .new(team: nil) } label: {
                Label("Add player", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, Theme.Space.xl)
                    .frame(minHeight: 50)
                    .background(Theme.brand, in: .capsule)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("squad-add-empty")
        }
    }

    private func duplicate(_ player: SquadPlayer) {
        do { _ = try player.duplicate(in: modelContext) } catch { saveError = error.localizedDescription }
    }
}

enum SquadEditorTarget: Identifiable {
    case new(team: String?)
    case edit(SquadPlayer)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let player): player.id.uuidString
        }
    }
}

// MARK: - Components

/// Photo, name, position and number.
struct SquadPlayerRow: View {
    let player: SquadPlayer
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// One line normally; at accessibility sizes the row grows instead of turning into ellipses.
    private var lines: Int? { dynamicTypeSize.isAccessibilitySize ? nil : 1 }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            SquadAvatar(player: player, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(lines)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(lines)
                if !physical.isEmpty {
                    Text(physical).font(.caption).foregroundStyle(.tertiary).lineLimit(lines)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            if let number = player.number {
                SquadNumberBadge(number: number, tint: player.kitColor)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([player.number.map { "Number \($0)" }, player.name, detail, physical.isEmpty ? nil : physical].compactMap { $0 }.joined(separator: ", "))
    }

    private var detail: String {
        player.role.isEmpty ? player.squadPosition.title : "\(player.squadPosition.title) · \(player.role)"
    }

    /// Foot, birth year and height: what a coach expects to see without opening the editor.
    private var physical: String {
        [player.foot.map { "\($0.title) foot" }, player.birthYear.map(String.init), player.heightCm.map { "\($0) cm" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct SquadNumberBadge: View {
    let number: Int
    var tint: Color = Theme.brand

    var body: some View {
        Text("\(number)")
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(tint)
            .frame(minWidth: 34, minHeight: 28)
            .padding(.horizontal, 4)
            .background(tint.opacity(0.13), in: .rect(cornerRadius: 8))
    }
}

/// Circular photo, or initials on a kit-colour gradient.
struct SquadAvatar: View {
    let id: UUID
    let name: String
    let photoVersion: Int
    let tint: Color
    var size: CGFloat = 44
    /// A photo being edited (not yet saved) replaces the stored one.
    var override: CGImage?
    /// False while the editor has removed the photo but not saved yet.
    var loadsStoredPhoto = true
    @State private var image: CGImage?

    init(player: SquadPlayer, size: CGFloat = 44) {
        id = player.id; name = player.name; photoVersion = player.photoVersion; tint = player.kitColor; self.size = size
    }

    init(id: UUID, name: String, photoVersion: Int, tint: Color, size: CGFloat, override: CGImage? = nil, loadsStoredPhoto: Bool = true) {
        self.id = id; self.name = name; self.photoVersion = photoVersion; self.tint = tint; self.size = size
        self.override = override; self.loadsStoredPhoto = loadsStoredPhoto
    }

    var body: some View {
        ZStack {
            if let shown = override ?? image {
                Image(decorative: shown, scale: 1).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(SquadPlayerSnapshot.initials(of: name))
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay(Circle().strokeBorder(.primary.opacity(0.08)))
        .accessibilityHidden(true)
        .task(id: "\(id)-\(photoVersion)-\(loadsStoredPhoto)") {
            guard loadsStoredPhoto else { image = nil; return }
            let id = id
            image = await Task.detached(priority: .userInitiated) { SquadPhotoStore.image(for: id) }.value
        }
    }
}

struct SquadFilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(isOn ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.fill.tertiary), in: .capsule)
                .foregroundStyle(isOn ? .white : .primary)
                // The capsule stays compact; the tap area around it is a full target.
                .frame(minHeight: Theme.tapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension SquadPlayer {
    /// Kit colour when set, else a calm per-position tint for avatars.
    var kitColor: Color {
        if let colorHex { return BoardPalette.color(colorHex) }
        switch squadPosition {
        case .goalkeeper: return Color(red: 0.93, green: 0.64, blue: 0.13)
        case .defender: return Theme.brand
        case .midfielder: return Color(red: 0.2, green: 0.62, blue: 0.45)
        case .forward: return Theme.highlight
        }
    }
}
