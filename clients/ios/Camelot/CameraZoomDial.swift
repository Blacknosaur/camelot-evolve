import SwiftUI

/// Log spacing gives wide-angle and telephoto zoom the same precision per movement.
struct CameraZoomScale {
    let minimum: CGFloat
    let maximum: CGFloat
    func clamped(_ value: CGFloat) -> CGFloat { min(maximum, max(minimum, value)) }
    func dragging(from start: CGFloat, translation: CGFloat) -> CGFloat {
        clamped(start * exp(-translation / 180))
    }
    var stops: [CGFloat] { [0.5, 1, 2, 3, 4, 5, 6].filter { $0 >= minimum && $0 <= maximum } }
}

struct CameraZoomDial: View {
    let value: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    let change: (CGFloat, Bool) -> Void
    @State private var expanded = false
    @State private var dragStart: CGFloat?
    @State private var lastStop: CGFloat?
    @State private var interaction = 0
    private var scale: CameraZoomScale { CameraZoomScale(minimum: minimum, maximum: maximum) }

    var body: some View {
        ZStack(alignment: .bottom) {
            if expanded {
                dialFace
                    .frame(height: 100)
                    .background(.black.opacity(0.75), in: .rect(cornerRadius: 20))
                    .transition(.opacity)
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                interaction += 1
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 8, weight: .bold))
                    Text("\(Double(value).formatted(.number.precision(.fractionLength(1))))×")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(Theme.signal).frame(minWidth: 72, minHeight: 44)
                .background(.black.opacity(0.75), in: .capsule)
            }.buttonStyle(.plain)
        }
        .frame(width: 280, height: expanded ? 100 : 44, alignment: .bottom)
        .contentShape(.rect)
        .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { gesture in
                if dragStart == nil { dragStart = value; lastStop = nil }
                expanded = true
                let target = scale.dragging(from: dragStart ?? value, translation: gesture.translation.width)
                change(target, false)
                if let stop = scale.stops.first(where: { abs(log(target / $0)) < 0.025 }), stop != lastStop {
                    UISelectionFeedbackGenerator().selectionChanged(); lastStop = stop
                }
            }
            .onEnded { _ in dragStart = nil; interaction += 1 })
        .task(id: interaction) {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, dragStart == nil else { return }
            withAnimation(.easeOut(duration: 0.15)) { expanded = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera zoom")
        .accessibilityValue("\(Double(value).formatted(.number.precision(.fractionLength(1)))) times\(expanded ? ", dial open" : "")")
        .accessibilityHint("Drag left to zoom in, right to zoom out. Tap to open the dial.")
        .accessibilityIdentifier("camera-zoom-dial")
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = direction == .increment ? 0.1 : -0.1
            change(scale.clamped(value + delta), true)
        }
        .accessibilityAction { expanded.toggle(); interaction += 1 }
    }

    private var dialFace: some View {
        Canvas { context, size in
            let radius = size.width * 0.6
            let center = CGPoint(x: size.width / 2, y: radius + 12)
            func point(angle: CGFloat, radius: CGFloat) -> CGPoint {
                CGPoint(x: center.x + sin(angle) * radius, y: center.y - cos(angle) * radius)
            }
            // Draw only the visible arc. No scroll view, image assets, or capture changes.
            let low = Int(floor(log(max(0.01, minimum)) / 0.05))
            let high = Int(ceil(log(max(minimum, maximum)) / 0.05))
            for tick in low...high {
                let zoom = exp(CGFloat(tick) * 0.05)
                guard zoom >= minimum, zoom <= maximum else { continue }
                let angle = log(zoom / max(0.01, value)) * 0.9
                guard abs(angle) < 1.05 else { continue }
                var path = Path()
                path.move(to: point(angle: angle, radius: radius))
                path.addLine(to: point(angle: angle, radius: radius - 8))
                context.stroke(path, with: .color(.white.opacity(0.45)), lineWidth: 1)
            }
            for stop in scale.stops {
                let angle = log(stop / max(0.01, value)) * 0.9
                guard abs(angle) < 1.05 else { continue }
                var path = Path()
                path.move(to: point(angle: angle, radius: radius))
                path.addLine(to: point(angle: angle, radius: radius - 14))
                context.stroke(path, with: .color(.white), lineWidth: 2)
                let labelPosition = point(angle: angle, radius: radius - 26)
                if labelPosition.y < size.height - 8 {
                    context.draw(Text("\(Double(stop).formatted(.number.precision(.fractionLength(0...1))))")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white), at: labelPosition)
                }
            }
            var pointer = Path()
            pointer.move(to: CGPoint(x: center.x, y: 3)); pointer.addLine(to: CGPoint(x: center.x, y: 22))
            context.stroke(pointer, with: .color(Theme.signal), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }.accessibilityHidden(true)
    }
}
