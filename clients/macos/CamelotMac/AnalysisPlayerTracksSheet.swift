import SwiftUI

/// Source tracks, not effect layers: each player can drive many drawings.
struct AnalysisPlayerTracksSheet: View {
    let players: [AnalysisTrackingLibrary.Player]
    let clipStart: Double
    let select: (AnalysisTrackingLibrary.Player) -> Void
    let add: () -> Void
    let correct: (UUID) -> Void
    let rename: (UUID, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Track new player", systemImage: "person.badge.plus") { dismiss(); add() }
                        .accessibilityIdentifier("analysis-track-new-player")
                } footer: {
                    Text("Select a player at a clear frame. Each player is tracked and saved independently. Corrections repair only that section, keeping saved tracking before and after it.")
                }
                Section("Saved players · \(players.count)") {
                    if players.isEmpty {
                        Text("Track players once, then reuse their motion for rings, spotlights, labels and connections.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(players) { player in
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Player name", text: Binding(get: { player.name }, set: { rename(player.id, $0) }))
                                .font(.headline).accessibilityIdentifier("analysis-player-name-\(player.id)")
                            Text(coverage(player.motion)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            HStack {
                                Button("Use track", systemImage: "plus.circle") { dismiss(); select(player) }
                                    .accessibilityIdentifier("analysis-use-player-\(player.id)")
                                Spacer()
                                Button("Correct", systemImage: "scope") { dismiss(); correct(player.id) }
                                    .accessibilityIdentifier("analysis-correct-player-\(player.id)")
                            }.buttonStyle(AnalysisControlStyle())
                        }.padding(.vertical, 4)
                    }
                }
                Section {
                    Text("If a player leaves the view, their effects stay hidden. Scrub to their return, choose Correct and select the same player. A repair stops when it rejoins the saved track or reaches your next correction. Later tracking is kept even if the repair fails. Only that player's effects are updated.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Player tracks")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .frame(minWidth: 460, minHeight: 560)
        .formStyle(.grouped)
        .preferredColorScheme(.dark).tint(Theme.signal)
    }

    private func coverage(_ motion: PlayerMotion) -> String {
        let start = timelineTimecode((motion.samples.first?.time ?? clipStart) - clipStart, includesTenths: true)
        let end = timelineTimecode((motion.samples.last?.time ?? clipStart) - clipStart, includesTenths: true)
        return "\(start) – \(end)" + (motion.lostAt == nil ? "" : " · Needs correction")
    }
}
