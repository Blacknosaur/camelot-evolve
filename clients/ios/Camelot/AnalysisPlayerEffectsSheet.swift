import SwiftUI

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AnalysisSheetHeader(title: name, cancel: { dismiss() }, actionTitle: existing.isEmpty ? "Add" : "Apply",
                                    actionID: "analysis-apply-player-effects", disabled: existing.isEmpty && options.tools.isEmpty) {
                    apply(options); dismiss()
                }
            Form {
                Section {
                    Toggle("Ring", systemImage: "circle", isOn: $options.ring)
                        .disabled(locked(.player)).accessibilityIdentifier("analysis-player-ring")
                    if options.ring {
                        Picker("Ring style", selection: $options.ringStyle) {
                            ForEach(AnnotationEffect.playerStyles) { Text($0.title).tag($0) }
                        }.disabled(locked(.player))
                    }
                    Toggle("Spotlight", systemImage: "light.beacon.max", isOn: $options.spotlight)
                        .disabled(locked(.spotlight)).accessibilityIdentifier("analysis-player-spotlight")
                    if options.spotlight {
                        Picker("Spotlight style", selection: $options.spotlightStyle) {
                            Text("Sky beam").tag(AnnotationEffect.neon)
                            Text("Pulse").tag(AnnotationEffect.pulse)
                            Text("Dim background").tag(AnnotationEffect.clean)
                        }.disabled(locked(.spotlight))
                    }
                    Toggle("Loupe", systemImage: "magnifyingglass.circle", isOn: $options.loupe)
                        .disabled(locked(.loupe)).accessibilityIdentifier("analysis-player-loupe")
                    if options.loupe {
                        AnalysisLoupeControls(style: $options.loupeStyle).disabled(locked(.loupe))
                    }
                    Toggle("Name label", systemImage: "textformat", isOn: $options.label)
                        .disabled(locked(.text)).accessibilityIdentifier("analysis-player-label")
                    if options.label {
                        TextField("Player name or number", text: $options.text)
                            .disabled(locked(.text)).accessibilityIdentifier("analysis-player-label-text")
                        if allowsTrajectory {
                            Toggle("Show speed · km/h", isOn: $options.showsSpeed).disabled(locked(.text))
                                .accessibilityIdentifier("analysis-player-speed")
                            if options.showsSpeed {
                                Text(measurementStatus ?? "Set a reference in Measurements to show speed. Until calibrated, the label shows —.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Player effects") } footer: {
                    Text("Combine any options. They share one player track, with separate layers for timing and placement.")
                }
                if options.label {
                    Section("Text formatting") {
                        AnalysisTextControls(style: $options.textStyle).disabled(locked(.text))
                    }
                }
                if allowsTrajectory || options.trajectory {
                    Section("Movement trail") {
                        Toggle("Trajectory", systemImage: "point.topleft.down.to.point.bottomright.curvepath", isOn: $options.trajectory)
                            .disabled(locked(.trajectory)).accessibilityIdentifier("analysis-player-trajectory")
                        if options.trajectory { AnalysisTrajectoryControls(style: $options.trajectoryStyle).disabled(locked(.trajectory)) }
                    }
                }
                Section("Appearance") {
                    ColorPicker("Color", selection: Binding(get: { Color(red: options.color.red, green: options.color.green, blue: options.color.blue) }, set: { value in
                        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                        UIColor(value).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                        options.color = .init(red: red, green: green, blue: blue)
                    }), supportsOpacity: false)
                    Text("Locked layers are unchanged. Use each layer's Drawing style controls for finer adjustments.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            }.toolbar(.hidden, for: .navigationBar)
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
            .preferredColorScheme(.dark).tint(Theme.signal)
    }

    private func locked(_ tool: AnalysisDrawingTool) -> Bool { existing.contains { $0.tool == tool && $0.isLocked == true } }
}
