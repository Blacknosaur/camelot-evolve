import SwiftUI

/// Source tracks, not effect layers: each player can drive many drawings.
struct AnalysisPlayerTracksSheet: View {
    let players: [AnalysisTrackingLibrary.Player]
    let clipStart: Double
    let clipEnd: Double
    var time: Double = 0
    let select: (AnalysisTrackingLibrary.Player) -> Void
    let add: () -> Void
    let rename: (UUID, String) -> Void
    var assignTeam: ((UUID, PlayerTrackingTeam) -> Void)? = nil
    var link: ((UUID, UUID) -> Void)? = nil
    var canLink: (UUID, UUID) -> Bool = { _, _ in false }
    var remove: ((UUID) -> Void)? = nil
    var canRemove: (UUID) -> Bool = { _ in false }
    var selectedID: UUID? = nil
    var choosingForLayer = false
    @State private var renaming: UUID?
    @State private var draftName = ""
    @State private var linking: AnalysisTrackingLibrary.Player?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Track new player", systemImage: "person.badge.plus") { dismiss(); add() }
                        .accessibilityIdentifier("analysis-track-new-player")
                } footer: {
                    Text("Select a saved player to open its four tracking actions. Assign a team or link confirmed sections from Player options.")
                }
                if !players.isEmpty {
                    Section {
                        LabeledContent("Tracked in this frame", value: "\(players.filter { !$0.motion.isMissing(at: time) && $0.motion.box(at: time) != nil }.count)")
                        LabeledContent("Saved tracks", value: "\(players.count)")
                    }
                }
                if players.isEmpty {
                    Section {
                        Text("Track players once, then assign Team A, Team B or Referee and reuse their motion across effects.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(PlayerTrackingTeam.allCases.filter { team in players.contains { $0.assignedTeam == team } }) { team in
                    let members = players.filter { $0.assignedTeam == team }
                    Section("\(team.title) · \(members.count) \(members.count == 1 ? "track" : "tracks")") {
                        ForEach(members) { player in playerRow(player) }
                    }
                }
                Section {
                    Text("Tracks are reused across effects. Choosing a saved player does not run tracking again. Players used by a drawing cannot be removed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(choosingForLayer ? "Follow player" : "Squad tracks").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Player name", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $draftName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") { if let renaming { rename(renaming, draftName) }; renaming = nil }
            }
        }
        .sheet(item: $linking) { source in
            NavigationStack {
                List {
                    Section {
                        Text("Choose the saved player who also appears in \(source.name). Linking combines their tracked sections and effects. Review the footage first; Undo restores both tracks.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Section {
                        if !players.contains(where: { canLink(source.id, $0.id) }) {
                            Text("No compatible tracks. Review team assignments or correct conflicting sections first.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(players.filter { canLink(source.id, $0.id) }) { target in
                            Button {
                                link?(source.id, target.id); linking = nil
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(target.name).font(.headline)
                                    Text("\(target.assignedTeam.title) · \(coverage(target.motion))").font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 44)
                            }
                        }
                    } header: {
                        Text("Link \(source.name) into")
                    } footer: {
                        Text("Tracks assigned to different teams or visible in different places at the same time cannot be linked.")
                    }
                }
                .navigationTitle("Link same player").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { linking = nil } } }
            }.preferredColorScheme(.dark).tint(Theme.signal)
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .preferredColorScheme(.dark).tint(Theme.signal)
    }

    private func playerRow(_ player: AnalysisTrackingLibrary.Player) -> some View {
        HStack(spacing: 4) {
            Button { select(player); dismiss() } label: {
                HStack(spacing: 10) {
                    swatch(player)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(player.name).font(.subheadline.bold())
                            if let number = player.number {
                                Text("#\(number)").font(.caption.bold().monospacedDigit())
                                    .accessibilityIdentifier("analysis-player-number-\(player.id)")
                            }
                        }
                        Text(coverage(player.motion)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 44).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("analysis-use-player-\(player.id)")
            if !choosingForLayer {
                if let assignTeam {
                    Menu {
                        Picker("Team", selection: Binding(get: { player.assignedTeam }, set: { assignTeam(player.id, $0) })) {
                            ForEach(PlayerTrackingTeam.allCases) { team in Text(team.title).tag(team) }
                        }
                    } label: {
                        Image(systemName: "person.2.badge.gearshape").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Assign team for \(player.name)")
                    .accessibilityValue(player.assignedTeam.title)
                    .accessibilityIdentifier("analysis-player-team-\(player.id)")
                }
                Menu {
                    if link != nil {
                        Button("Link same player…", systemImage: "link") { linking = player }
                            .disabled(players.count < 2)
                            .accessibilityIdentifier("analysis-link-player-\(player.id)")
                    }
                    Button("Rename", systemImage: "pencil") { renaming = player.id; draftName = player.name }
                    if let remove, canRemove(player.id) {
                        Button("Remove track", systemImage: "trash", role: .destructive) { remove(player.id) }
                            .accessibilityIdentifier("analysis-remove-player-\(player.id)")
                    }
                } label: { Label("Player options", systemImage: "ellipsis").frame(width: 44, height: 44) }
                    .labelStyle(.iconOnly)
            }
        }
    }

    @ViewBuilder private func swatch(_ player: AnalysisTrackingLibrary.Player) -> some View {
        ZStack {
            Circle().fill(player.kitColor.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Color.white.opacity(0.12))
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            if selectedID == player.id {
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white).shadow(radius: 1)
            } else if player.kitColor == nil {
                Image(systemName: "person.crop.circle").font(.body).foregroundStyle(.secondary)
            }
        }
    }

    private func coverage(_ motion: PlayerMotion) -> String {
        let start = timelineTimecode((motion.samples.first?.time ?? clipStart) - clipStart, includesTenths: true)
        let end = timelineTimecode((motion.samples.last?.time ?? clipStart) - clipStart, includesTenths: true)
        let missing = motion.missingIntervals(in: clipStart...clipEnd).count
        var status = "\(start) – \(end)"
        if motion.lostAt != nil { status += " · Needs correction" }
        else if missing > 0 { status += " · \(missing) \(missing == 1 ? "gap" : "gaps")" }
        return status
    }
}
