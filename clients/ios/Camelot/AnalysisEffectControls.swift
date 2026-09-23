import SwiftUI

struct AnalysisLineControls: View {
    let mark: AnalysisAnnotation
    let style: (AnnotationLineStyle) -> Void
    let beginEdit: () -> Void

    private var current: AnnotationLineStyle {
        mark.lineStyle ?? {
            if mark.tool == .arrow { return .legacyArrow }
            if mark.tool == .connection { return AnnotationLineStyle(pattern: .solid, start: .circle, end: .circle) }
            return .default
        }()
    }
    private var supportsEndpoints: Bool { [.line, .arrow, .pen, .connection].contains(mark.tool) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Pattern", selection: Binding(get: { current.pattern }, set: { update(pattern: $0) })) {
                ForEach(AnnotationLinePattern.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("analysis-line-pattern")
            if supportsEndpoints {
                Picker("Start", selection: Binding(get: { current.start }, set: { update(start: $0) })) {
                    ForEach(AnnotationEndpoint.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("analysis-line-start")
                Picker("End", selection: Binding(get: { current.end }, set: { update(end: $0) })) {
                    ForEach(AnnotationEndpoint.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("analysis-line-end")
            }
        }.disabled(mark.isLocked == true)
    }

    private func update(pattern: AnnotationLinePattern? = nil, start: AnnotationEndpoint? = nil, end: AnnotationEndpoint? = nil) {
        beginEdit()
        var value = current
        if let pattern { value.pattern = pattern }
        if let start { value.start = start }
        if let end { value.end = end }
        style(value)
    }
}

struct AnalysisEffectControls: View {
    let mark: AnalysisAnnotation
    let effect: (AnnotationEffect) -> Void
    let fill: (Double) -> Void
    var wallHeight: (Double) -> Void = { _ in }
    var wallOpacity: (Double) -> Void = { _ in }
    var hasGround = false
    var groundAvailable = false
    var grounding: (Bool) -> Void = { _ in }
    var metricHeight: (Double) -> Void = { _ in }
    let beginEdit: () -> Void
    private var effects: [AnnotationEffect] {
        if mark.tool == .player { return AnnotationEffect.playerStyles }
        if [.zone, .rectangle, .connection, .line].contains(mark.tool), mark.fieldLines != true {
            return [.zone, .rectangle].contains(mark.tool) ? [.clean, .neon, .pulse, .wall, .aerial] : [.clean, .neon, .pulse, .wall]
        }
        return [.clean, .neon, .pulse]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Effect", selection: Binding(get: { mark.effect ?? .clean }, set: { effect($0) })) {
                ForEach(effects) { value in Text(value.title).tag(value) }
            }.pickerStyle(.segmented).accessibilityIdentifier("analysis-effect-style")
            if mark.supportsGrounding {
                Toggle("Lay flat on the pitch", isOn: Binding(get: { mark.isGrounded(hasField: hasGround) }, set: grounding))
                    .disabled(!hasGround && !mark.isGrounded(hasField: false)).accessibilityIdentifier("analysis-ground-effect")
                if !hasGround {
                    Text("Line up the pitch first (Pitch in the bottom bar).").font(.caption).foregroundStyle(.secondary)
                } else if mark.isGrounded(hasField: hasGround) {
                    Text(groundAvailable ? "Drawn in the pitch's perspective and kept in place as the camera moves." : "The pitch isn't lined up at this moment, so this stays hidden here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if mark.effect == .wall || mark.effect == .aerial {
                Text(mark.effect == .aerial ? "Raise the tactical roof above the ground area." : "Project a light wall above the boundary.").font(.caption).foregroundStyle(.secondary)
                if mark.isGrounded(hasField: hasGround) {
                    Text("Height · \((mark.wallHeightMeters ?? 2).formatted(.number.precision(.fractionLength(1)))) m")
                    Slider(value: Binding(get: { mark.wallHeightMeters ?? 2 }, set: metricHeight), in: 0.2...8,
                           onEditingChanged: { if $0 { beginEdit() } }).accessibilityIdentifier("analysis-wall-height-meters")
                } else {
                    Text(mark.effect == .aerial ? "Height" : "Wall height")
                    Slider(value: Binding(get: { mark.wallHeight ?? 0.18 }, set: wallHeight), in: 0.03...0.45,
                           onEditingChanged: { if $0 { beginEdit() } }).accessibilityIdentifier("analysis-wall-height")
                }
                Text("Light intensity")
                Slider(value: Binding(get: { mark.wallOpacity ?? 0.32 }, set: wallOpacity), in: 0.05...0.7,
                       onEditingChanged: { if $0 { beginEdit() } }).accessibilityIdentifier("analysis-wall-intensity")
            }
            if mark.tool == .zone && mark.fieldLines != true {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Area fill")
                    Slider(value: Binding(get: { mark.areaFill ?? 0.18 }, set: { fill($0) }), in: 0.05...0.6,
                           onEditingChanged: { if $0 { beginEdit() } }).accessibilityLabel("Area fill")
                }
                Text("Drag a corner on the video to reshape the area.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.disabled(mark.isLocked == true)
    }
}

struct AnalysisZoomControls: View {
    let mark: AnalysisAnnotation
    let amount: (Double) -> Void
    let ramp: (Double) -> Void
    let beginEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zoom \((mark.zoomScale ?? 2).formatted(.number.precision(.fractionLength(1))))×")
            Slider(value: Binding(get: { mark.zoomScale ?? 2 }, set: { amount($0) }), in: 1...4,
                   onEditingChanged: { if $0 { beginEdit() } }).accessibilityIdentifier("analysis-zoom-amount")
            Text("Smooth in and out: \((mark.zoomRamp ?? 0.35).formatted(.number.precision(.fractionLength(2)))) s")
            Slider(value: Binding(get: { mark.zoomRamp ?? 0.35 }, set: { ramp($0) }), in: 0...1.5,
                   onEditingChanged: { if $0 { beginEdit() } }).accessibilityLabel("Zoom ease in and out")
            Text("Drag on the video to move the zoom. Trim its bar on the timeline to set how long it lasts.")
                .font(.footnote).foregroundStyle(.secondary)
        }.disabled(mark.isLocked == true)
    }
}

/// How long an effect keeps following a player whose tracking is missing.
/// Positions come from the confirmed neighbours (camera-aware with a clip
/// camera track); raw gaps stay marked on the timeline either way.
struct AnalysisTrackingBridgeControls: View {
    let mark: AnalysisAnnotation
    let amount: (Double) -> Void
    let beginEdit: () -> Void

    private var current: Double {
        (mark.playerMotion ?? mark.linkedPlayers?.first)?.bridgeHorizon ?? 0.4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Estimate missing positions")
                Spacer()
                Text(current < 0.05 ? "Off" : String(format: "%.1f s", current)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { current }, set: { amount(($0 * 10).rounded() / 10) }), in: 0...PlayerMotion.maximumBridgeHorizon,
                   onEditingChanged: { if $0 { beginEdit() } }).accessibilityIdentifier("analysis-tracking-bridge")
            Text("Off hides uncertain tracking. Increasing this draws estimated positions, which can cross other players. Use frame review to confirm positions by hand.")
                .font(.footnote).foregroundStyle(.secondary)
        }.disabled(mark.isLocked == true)
    }
}

struct AnalysisTrackingSmoothingControls: View {
    let mark: AnalysisAnnotation
    let amount: (Double) -> Void
    let beginEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tracking smoothing")
            Slider(value: Binding(get: { mark.displayPlayerMotion?.smoothing ?? mark.linkedPlayers?.first?.smoothing ?? 0.65 }, set: { amount($0) }), in: 0...1,
                   onEditingChanged: { if $0 { beginEdit() } }).accessibilityIdentifier("analysis-tracking-smoothing")
            HStack { Text("Raw"); Spacer(); Text("Smooth") }.font(.footnote).foregroundStyle(.secondary)
        }.disabled(mark.isLocked == true)
    }
}
