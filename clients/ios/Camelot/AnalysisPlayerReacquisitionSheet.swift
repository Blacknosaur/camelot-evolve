import SwiftUI

/// "Which one is he?" — the step automatic re-identification cannot do.
///
/// When a tracked player comes back after leaving the picture, the system can
/// narrow the field but not settle it: a team in one kit looks alike to every
/// cue available, and the shirt number is unreadable at this resolution. The
/// person watching knows immediately. This shows the plausible bodies as crops
/// and takes one tap.
struct AnalysisPlayerReacquisitionSheet: View {
    let playerName: String
    let searchedFrom: Double
    let clipStart: Double
    let isSearching: Bool
    let progress: Double
    let candidates: [PlayerReacquisitionCandidate]
    /// Confirm this body as the player, and carry on tracking from its frame.
    let confirm: (PlayerReacquisitionCandidate) -> Void
    /// Look at a candidate's frame without committing to it.
    let preview: (PlayerReacquisitionCandidate) -> Void
    let cancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            Group {
                if isSearching && candidates.isEmpty {
                    searching
                } else if candidates.isEmpty {
                    empty
                } else {
                    grid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ink)
            .navigationTitle("Find \(playerName)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel(); dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent).presentationDragIndicator(.visible)
        .preferredColorScheme(.dark).tint(Theme.signal)
    }

    private var searching: some View {
        VStack(spacing: 14) {
            ProgressView(value: progress)
                .progressViewStyle(.linear).frame(maxWidth: 240)
            Text("Looking for \(playerName) after \(timelineTimecode(searchedFrom - clipStart, includesTenths: true))")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.fill.questionmark").font(.largeTitle).foregroundStyle(.secondary)
            Text("No likely matches").font(.headline)
            Text("Nobody after \(timelineTimecode(searchedFrom - clipStart, includesTenths: true)) looks enough like \(playerName). "
                 + "Scrub to a frame where you can see this player and use Fix from this frame.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
        }.padding()
    }

    private var grid: some View {
        ScrollView {
            Text("Tap the one that is \(playerName). Tracking continues from that frame.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.top, 10)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(candidates) { candidate in
                    VStack(spacing: 6) {
                        Button { confirm(candidate); dismiss() } label: {
                            VStack(spacing: 4) {
                                Image(uiImage: candidate.thumbnail)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(height: 132)
                                    .frame(maxWidth: .infinity)
                                    .background(.black.opacity(0.3), in: .rect(cornerRadius: 8))
                                Text(timelineTimecode(candidate.time - clipStart, includesTenths: true))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("analysis-reacquire-candidate")
                        .accessibilityLabel("Confirm \(playerName) at \(timelineTimecode(candidate.time - clipStart, includesTenths: true))")
                        Button("Show frame", systemImage: "eye") { preview(candidate); detent = .medium }
                            .font(.caption).frame(minHeight: 44)
                            .accessibilityIdentifier("analysis-reacquire-preview")
                    }
                }
            }.padding(.horizontal, 14).padding(.bottom, 16)
            if isSearching {
                ProgressView(value: progress).progressViewStyle(.linear)
                    .frame(maxWidth: 200).padding(.bottom, 16)
            }
        }
    }
}
