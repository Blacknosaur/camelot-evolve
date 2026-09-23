import SwiftUI

/// Lens pills like Camera.app with a precision ruler behind them. The row is one gesture surface:
/// tap a pill to ramp to that lens, hold or drag anywhere on the row to open the ruler and slide.
struct CameraZoomControl: View {
    let value: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    var lensFactors: [CGFloat] = []
    /// `smooth` asks the recorder to ramp instead of jumping.
    let change: (CGFloat, _ smooth: Bool) -> Void

    @State private var expanded = false
    @State private var dragStart: CGFloat?
    @State private var holdTask: Task<Void, Never>?
    @State private var lastHapticStop: CGFloat?
    @State private var suppressTapsUntil = Date.distantPast
    @State private var interaction = 0

    private var scale: CameraZoomScale { CameraZoomScale(minimum: minimum, maximum: maximum, lensFactors: lensFactors) }
    private var pills: [CGFloat] { CameraZoomStops.pills(lensFactors: lensFactors, minimum: minimum, maximum: maximum) }
    private var selectedPill: CGFloat? { CameraZoomStops.selectedPill(for: value, in: pills) }
    private var ruler: CameraZoomRuler { CameraZoomRuler(scale: scale) }

    var body: some View {
        ZStack {
            if expanded {
                CameraZoomRulerView(value: value, ruler: ruler)
                    .frame(height: 64)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .modifier(ZoomAccessibility(value: value, expanded: true, adjust: adjust, toggle: toggleExpanded))
            } else {
                pillRow.transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(maxWidth: 360)
        .frame(height: expanded ? 64 : 44)
        .contentShape(.rect)
        .simultaneousGesture(rowGesture)
        .animation(.snappy(duration: 0.22), value: expanded)
        .task(id: interaction) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, dragStart == nil else { return }
            expanded = false
        }
        .onDisappear { holdTask?.cancel() }
    }

    private var pillRow: some View {
        HStack(spacing: 6) {
            ForEach(pills, id: \.self) { stop in
                let isSelected = stop == selectedPill
                Button {
                    guard Date.now >= suppressTapsUntil else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    change(stop, true)
                    interaction += 1
                } label: {
                    Text(CameraZoomStops.label(for: stop, value: value, isSelected: isSelected))
                        .font(.system(size: isSelected ? 13 : 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Theme.signal : .white)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(minWidth: isSelected ? 44 : 30, minHeight: isSelected ? 34 : 30)
                        .padding(.horizontal, isSelected ? 8 : 4)
                        .background(.black.opacity(isSelected ? 0.55 : 0.25), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "Camera zoom" : "Zoom to \(CameraZoomStops.format(stop, decimals: stop == stop.rounded() ? 0 : 1)) times")
                .accessibilityIdentifier(isSelected ? "camera-zoom-dial" : "camera-zoom-\(CameraZoomStops.format(stop, decimals: stop == stop.rounded() ? 0 : 1))x")
                .modifier(ZoomAccessibility(value: value, expanded: false, isEnabled: isSelected, adjust: adjust, toggle: toggleExpanded))
            }
        }
        .padding(4)
        .background(.black.opacity(0.32), in: .capsule)
        .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5))
    }

    /// One drag recogniser handles hold-to-open, drag-to-open and ruler sliding. Quick taps fall
    /// through to the pill buttons; once the ruler opens, the release is not treated as a tap.
    private var rowGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { gesture in
                if dragStart == nil {
                    dragStart = value; lastHapticStop = nil
                    holdTask?.cancel()
                    if !expanded {
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(320))
                            guard !Task.isCancelled, dragStart != nil, !expanded else { return }
                            open()
                        }
                    }
                }
                let moved = abs(gesture.translation.width) > 12
                if !expanded, moved { open() }
                guard expanded, let start = dragStart else { return }
                let target = ruler.value(from: start, translation: gesture.translation.width)
                if let stop = CameraZoomRuler.crossedStop(from: value, to: target, stops: scale.hapticStops), stop != lastHapticStop {
                    UISelectionFeedbackGenerator().selectionChanged(); lastHapticStop = stop
                }
                change(target, false)
            }
            .onEnded { _ in
                holdTask?.cancel(); holdTask = nil
                if expanded {
                    suppressTapsUntil = .now.addingTimeInterval(0.4)
                    change(CameraZoomRuler.snapped(value, to: scale.hapticStops), false)
                }
                dragStart = nil
                interaction += 1
            }
    }

    private func open() {
        guard !expanded else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        suppressTapsUntil = .now.addingTimeInterval(0.6)
        expanded = true
        interaction += 1
    }

    private func toggleExpanded() {
        expanded.toggle(); interaction += 1
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        let factor: CGFloat = direction == .increment ? 1.1 : 1 / 1.1
        change(scale.clamped(value * factor), true)
        interaction += 1
    }
}

/// Shared VoiceOver contract for the collapsed selected pill and the open ruler.
private struct ZoomAccessibility: ViewModifier {
    let value: CGFloat
    let expanded: Bool
    var isEnabled = true
    let adjust: (AccessibilityAdjustmentDirection) -> Void
    let toggle: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if !isEnabled { content } else {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Camera zoom")
            .accessibilityValue("\(CameraZoomStops.format(value, decimals: 1)) times\(expanded ? ", dial open" : "")")
            .accessibilityHint(expanded ? "Drag left to zoom in, right to zoom out." : "Tap to snap to this lens, hold or drag to open the dial.")
            .accessibilityIdentifier("camera-zoom-dial")
            .accessibilityAdjustableAction(adjust)
            .accessibilityAction(named: expanded ? "Close dial" : "Open dial", toggle)
        }
    }
}

/// Ticks slide under a fixed centre indicator; labelled stops read as the lenses.
struct CameraZoomRulerView: View {
    let value: CGFloat
    let ruler: CameraZoomRuler

    var body: some View {
        Canvas { context, size in
            let centerX = size.width / 2, baseline = size.height - 18
            for tick in ruler.ticks(around: value, width: size.width - 24) {
                let x = centerX + tick.offset
                let fade = max(0.15, 1 - pow(abs(tick.offset) / (size.width / 2), 2))
                var path = Path()
                path.move(to: CGPoint(x: x, y: baseline))
                path.addLine(to: CGPoint(x: x, y: baseline - (tick.isStop ? 16 : 8)))
                context.stroke(path, with: .color(.white.opacity(tick.isStop ? fade : fade * 0.5)), lineWidth: tick.isStop ? 2 : 1)
                if tick.isStop {
                    context.draw(Text("\(CameraZoomStops.format(tick.zoom, decimals: tick.zoom == tick.zoom.rounded() ? 0 : 1))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(fade)),
                        at: CGPoint(x: x, y: baseline + 9))
                }
            }
            var pointer = Path()
            pointer.move(to: CGPoint(x: centerX, y: baseline - 24)); pointer.addLine(to: CGPoint(x: centerX, y: baseline + 2))
            context.stroke(pointer, with: .color(Theme.signal), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            context.draw(Text("\(CameraZoomStops.format(value, decimals: 1))×")
                .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.signal),
                at: CGPoint(x: centerX, y: 10))
        }
        .padding(.horizontal, 8)
        .background(.black.opacity(0.45), in: .rect(cornerRadius: Theme.Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).stroke(.white.opacity(0.08), lineWidth: 0.5))
    }
}
