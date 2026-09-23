import SwiftUI

/// The small set of actions for following one player. Repair and review are
/// deliberately expressed as tracking directions so the normal path is easy
/// to understand: Track, forward, backward, or fill a missing interval.
struct AnalysisPlayerTrackingSheet: View {
    let player: AnalysisTrackingLibrary.Player
    let clipRange: ClosedRange<Double>
    let time: Double
    let isBusy: Bool
    /// The drawing that follows this player, when one is selected.
    var layer: AnalysisAnnotation? = nil
    /// Optional body outlines for effects, using the same identity tracker.
    @Binding var includeBodyMasks: Bool
    let trackWholeClip: () -> Void
    let trackToEnd: () -> Void
    let trackBackToStart: () -> Void
    let fillGap: () -> Void
    var addReference: (PlayerIdentityView) -> Void = { _ in }
    var setNumber: (String) -> Void = { _ in }
    let seek: (Double) -> Void
    let bridge: (Double) -> Void
    let smoothing: (Double) -> Void
    let rename: (String) -> Void
    var remove: (() -> Void)? = nil
    @State private var draftName = ""
    @State private var renaming = false
    @State private var editingNumber = false
    @State private var draftNumber = ""
    @Environment(\.dismiss) private var dismiss

    private var motion: PlayerMotion { player.motion }
    private var missing: [ClosedRange<Double>] { motion.missingIntervals(in: clipRange) }
    private var coversClip: Bool { missing.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    coverage
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Track", systemImage: "arrow.left.and.right.circle.fill") { dismiss(); trackWholeClip() }
                        .fontWeight(.semibold).accessibilityIdentifier("analysis-track-player")
                    Button("Track forward", systemImage: "arrow.right.to.line.circle") { dismiss(); trackToEnd() }
                        .disabled(time >= clipRange.upperBound - 0.1)
                        .accessibilityIdentifier("analysis-track-player-forward")
                    Button("Track backward", systemImage: "arrow.left.to.line.circle") { dismiss(); trackBackToStart() }
                        .disabled(time <= clipRange.lowerBound + 0.1)
                        .accessibilityIdentifier("analysis-track-player-backward")
                    Button("Fill gap", systemImage: "wand.and.stars") { dismiss(); fillGap() }
                        .disabled(coversClip).accessibilityIdentifier("analysis-fill-player-gap")
                } header: { Text("Tracking") } footer: {
                    Text("Track replaces the selected range and stops cleanly when you stop it. Fill gap only adds missing frames; existing tracked frames are kept.")
                }
                Section {
                    DisclosureGroup("Player identity (optional)") {
                        ForEach(PlayerIdentityView.allCases.filter { $0 != .unspecified }) { view in
                            let reference = player.identity?.confirmedViews?.last { $0.view == view }
                            Button { dismiss(); addReference(view) } label: {
                                HStack {
                                    Label(view.title, systemImage: reference == nil ? "person.crop.rectangle.badge.plus" : "checkmark.circle.fill")
                                    Spacer()
                                    Text(reference.map { timelineTimecode($0.observation.time - clipRange.lowerBound, includesTenths: true) } ?? "Add view")
                                        .foregroundStyle(.secondary).font(.caption.monospacedDigit())
                                }
                            }
                                .accessibilityIdentifier("analysis-identity-\(view.rawValue)")
                        }
                        Button { draftNumber = player.number ?? ""; editingNumber = true } label: {
                            HStack { Text("Jersey number"); Spacer(); Text(player.number.map { "#\($0)" } ?? "Set number").foregroundStyle(.secondary) }
                        }.accessibilityIdentifier("analysis-identity-number")
                    }
                } header: { Text("Player identity") } footer: {
                    Text("Clear appearances are learned automatically during tracking. These optional labels add a stronger front, back or side reference when you have one; small or hidden faces are ignored. A jersey number helps separate teammates.")
                }
                Section {
                    DisclosureGroup("Advanced player settings") {
                        Toggle("Generate body outline", isOn: $includeBodyMasks)
                            .accessibilityIdentifier("analysis-include-body-masks")
                        if let layer {
                            AnalysisTrackingBridgeControls(mark: layer, amount: bridge, beginEdit: {})
                            AnalysisTrackingSmoothingControls(mark: layer, amount: smoothing, beginEdit: {})
                        }
                        if let remove {
                            Button("Remove player track", systemImage: "trash", role: .destructive) { dismiss(); remove() }
                                .accessibilityIdentifier("analysis-remove-selected-player")
                        }
                    }
                    Button("Rename player", systemImage: "pencil") { draftName = player.name; renaming = true }
                } header: { Text("More") }
            }
            .disabled(isBusy)
            .navigationTitle(player.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Jersey number", isPresented: $editingNumber) {
                TextField("1–99", text: $draftNumber).keyboardType(.numberPad)
                Button("Cancel", role: .cancel) {}
                Button("Save") { setNumber(draftNumber) }
                    .disabled(!draftNumber.isEmpty && !PlayerNumberVotes.isShirtNumber(draftNumber))
            } message: { Text("Enter the number you can read on this player's shirt. Clear it to remove the number.") }
            .alert("Player name", isPresented: $renaming) {
                TextField("Name", text: $draftName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { rename(draftName) }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .preferredColorScheme(.dark).tint(Theme.signal)
    }

    private var status: String {
        guard let first = motion.samples.first?.time, let last = motion.samples.last?.time else { return "Not tracked yet." }
        let span = "\(timelineTimecode(first - clipRange.lowerBound, includesTenths: true)) – \(timelineTimecode(min(last, motion.lostAt ?? last) - clipRange.lowerBound, includesTenths: true))"
        if coversClip { return "Tracked \(span), no gaps." }
        let count = missing.count
        return "Tracked \(span) · \(count) untracked \(count == 1 ? "section" : "sections") shown in orange."
    }

    /// Blue where the player is tracked, orange where it is not, with the
    /// current frame marked. Tap to jump.
    private var coverage: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, span = max(0.01, clipRange.upperBound - clipRange.lowerBound)
            let x: (Double) -> CGFloat = { seconds in CGFloat((min(clipRange.upperBound, max(clipRange.lowerBound, seconds)) - clipRange.lowerBound) / span) * width }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.cyan.opacity(0.8)).frame(height: 8)
                ForEach(Array(missing.enumerated()), id: \.offset) { _, gap in
                    Capsule().fill(Color.orange).frame(width: max(3, x(gap.upperBound) - x(gap.lowerBound)), height: 8).offset(x: x(gap.lowerBound))
                }
                Rectangle().fill(Theme.signal).frame(width: 2, height: 16).offset(x: x(time) - 1)
            }.frame(height: 16).contentShape(.rect)
                .onTapGesture { location in seek(clipRange.lowerBound + Double(location.x / width) * span) }
        }.frame(height: 16).padding(.vertical, 6)
            .accessibilityLabel("Tracking coverage").accessibilityValue(status)
    }
}

/// Compact controls stay visible while the player is selected directly on video.
struct AnalysisPlayerFrameReviewControls: View {
    let name: String
    let time: Double
    let canGoBack: Bool
    let canGoNext: Bool
    let canUndo: Bool
    let canTrack: Bool
    let isSeeking: Bool
    let previous: () -> Void
    let next: () -> Void
    let undo: () -> Void
    let track: () -> Void
    let done: () -> Void
    var redoTracking: () -> Void = {}

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text("Review \(name)").font(.caption.bold()).lineLimit(1)
                Spacer(minLength: 4)
                Text(time, format: .number.precision(.fractionLength(3)))
                    .font(.caption.monospacedDigit()).fixedSize()
                    .accessibilityIdentifier("analysis-review-frame-time")
                    .accessibilityValue(String(time))
                Menu {
                    Button("Continue from last selection", systemImage: "figure.run", action: track)
                        .disabled(!canTrack).accessibilityIdentifier("analysis-review-track-forward")
                    Button("Redo section or whole track…", systemImage: "arrow.clockwise", action: redoTracking)
                        .accessibilityIdentifier("analysis-review-redo-tracking")
                } label: { Label("Track", systemImage: "figure.run") }
                    .disabled(isSeeking).accessibilityIdentifier("analysis-review-tracking-menu")
                Button("Done", action: done).accessibilityIdentifier("analysis-review-done")
            }
            HStack(spacing: 8) {
                Button("Back", systemImage: "backward.frame", action: previous).disabled(!canGoBack)
                    .accessibilityIdentifier("analysis-review-previous-frame")
                Button("Undo", systemImage: "arrow.uturn.backward", action: undo).disabled(!canUndo)
                    .accessibilityIdentifier("analysis-review-undo")
                Spacer(minLength: 0)
                Button("Next", systemImage: "forward.frame", action: next).disabled(!canGoNext)
                    .accessibilityIdentifier("analysis-review-next-frame")
            }.disabled(isSeeking)
        }.buttonStyle(AnalysisControlStyle()).padding(.horizontal, 10).padding(.vertical, 4).background(Theme.inkPanel)
            .accessibilityElement(children: .contain).accessibilityIdentifier("analysis-frame-review")
    }
}

struct PlayerTrackingReplacementRequest: Identifiable {
    let id: UUID
    let name: String
    let time: Double
    var wholeClip = false
}

/// Explicit range ownership lets automatic tracking replace reviewed frames
/// without weakening the normal repair path's protection of manual picks.
struct AnalysisPlayerTrackingReplacementSheet: View {
    let request: PlayerTrackingReplacementRequest
    let clipRange: ClosedRange<Double>
    let frameRate: Double
    let replace: (ClosedRange<Double>, Double) -> Void
    @State private var wholeClip = false
    @State private var start: Double
    @State private var end: Double
    @Environment(\.dismiss) private var dismiss

    init(request: PlayerTrackingReplacementRequest, clipRange: ClosedRange<Double>, frameRate: Double,
         replace: @escaping (ClosedRange<Double>, Double) -> Void) {
        self.request = request; self.clipRange = clipRange; self.frameRate = frameRate; self.replace = replace
        _wholeClip = State(initialValue: request.wholeClip)
        _start = State(initialValue: min(clipRange.upperBound - 1 / max(1, frameRate), max(clipRange.lowerBound, request.time)))
        _end = State(initialValue: clipRange.upperBound)
    }

    private var range: ClosedRange<Double> { wholeClip ? clipRange : start...max(start, end) }
    private var seedTime: Double { min(range.upperBound - 1 / max(1, frameRate), max(range.lowerBound, request.time)) }
    private var valid: Bool { range.upperBound - range.lowerBound > 0.05 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Replace", selection: $wholeClip) {
                        Text("Section").tag(false)
                        Text("Whole clip").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("analysis-redo-scope")
                    if !wholeClip {
                        timeControl("Start", value: $start, identifier: "analysis-redo-start")
                        timeControl("End", value: $end, identifier: "analysis-redo-end")
                    }
                    Text("\(timelineTimecode(range.lowerBound - clipRange.lowerBound, includesTenths: true)) – \(timelineTimecode(range.upperBound - clipRange.lowerBound, includesTenths: true))")
                        .font(.headline.monospacedDigit())
                } footer: {
                    Text("Replaces automatic tracking and manual picks inside this range. Tracking outside the range and this player's identity references are kept. Stop leaves unfinished frames untracked. Undo restores the previous track.")
                }
                Section {
                    Button("Select player and redo", systemImage: "scope") {
                        dismiss(); replace(range, seedTime)
                    }.fontWeight(.semibold).disabled(!valid)
                        .accessibilityIdentifier("analysis-redo-confirm")
                } footer: {
                    Text("Select the player at \(timelineTimecode(seedTime - clipRange.lowerBound, includesTenths: true)). Tracking runs from that frame in both directions within your range.")
                }
            }
            .navigationTitle("Redo \(request.name)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
            .preferredColorScheme(.dark).tint(Theme.signal)
    }

    private func timeControl(_ title: String, value: Binding<Double>, identifier: String) -> some View {
        VStack(alignment: .leading) {
            Stepper(value: value, in: clipRange, step: 1 / max(1, frameRate)) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(value.wrappedValue - clipRange.lowerBound, format: .number.precision(.fractionLength(3)))
                        .monospacedDigit()
                }
            }
            Slider(value: value, in: clipRange, step: 1 / max(1, frameRate))
                .accessibilityLabel(title).accessibilityIdentifier(identifier)
        }
    }
}
