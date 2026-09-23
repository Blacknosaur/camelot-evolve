import SwiftUI

/// "How should this player stand out?" Big toggles for each highlight, one
/// colour row, and the few choices that matter. Fine-tuning stays out of the
/// way until an effect is on.
struct AnalysisPlayerEffectsSheet: View {
    let name: String
    let existing: [AnalysisAnnotation]
    var allowsTrajectory: Bool = true
    var measurementStatus: String?
    let apply: (AnalysisPlayerEffects) -> Void
    @State private var options: AnalysisPlayerEffects
    @Environment(\.dismiss) private var dismiss

    init(name: String, existing: [AnalysisAnnotation], allowsTrajectory: Bool = true, measurementStatus: String? = nil, apply: @escaping (AnalysisPlayerEffects) -> Void) {
        self.name = name; self.existing = existing; self.apply = apply
        self.allowsTrajectory = allowsTrajectory
        self.measurementStatus = measurementStatus
        _options = State(initialValue: AnalysisPlayerEffects(layers: existing, name: name))
    }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        tile("Ring", symbol: "circle.dashed", isOn: $options.ring, tool: .player, id: "analysis-player-ring")
                        tile("Spotlight", symbol: "light.beacon.max", isOn: $options.spotlight, tool: .spotlight, id: "analysis-player-spotlight")
                        tile("Name", symbol: "textformat", isOn: $options.label, tool: .text, id: "analysis-player-label")
                        if allowsTrajectory || options.trajectory {
                            tile("Trail", symbol: "point.topleft.down.to.point.bottomright.curvepath", isOn: $options.trajectory, tool: .trajectory, id: "analysis-player-trajectory")
                        }
                        tile("Magnifier", symbol: "magnifyingglass.circle", isOn: $options.loupe, tool: .loupe, id: "analysis-player-loupe")
                    }

                    if options.ring {
                        section("Ring style") {
                            chips(AnnotationEffect.playerStyles.map { ($0.playerStyleTitle, $0) }, selection: $options.ringStyle)
                                .disabled(locked(.player))
                        }
                    }
                    if options.spotlight {
                        section("Spotlight style") {
                            chips([("Beam", .neon), ("Pulse", .pulse), ("Dim the rest", .clean)], selection: $options.spotlightStyle)
                                .disabled(locked(.spotlight))
                        }
                    }
                    if options.label {
                        section("Name") {
                            TextField("Name or number", text: $options.text)
                                .padding(.horizontal, 12).frame(minHeight: 44)
                                .background(.white.opacity(0.07), in: .rect(cornerRadius: Theme.Radius.small))
                                .disabled(locked(.text)).accessibilityIdentifier("analysis-player-label-text")
                            if allowsTrajectory {
                                Toggle("Show speed", isOn: $options.showsSpeed).disabled(locked(.text))
                                    .accessibilityIdentifier("analysis-player-speed")
                                if options.showsSpeed, measurementStatus == nil {
                                    Text("Speed appears once the pitch is lined up (Pitch in the bottom bar).")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    section("Colour") { AnalysisColorSwatches(color: $options.color) }

                    if options.label || options.trajectory || options.loupe {
                        section("Fine-tune") {
                            if options.label {
                                NavigationLink("Name style") {
                                    Form { AnalysisTextControls(style: $options.textStyle).disabled(locked(.text)) }.navigationTitle("Name style")
                                }
                            }
                            if options.trajectory {
                                NavigationLink("Trail") {
                                    Form { AnalysisTrajectoryControls(style: $options.trajectoryStyle).disabled(locked(.trajectory)) }.navigationTitle("Trail")
                                }
                            }
                            if options.loupe {
                                NavigationLink("Magnifier") {
                                    Form { AnalysisLoupeControls(style: $options.loupeStyle).disabled(locked(.loupe)) }.navigationTitle("Magnifier")
                                }
                            }
                        }.foregroundStyle(.white)
                    }
                }.padding(16)
            }
            .background(Theme.inkPanel)
            .navigationTitle(existing.isEmpty ? "Highlight \(name)" : name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing.isEmpty ? "Add" : "Done") { apply(options); dismiss() }.bold()
                        .disabled(existing.isEmpty && options.tools.isEmpty)
                        .accessibilityIdentifier("analysis-apply-player-effects")
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .preferredColorScheme(.dark).tint(Theme.signal)
    }

    private func tile(_ title: String, symbol: String, isOn: Binding<Bool>, tool: AnalysisDrawingTool, id: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 22, weight: .medium)).frame(height: 26)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .foregroundStyle(isOn.wrappedValue ? Theme.ink : .white)
            .background(isOn.wrappedValue ? Theme.signal : .white.opacity(0.07), in: .rect(cornerRadius: Theme.Radius.medium))
            .overlay(alignment: .topTrailing) {
                if isOn.wrappedValue { Image(systemName: "checkmark.circle.fill").padding(6).foregroundStyle(Theme.ink) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(TilePressStyle()).disabled(locked(tool))
        .accessibilityLabel(title).accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier(id)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func chips(_ items: [(String, AnnotationEffect)], selection: Binding<AnnotationEffect>) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.1) { title, value in
                Button(title) { selection.wrappedValue = value }
                    .buttonStyle(EditorActionStyle(prominent: selection.wrappedValue == value))
                    .accessibilityAddTraits(selection.wrappedValue == value ? .isSelected : [])
            }
        }
    }

    private func locked(_ tool: AnalysisDrawingTool) -> Bool { existing.contains { $0.tool == tool && $0.isLocked == true } }
}

extension AnnotationEffect {
    /// Names coaches recognise from broadcast graphics.
    var playerStyleTitle: String {
        switch self {
        case .clean: "Simple"
        case .neon: "Glow"
        case .pulse: "Pulse"
        case .radar: "Radar"
        default: title
        }
    }
}
