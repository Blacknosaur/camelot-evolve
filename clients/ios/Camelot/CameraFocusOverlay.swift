import Observation
import SwiftUI

/// Transient viewfinder feedback driven by the preview's UIKit recognisers: focus reticle with its
/// exposure slider, AE/AF lock badge and the zoom HUD shown while pinching.
@MainActor @Observable
final class CameraInteractionState {
    struct Reticle: Equatable {
        var point: CGPoint
        var token = UUID()
    }

    private(set) var reticle: Reticle?
    /// Dimmed once the initial focus animation settles; the slider stays usable.
    private(set) var reticleIsSettled = false
    private(set) var isLocked = false
    private(set) var zoomHUDFactor: CGFloat?
    private var hideTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?

    func showFocus(at point: CGPoint) {
        reticle = Reticle(point: point)
        reticleIsSettled = false
        scheduleHide()
    }

    func lock(at point: CGPoint) {
        reticle = Reticle(point: point)
        reticleIsSettled = false
        isLocked = true
        scheduleHide()
    }

    func unlock() {
        isLocked = false
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { reticle = nil }
    }

    /// Any touch on the slider restarts the idle timer.
    func touchedExposure() { scheduleHide() }

    func showZoomHUD(_ factor: CGFloat) {
        zoomHUDFactor = factor
        hudTask?.cancel()
    }

    func endZoomHUD() {
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { zoomHUDFactor = nil }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { reticleIsSettled = true }
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, !isLocked else { return }
            withAnimation(.easeOut(duration: 0.3)) { reticle = nil }
        }
    }
}

/// Sits over the preview in the same coordinate space. Only the exposure slider takes touches.
struct CameraFocusOverlay: View {
    let state: CameraInteractionState
    let exposureBias: Float
    let exposureRange: ClosedRange<Float>
    let setExposureBias: (Float) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let reticle = state.reticle {
                    FocusReticle(isSettled: state.reticleIsSettled, isLocked: state.isLocked)
                        .position(reticle.point)
                        .id(reticle.token)
                        .allowsHitTesting(false)
                    ExposureSliderView(bias: exposureBias, range: exposureRange,
                        set: { value in state.touchedExposure(); setExposureBias(value) })
                        .opacity(state.reticleIsSettled ? 0.75 : 1)
                        .position(sliderCenter(for: reticle.point, in: proxy.size))
                        .id(reticle.token)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(.easeOut(duration: 0.25), value: state.reticle)
    }

    /// Slider on the right of the reticle unless it would leave the screen; kept inside vertically.
    private func sliderCenter(for point: CGPoint, in size: CGSize) -> CGPoint {
        let x = point.x + 72 + 24 <= size.width ? point.x + 72 : point.x - 72
        let half = CameraExposureSlider(minimum: exposureRange.lowerBound, maximum: exposureRange.upperBound).trackHeight / 2
        return CGPoint(x: x, y: min(max(point.y, half + 60), size.height - half - 60))
    }
}

/// Yellow square that shrinks in and dims, like Camera.app.
private struct FocusReticle: View {
    let isSettled: Bool
    let isLocked: Bool
    @State private var appeared = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 76, height: 76)
            .overlay {
                ForEach(0..<4, id: \.self) { index in
                    Rectangle().fill(Color.yellow).frame(width: index < 2 ? 1.5 : 7, height: index < 2 ? 7 : 1.5)
                        .offset(x: index == 2 ? -38 : index == 3 ? 38 : 0, y: index == 0 ? -38 : index == 1 ? 38 : 0)
                }
            }
            .scaleEffect(appeared ? 1 : 1.6)
            .opacity(appeared ? (isSettled && !isLocked ? 0.55 : 1) : 0)
            .onAppear { withAnimation(.spring(duration: 0.28, bounce: 0.2)) { appeared = true } }
            .accessibilityLabel(isLocked ? "Focus locked" : "Focus point")
            .accessibilityIdentifier("camera-focus-indicator")
    }
}

/// Thin vertical track with a sun knob; drag up to brighten. VoiceOver adjusts in ⅓-stop steps.
private struct ExposureSliderView: View {
    let bias: Float
    let range: ClosedRange<Float>
    let set: (Float) -> Void
    @State private var dragStartBias: Float?
    private var slider: CameraExposureSlider { CameraExposureSlider(minimum: range.lowerBound, maximum: range.upperBound) }

    var body: some View {
        ZStack(alignment: .top) {
            Capsule().fill(Color.yellow.opacity(0.85)).frame(width: 1.5, height: slider.trackHeight)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.yellow)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .offset(y: slider.knobOffset(for: bias) - 9)
            if abs(bias) > 0.05 {
                Text(bias.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())))
                    .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.yellow)
                    .offset(x: 22, y: slider.knobOffset(for: bias) - 6)
            }
        }
        .frame(width: 44, height: slider.trackHeight + 24)
        .contentShape(.rect)
        .highPriorityGesture(DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if dragStartBias == nil { dragStartBias = bias }
                set(slider.bias(from: dragStartBias ?? bias, verticalTranslation: gesture.translation.height))
            }
            .onEnded { _ in dragStartBias = nil })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exposure")
        .accessibilityValue("\(bias.formatted(.number.precision(.fractionLength(1)))) EV")
        .accessibilityIdentifier("camera-exposure-slider")
        .accessibilityAdjustableAction { direction in
            set(slider.clamped(bias + (direction == .increment ? 1 : -1) / 3))
        }
    }
}

/// Factor label that fades in while pinching.
struct CameraZoomHUD: View {
    let factor: CGFloat
    var body: some View {
        Text("\(CameraZoomStops.format(factor, decimals: 1))×")
            .font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(Theme.signal)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.55), in: .capsule)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .accessibilityLabel("Zoom").accessibilityValue("\(CameraZoomStops.format(factor, decimals: 1)) times")
            .accessibilityIdentifier("camera-zoom-hud")
    }
}

/// Apple-style AE/AF lock badge.
struct CameraLockBadge: View {
    var body: some View {
        Text("AE/AF LOCK")
            .font(.system(size: 11, weight: .bold, design: .rounded)).tracking(0.5)
            .foregroundStyle(.black)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.yellow, in: .rect(cornerRadius: 6))
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .accessibilityLabel("Exposure and focus locked")
            .accessibilityIdentifier("camera-aeaf-lock")
    }
}
