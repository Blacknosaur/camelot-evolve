import SwiftData
import SwiftUI

/// Receives the elements to insert as one undoable change and a short toast summary.
typealias SquadLineupHandler = (_ elements: [BoardElement], _ summary: String) -> Void

/// Places a formation for Home or Away: chosen squad players go to slots of their position, and
/// "Fill empty slots" adds generic numbered players for the rest (with no squad players selected
/// this places a full team). "Fill remaining" only adds players to slots the side has not covered.
struct SquadLineupSheet: View {
    let document: BoardDocument
    var initialSide: BoardTeamSide = .home
    var initialSquadTeam: String?
    let onPlace: SquadLineupHandler
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SquadPlayer.name) private var players: [SquadPlayer]
    @State private var side: BoardTeamSide = .home
    @State private var formation: SquadFormation = .f433
    @State private var fillsEmptySlots = true
    @State private var squadTeam: String?
    @State private var selection: [UUID] = []
    @State private var didLoad = false

    static let maximum = 11

    static func squadTeams(of players: [SquadPlayer]) -> [String] {
        Array(Set(players.map(\.team))).sorted(by: SquadView.teamOrder)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section {
                        Picker("Team", selection: $side) {
                            ForEach(BoardTeamSide.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("squad-lineup-side")
                        .listRowSeparator(.hidden)
                        formationPicker
                    } footer: {
                        Text(side == .home ? "Placed in your own half." : "Placed in the other half, in the away colour.")
                    }

                    Section {
                        Toggle("Fill empty slots", isOn: $fillsEmptySlots)
                            .accessibilityIdentifier("squad-lineup-fill")
                        if !document.teamElements(side).isEmpty {
                            Button {
                                place(remaining, summary: "Filled \(remaining.count) \(side.title.lowercased()) slots")
                            } label: {
                                Label(remaining.isEmpty ? "\(side.title) slots are all covered" : "Fill remaining for \(side.title) (\(remaining.count))",
                                      systemImage: "person.crop.circle.badge.plus")
                            }
                            .disabled(remaining.isEmpty)
                            .accessibilityIdentifier("squad-lineup-fill-remaining")
                        }
                    } footer: {
                        Text("Empty slots get numbered \(side.title.lowercased()) players. Fill remaining keeps players already on the board and adds only the missing positions.")
                    }

                    playersSection
                }
                // The Place button sits below the list rather than floating over it, so the last player
                // row is always tappable and a tap near the bottom never lands on Place by mistake.
                placeBar
            }
            .navigationTitle("Add lineup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                side = initialSide
                squadTeam = initialSquadTeam
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Sections

    private var placeBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button { place(planned, summary: "Placed \(planned.count) \(side.title.lowercased()) players in \(formation.title)") } label: {
                Text(primaryTitle)
            }
            .buttonStyle(.primary)
            .disabled(planned.isEmpty)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.xs)
            .accessibilityIdentifier("squad-lineup-place")
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    /// All five fit across a 375 pt phone without scrolling.
    private var formationPicker: some View {
        HStack(spacing: 4) {
                ForEach(SquadFormation.allCases) { item in
                    Button { formation = item } label: {
                        VStack(spacing: 4) {
                            FormationPreview(formation: item, tint: BoardPalette.color(document.colorHex(for: side)), keeperTint: BoardPalette.color(side == .home ? BoardPalette.keeper : document.awayColorHex))
                                .aspectRatio(1.4, contentMode: .fit)
                            Text(item.title).font(.caption2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity)
                        .background(formation == item ? Theme.brand.opacity(0.16) : Color.clear, in: .rect(cornerRadius: Theme.Radius.small))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(formation == item ? Theme.brand : .clear, lineWidth: 1.5))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Formation \(item.title)")
                    .accessibilityAddTraits(formation == item ? .isSelected : [])
                    .accessibilityIdentifier("squad-formation-\(item.title)")
                }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var playersSection: some View {
        Section {
            if squadTeams.count > 1 {
                Picker("Squad", selection: Binding(get: { selectedSquadTeam ?? "" }, set: { squadTeam = $0 })) {
                    ForEach(squadTeams, id: \.self) { Text($0.isEmpty ? "No team" : $0).tag($0) }
                }
            }
            if teamPlayers.isEmpty {
                Text("No squad players yet. Numbered players fill the formation.").foregroundStyle(.secondary)
            }
            ForEach(teamPlayers) { player in
                let isOn = selection.contains(player.id)
                Button { toggle(player) } label: {
                    HStack {
                        SquadPlayerRow(player: player)
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isOn ? Theme.brand : Color.secondary.opacity(0.5))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!isOn && selection.count >= Self.maximum)
                .accessibilityIdentifier("squad-lineup-player")
                .accessibilityValue(isOn ? "In the lineup" : "Not in the lineup")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        } header: {
            HStack {
                Text("Squad players · \(selection.count) of \(Self.maximum)").monospacedDigit()
                Spacer()
                if selection.isEmpty {
                    Button("Pick 11") { autoPick() }.disabled(teamPlayers.isEmpty)
                } else {
                    Button("Clear") { selection = [] }
                }
            }
            .textCase(nil)
        }
    }

    // MARK: Plan

    private var squadTeams: [String] { Self.squadTeams(of: players) }
    private var selectedSquadTeam: String? { squadTeam ?? squadTeams.first }
    private var teamPlayers: [SquadPlayer] {
        players.filter { squadTeams.count <= 1 || $0.team == selectedSquadTeam }.sorted(by: SquadView.numberOrder)
    }
    private var chosen: [SquadPlayerSnapshot] { selection.compactMap { id in players.first { $0.id == id }?.snapshot } }
    private var planned: [BoardElement] {
        document.lineupElements(chosen, formation: formation, side: side, fillsEmptySlots: fillsEmptySlots)
    }
    private var remaining: [BoardElement] { document.fillRemainingElements(formation: formation, side: side) }

    private var primaryTitle: String {
        let total = planned.count, fromSquad = min(chosen.count, total)
        if fromSquad == 0 { return total == 0 ? "Select players or fill slots" : "Place full team (\(total))" }
        if total == fromSquad { return "Place \(total) player\(total == 1 ? "" : "s")" }
        return "Place \(total) players (\(fromSquad) from squad)"
    }

    private func place(_ elements: [BoardElement], summary: String) {
        guard !elements.isEmpty else { return }
        dismiss()
        onPlace(elements, summary)
    }

    /// One keeper, then outfield players by number.
    private func autoPick() {
        let list = teamPlayers
        let keeper = list.first { $0.squadPosition == .goalkeeper }
        let outfield = list.filter { $0.squadPosition != .goalkeeper }.prefix(Self.maximum - (keeper == nil ? 0 : 1))
        selection = ([keeper].compactMap { $0 } + outfield).map(\.id)
    }

    private func toggle(_ player: SquadPlayer) {
        if let index = selection.firstIndex(of: player.id) { selection.remove(at: index) } else if selection.count < Self.maximum { selection.append(player.id) }
    }
}

/// Mini pitch with a formation's eleven dots, drawn with the attack to the right.
private struct FormationPreview: View {
    let formation: SquadFormation
    let tint: Color
    let keeperTint: Color

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(Color(red: 0.2, green: 0.5, blue: 0.3)))
            context.stroke(Path { $0.move(to: CGPoint(x: size.width - 1, y: 0)); $0.addLine(to: CGPoint(x: size.width - 1, y: size.height)) }, with: .color(.white.opacity(0.4)), lineWidth: 1)
            let dot: CGFloat = max(3.5, size.width / 13)
            for slot in formation.slots {
                // Attack to the right, so the team's right (width 0) is at the bottom.
                let x = 3 + slot.depth * (size.width - 8), y = 3 + (1 - slot.width) * (size.height - 6)
                let color = slot.position == .goalkeeper ? keeperTint : tint
                context.fill(Path(ellipseIn: CGRect(x: x - dot / 2 + 1, y: y - dot / 2, width: dot, height: dot)), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// "Fill team…" for the element card: opens the lineup sheet on the element's side.
struct SquadFillTeamButton: View {
    let document: BoardDocument
    let element: BoardElement
    let onPlace: SquadLineupHandler
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Label("Fill team…", systemImage: "person.3.sequence.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.white.opacity(0.1), in: .capsule)
                .foregroundStyle(.white)
                .frame(minHeight: Theme.tapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("board-squad-fill-team")
        .sheet(isPresented: $showing) {
            SquadLineupSheet(document: document, initialSide: element.colorHex == document.awayColorHex ? .away : .home, onPlace: onPlace)
        }
    }
}
