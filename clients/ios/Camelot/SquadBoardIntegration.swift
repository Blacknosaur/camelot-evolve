import SwiftData
import SwiftUI

// MARK: - Library section

/// Squad players in the board's element library. Tapping a player arms placement of that player
/// (`onPick`); "Add lineup" opens `SquadLineupSheet` for `document` and hands back the elements to
/// insert as one change plus a short summary (`onLineup`).
struct SquadPlacementSection: View {
    let onPick: (SquadPlayerSnapshot) -> Void
    let document: BoardDocument
    let onLineup: SquadLineupHandler
    @Query(sort: \SquadPlayer.name) private var players: [SquadPlayer]
    @State private var team: String?
    @State private var showingLineup = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Squad").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { showingLineup = true } label: {
                    Label("Add lineup", systemImage: "person.3.sequence.fill").font(.subheadline.weight(.semibold))
                        .frame(minHeight: Theme.tapTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("squad-add-lineup")
            }
            if players.isEmpty {
                Text("Add players with photos in the Squad tab to place them here.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                if teams.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: Theme.Space.xs) {
                            ForEach(teams, id: \.self) { name in
                                SquadFilterChip(title: name.isEmpty ? "No team" : name, isOn: selectedTeam == name) { team = name }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Theme.Space.md) {
                        ForEach(visiblePlayers) { player in
                            Button { onPick(player.snapshot) } label: { SquadPlayerTile(player: player) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("squad-place-player")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
        .sheet(isPresented: $showingLineup) {
            SquadLineupSheet(document: document, initialSquadTeam: selectedTeam, onPlace: onLineup)
        }
    }

    private var teams: [String] { SquadLineupSheet.squadTeams(of: players) }
    private var selectedTeam: String? { team ?? teams.first }
    private var visiblePlayers: [SquadPlayer] {
        players.filter { teams.count <= 1 || $0.team == selectedTeam }.sorted(by: SquadView.numberOrder)
    }
}

/// Compact avatar tile: photo with number badge and first name.
private struct SquadPlayerTile: View {
    let player: SquadPlayer

    var body: some View {
        VStack(spacing: 4) {
            SquadAvatar(player: player, size: 52)
                .overlay(alignment: .bottomTrailing) {
                    if let number = player.number {
                        Text("\(number)")
                            .font(.caption2.weight(.heavy).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 20, minHeight: 18)
                            .background(player.kitColor, in: .capsule)
                            .overlay(Capsule().stroke(Color(.systemBackground), lineWidth: 1.5))
                            .offset(x: 4, y: 2)
                    }
                }
            Text(SquadPlayerSnapshot(id: player.id, name: player.name, position: player.squadPosition).boardLabel)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .frame(width: 64)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([player.number.map { "Number \($0)" }, player.name].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: - Inspector link

/// Inspector control for a person element: "Linked to <name>" with Unlink / Change player, or
/// "Link to squad player…". `onLink(nil)` unlinks.
struct SquadLinkControl: View {
    let element: BoardElement
    let onLink: (SquadPlayerSnapshot?) -> Void
    @Query(sort: \SquadPlayer.name) private var players: [SquadPlayer]
    @State private var choosing = false

    var body: some View {
        Group {
            if let linked {
                Menu {
                    Button("Change player…", systemImage: "arrow.triangle.swap") { choosing = true }
                    Button("Unlink", systemImage: "link.badge.minus", role: .destructive) { onLink(nil) }
                } label: {
                    chipLabel("Linked to \(linked.name)", symbol: "link", avatar: linked)
                }
                .accessibilityIdentifier("board-squad-linked")
            } else if !players.isEmpty {
                Button { choosing = true } label: { chipLabel("Link to squad player…", symbol: "link.badge.plus", avatar: nil) }
                    .accessibilityIdentifier("board-squad-link")
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $choosing) {
            SquadPlayerChooser(currentID: element.playerID) { onLink($0) }
        }
    }

    private var linked: SquadPlayer? {
        element.playerID.flatMap { id in players.first { $0.id == id } }
    }

    private func chipLabel(_ title: String, symbol: String, avatar: SquadPlayer?) -> some View {
        HStack(spacing: 6) {
            if let avatar {
                SquadAvatar(player: avatar, size: 24)
            } else {
                Image(systemName: symbol).font(.subheadline.weight(.semibold))
            }
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .padding(.leading, avatar == nil ? 12 : 6)
        .padding(.trailing, 12)
        .frame(height: 36)
        .background(.white.opacity(0.1), in: .capsule)
        .foregroundStyle(.white)
        .frame(minHeight: Theme.tapTarget)
        .contentShape(.rect)
    }
}

/// Searchable list for linking a board element to a squad player.
struct SquadPlayerChooser: View {
    var currentID: UUID?
    let onPick: (SquadPlayerSnapshot) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SquadPlayer.name) private var players: [SquadPlayer]
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.team) { group in
                    Section(group.team.isEmpty ? "No team" : group.team) {
                        ForEach(group.players) { player in
                            Button { dismiss(); onPick(player.snapshot) } label: {
                                HStack {
                                    SquadPlayerRow(player: player)
                                    if player.id == currentID {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.brand).accessibilityHidden(true)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(player.id == currentID ? "Linked" : "")
                            .accessibilityAddTraits(player.id == currentID ? .isSelected : [])
                            .accessibilityIdentifier("squad-choose-player")
                        }
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search players")
            .navigationTitle("Squad player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var groups: [(team: String, players: [SquadPlayer])] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = players.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.number.map { "\($0)" == query } == true }
        return Dictionary(grouping: filtered, by: \.team)
            .map { (team: $0.key, players: $0.value.sorted(by: SquadView.numberOrder)) }
            .sorted { SquadView.teamOrder($0.team, $1.team) }
    }
}

extension BoardDocument {
    /// Links (or with nil unlinks) a person element. Linking copies number, label and kind from the player.
    mutating func link(_ id: UUID, to player: SquadPlayerSnapshot?) {
        update(id) { element in
            element.playerID = player?.id
            guard let player else { return }
            element.number = player.number
            element.label = player.boardLabel
            if element.kind == .player || element.kind == .goalkeeper { element.kind = player.elementKind }
            if let kit = player.colorHex { element.colorHex = kit }
        }
    }
}
