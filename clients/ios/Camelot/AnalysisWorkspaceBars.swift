import SwiftUI

// The Analyse workspace shows exactly one bottom bar: the task tiles, the
// palette of the task in progress, or the actions of what is selected. Every
// bar uses the same large, labelled targets so it reads at a glance.

/// The resting bar: what the coach can do with this clip.
struct AnalysisTaskBar: View {
    let hasPitch: Bool
    let allowsPlayers: Bool
    let player: () -> Void
    let draw: () -> Void
    let text: () -> Void
    let zoom: () -> Void
    let pitch: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TaskTileButton(title: "Player", symbol: "figure.run", identifier: "analysis-task-player", action: player)
                .disabled(!allowsPlayers)
            TaskTileButton(title: "Draw", symbol: "scribble.variable", identifier: "analysis-task-draw", action: draw)
            TaskTileButton(title: "Text", symbol: "textformat", identifier: "analysis-task-text", action: text)
            TaskTileButton(title: "Zoom", symbol: "plus.magnifyingglass", identifier: "analysis-task-zoom", action: zoom)
            TaskTileButton(title: "Pitch", symbol: hasPitch ? "sportscourt.fill" : "sportscourt", identifier: "analysis-task-pitch", action: pitch)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .accessibilityElement(children: .contain).accessibilityIdentifier("analysis-task-bar")
    }
}

/// Shapes the Draw task offers, in the order coaches reach for them.
extension AnalysisDrawingTool {
    static let drawShapes: [Self] = [.arrow, .line, .pen, .ellipse, .rectangle, .zone, .connection, .loupe]
}

struct AnalysisDrawPalette: View {
    let tool: AnalysisDrawingTool
    @Binding var color: AnnotationColor
    let choose: (AnalysisDrawingTool) -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(AnalysisDrawingTool.drawShapes) { shape in
                        Button { choose(shape) } label: {
                            VStack(spacing: 3) {
                                Image(systemName: shape.symbol).font(.system(size: 17, weight: .medium)).frame(height: 22)
                                Text(shape.title).font(.caption2.weight(.semibold)).lineLimit(1)
                            }
                            .frame(width: 64, height: 52)
                            .foregroundStyle(tool == shape ? Theme.ink : .white)
                            .background(tool == shape ? Theme.signal : .white.opacity(0.07), in: .rect(cornerRadius: Theme.Radius.small))
                            .contentShape(.rect)
                        }
                        .buttonStyle(TilePressStyle())
                        .accessibilityLabel(shape.title)
                        .accessibilityAddTraits(tool == shape ? .isSelected : [])
                        .accessibilityIdentifier("analysis-tool-\(shape.rawValue)")
                    }
                }.padding(.horizontal, 10)
            }.scrollIndicators(.hidden)
            HStack(spacing: 4) {
                AnalysisColorSwatches(color: $color)
                Spacer(minLength: 4)
                Button("Done", action: done)
                    .buttonStyle(EditorActionStyle(prominent: true))
                    .accessibilityIdentifier("analysis-draw-done")
            }.padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain).accessibilityIdentifier("analysis-drawing-tools")
    }
}

/// A short row of match-friendly colours. Precise colours stay one tap away
/// through the system picker at the end of the row.
struct AnalysisColorSwatches: View {
    @Binding var color: AnnotationColor
    var showsCustom = true

    static let presets: [(String, AnnotationColor)] = [
        ("Lime", .yellow),
        ("Yellow", .init(red: 1, green: 0.84, blue: 0.1)),
        ("Red", .init(red: 1, green: 0.27, blue: 0.23)),
        ("Blue", .init(red: 0.2, green: 0.65, blue: 1)),
        ("White", .init(red: 1, green: 1, blue: 1)),
        ("Orange", .init(red: 1, green: 0.55, blue: 0.1)),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.presets, id: \.0) { name, preset in
                let selected = Self.matches(preset, color)
                Button { color = preset } label: {
                    Circle().fill(Color(red: preset.red, green: preset.green, blue: preset.blue))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(.white.opacity(selected ? 1 : 0.25), lineWidth: selected ? 2.5 : 1).padding(selected ? -4 : 0))
                        .frame(width: 36, height: 44).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name).accessibilityAddTraits(selected ? .isSelected : [])
            }
            if showsCustom {
                ColorPicker("Custom colour", selection: Binding(get: {
                    Color(red: color.red, green: color.green, blue: color.blue)
                }, set: { value in
                    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                    UIColor(value).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                    color = .init(red: red, green: green, blue: blue)
                }), supportsOpacity: false)
                .labelsHidden().frame(width: 36, height: 44)
            }
        }
    }

    static func matches(_ a: AnnotationColor, _ b: AnnotationColor) -> Bool {
        abs(a.red - b.red) + abs(a.green - b.green) + abs(a.blue - b.blue) < 0.06
    }
}

/// A one-line instruction with a way out, used while the video is waiting for a tap.
struct AnalysisPromptBar<Accessory: View>: View {
    let title: String
    var message: String? = nil
    var cancelTitle = "Cancel"
    var identifier = "analysis-prompt"
    let cancel: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            accessory()
            Button(cancelTitle, action: cancel).buttonStyle(EditorActionStyle())
                .accessibilityIdentifier("\(identifier)-cancel")
        }
        .padding(.horizontal, 12).frame(minHeight: 60)
        .accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
    }
}

extension AnalysisPromptBar where Accessory == EmptyView {
    init(title: String, message: String? = nil, cancelTitle: String = "Cancel", identifier: String = "analysis-prompt", cancel: @escaping () -> Void) {
        self.init(title: title, message: message, cancelTitle: cancelTitle, identifier: identifier, cancel: cancel, accessory: { EmptyView() })
    }
}

/// Shown while a player is being followed. The video moves with the pass, so
/// this bar only needs to say who, how far, and how to stop.
struct AnalysisFollowingBar: View {
    let title: String
    let progress: Double
    let status: String
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "figure.run").symbolEffect(.pulse).foregroundStyle(Theme.signal)
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: progress).tint(Theme.signal)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("analysis-tracking-phase")
            }
            // Stop, not Cancel: everything followed so far is kept.
            Button("Stop", action: stop).buttonStyle(EditorActionStyle())
                .accessibilityIdentifier("analysis-stop-tracking")
        }
        .padding(.horizontal, 12).frame(minHeight: 72)
        .accessibilityElement(children: .contain).accessibilityIdentifier("analysis-tracking-status")
    }
}

/// Where the player is followed (lime) and lost (orange) across the clip.
/// Tapping jumps there, so checking a loss is one tap.
struct AnalysisTrackingStrip: View {
    let motion: PlayerMotion
    let range: ClosedRange<Double>
    let time: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, span = max(0.01, range.upperBound - range.lowerBound)
            let x: (Double) -> CGFloat = { CGFloat((min(range.upperBound, max(range.lowerBound, $0)) - range.lowerBound) / span) * width }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12)).frame(height: 8)
                if let first = motion.samples.first?.time, let last = motion.samples.last?.time {
                    Capsule().fill(Theme.signal.opacity(0.85))
                        .frame(width: max(3, x(last) - x(first)), height: 8).offset(x: x(first))
                }
                ForEach(Array(missing.enumerated()), id: \.offset) { _, gap in
                    Capsule().fill(Color.orange)
                        .frame(width: max(4, x(gap.upperBound) - x(gap.lowerBound)), height: 8).offset(x: x(gap.lowerBound))
                }
                RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 3, height: 18).offset(x: x(time) - 1.5)
            }
            .frame(height: 24).contentShape(.rect)
            .onTapGesture { location in seek(range.lowerBound + Double(location.x / max(1, width)) * span) }
        }
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Where the player is followed")
        .accessibilityValue(summary)
        .accessibilityIdentifier("analysis-tracking-strip")
    }

    private var missing: [ClosedRange<Double>] {
        motion.samples.isEmpty ? [] : Self.lostSections(motion, range: range)
    }

    var summary: String { Self.summary(motion, range: range) }

    /// Untracked parts of the clip: the lead-in, every gap and the tail.
    static func lostSections(_ motion: PlayerMotion, range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        motion.missingIntervals(in: range)
    }

    static func summary(_ motion: PlayerMotion, range: ClosedRange<Double>) -> String {
        guard !motion.samples.isEmpty else { return "Not followed yet" }
        let lost = lostSections(motion, range: range).count
        if lost == 0 { return "Followed through the whole clip" }
        return "Lost in \(lost) \(lost == 1 ? "place" : "places")"
    }
}

/// The selected player: who, their highlight, and whether following needs a hand.
struct AnalysisPlayerBar<More: View>: View {
    let player: AnalysisTrackingLibrary.Player
    let range: ClosedRange<Double>
    let time: Double
    let rename: () -> Void
    let effects: () -> Void
    let fix: () -> Void
    let seek: (Double) -> Void
    var allowsFix = true
    var close: () -> Void = {}
    @ViewBuilder var more: () -> More

    private var lost: Bool { !AnalysisTrackingStrip.lostSections(player.motion, range: range).isEmpty }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                DeselectButton(action: close)
                Button(action: rename) {
                    HStack(spacing: 8) {
                        AnalysisPlayerSwatch(player: player, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(player.number.map { "\(player.name) · #\($0)" } ?? player.name)
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(AnalysisTrackingStrip.summary(player.motion, range: range))
                                .font(.caption2).foregroundStyle(lost ? Color.orange : .secondary).lineLimit(1)
                        }
                    }.frame(minHeight: 44).contentShape(.rect)
                }
                .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHint("Rename this player")
                .accessibilityIdentifier("analysis-active-player-track")
                Button("Highlight", systemImage: "sparkles", action: effects)
                    .labelStyle(CompactLabelStyle())
                    .buttonStyle(EditorActionStyle()).accessibilityIdentifier("analysis-player-effects")
                if allowsFix {
                    Button("Fix", systemImage: "hand.tap", action: fix)
                        .labelStyle(CompactLabelStyle())
                        .buttonStyle(EditorActionStyle(prominent: lost)).accessibilityIdentifier("analysis-player-tracking")
                }
                more()
            }
            AnalysisTrackingStrip(motion: player.motion, range: range, time: time, seek: seek)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .contain).accessibilityIdentifier("analysis-player-bar")
    }
}

struct AnalysisPlayerSwatch: View {
    let player: AnalysisTrackingLibrary.Player
    var size: CGFloat = 16
    var body: some View {
        Circle().fill(player.kitColor.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Color.white.opacity(0.2))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
    }
}

/// The selected drawing: what it is plus a few plain actions.
struct AnalysisSelectionBar<Actions: View>: View {
    let title: String
    let symbol: String
    let close: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            DeselectButton(action: close)
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
            actions()
        }
        .padding(.horizontal, 12).frame(minHeight: 60)
        .accessibilityElement(children: .contain).accessibilityIdentifier("analysis-selection-bar")
    }
}
