import CoreGraphics
import Foundation

/// Log spacing gives wide-angle and telephoto zoom the same precision per movement.
struct CameraZoomScale {
    let minimum: CGFloat
    let maximum: CGFloat
    /// Lens switch-over factors in display units (0.5×, 1×, 3× …). Empty on a single-lens device.
    var lensFactors: [CGFloat] = []

    func clamped(_ value: CGFloat) -> CGFloat { min(maximum, max(minimum, value)) }

    /// Horizontal drag on the collapsed row: 180 pt per e-fold, negative translation zooms in.
    func dragging(from start: CGFloat, translation: CGFloat) -> CGFloat {
        clamped(start * exp(-translation / 180))
    }

    /// Labelled stops on the ruler: the lens stops plus the round factors in range.
    var stops: [CGFloat] {
        CameraZoomStops.merge([0.5, 1, 2, 3, 4, 5, 6] + lensFactors, minimum: minimum, maximum: maximum)
    }

    /// Stops that trigger a haptic while dragging or pinching.
    var hapticStops: [CGFloat] { CameraZoomStops.pills(lensFactors: lensFactors, minimum: minimum, maximum: maximum) }
}

/// Derives the lens pills shown above the shutter from the active device's switch-over factors.
enum CameraZoomStops {
    /// - Parameters:
    ///   - switchOverFactors: `virtualDeviceSwitchOverVideoZoomFactors` in hardware units.
    ///   - displayMultiplier: hardware → display factor (0.5 on ultra-wide virtual devices).
    static func lensFactors(switchOverFactors: [Double], displayMultiplier: CGFloat) -> [CGFloat] {
        switchOverFactors.map { CGFloat($0) * displayMultiplier }.filter { $0.isFinite && $0 > 0 }
    }

    /// Apple-style pill row: 0.5× when the range starts below 1, 1×, each lens, and a 2× crop
    /// stop unless a lens already sits at or just above 2×. A single-lens device gets 1× and 2×.
    static func pills(lensFactors: [CGFloat], minimum: CGFloat, maximum: CGFloat) -> [CGFloat] {
        var candidates: [CGFloat] = [1] + lensFactors
        if minimum < 0.95 { candidates.append(minimum) }
        let hasLensNearTwo = lensFactors.contains { $0 > 1.05 && $0 <= 2.5 }
        if !hasLensNearTwo, maximum >= 2 { candidates.append(2) }
        return merge(candidates, minimum: minimum, maximum: maximum)
    }

    /// Sorted, clamped and de-duplicated (values within 4% collapse to the first one).
    static func merge(_ values: [CGFloat], minimum: CGFloat, maximum: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        for value in values.sorted() where value >= minimum - 0.001 && value <= maximum + 0.001 {
            let clamped = min(maximum, max(minimum, value))
            if let last = result.last, abs(log(clamped / last)) < 0.04 { continue }
            result.append(clamped)
        }
        return result
    }

    /// The pill that owns the live factor: the largest stop not above the value. A ramp can settle
    /// a hair under its target (1.9999), so a stop within 1% below counts as reached.
    static func selectedPill(for value: CGFloat, in pills: [CGFloat]) -> CGFloat? {
        pills.last { $0 * 0.99 <= value } ?? pills.first
    }

    /// Text on a pill: the live value on the selected pill, the stop on the others.
    static func label(for stop: CGFloat, value: CGFloat, isSelected: Bool) -> String {
        if isSelected { return "\(format(value, decimals: 1))×" }
        return format(stop, decimals: stop == stop.rounded() ? 0 : 1)
    }

    static func format(_ value: CGFloat, decimals: Int) -> String {
        Double(value).formatted(.number.precision(.fractionLength(decimals)))
    }
}

/// Horizontal ruler where equal distances mean equal zoom ratios. The indicator stays in the
/// centre; the ticks slide under it as the finger drags.
struct CameraZoomRuler {
    let scale: CameraZoomScale
    var pointsPerOctave: CGFloat = 120
    /// Tick every tenth of an octave ≈ 7% zoom.
    var tickOctaves: CGFloat = 0.1

    struct Tick: Equatable {
        let zoom: CGFloat
        let offset: CGFloat
        let isStop: Bool
    }

    /// Horizontal distance from the centre for `zoom` while the ruler is centred on `value`.
    func offset(of zoom: CGFloat, around value: CGFloat) -> CGFloat {
        (log2(max(zoom, 0.01)) - log2(max(value, 0.01))) * pointsPerOctave
    }

    /// Dragging the ruler right (positive translation) moves the ticks right, so the value falls.
    func value(from start: CGFloat, translation: CGFloat) -> CGFloat {
        scale.clamped(start * pow(2, -translation / pointsPerOctave))
    }

    /// Visible ticks for a ruler of `width` centred on `value`.
    func ticks(around value: CGFloat, width: CGFloat) -> [Tick] {
        let half = width / 2
        let stops = scale.stops
        var ticks: [Tick] = []
        let low = Int(floor(log2(max(0.01, scale.minimum)) / tickOctaves))
        let high = Int(ceil(log2(max(scale.minimum, scale.maximum)) / tickOctaves))
        for index in low...high {
            let zoom = pow(2, CGFloat(index) * tickOctaves)
            guard zoom >= scale.minimum * 0.999, zoom <= scale.maximum * 1.001 else { continue }
            let offset = offset(of: zoom, around: value)
            guard abs(offset) <= half else { continue }
            if stops.contains(where: { abs(log(zoom / $0)) < 0.02 }) { continue }
            ticks.append(Tick(zoom: zoom, offset: offset, isStop: false))
        }
        for stop in stops {
            let offset = offset(of: stop, around: value)
            guard abs(offset) <= half else { continue }
            ticks.append(Tick(zoom: stop, offset: offset, isStop: true))
        }
        return ticks.sorted { $0.offset < $1.offset }
    }

    /// The stop crossed between two values, for haptics. `nil` when no stop lies between them.
    static func crossedStop(from previous: CGFloat, to current: CGFloat, stops: [CGFloat]) -> CGFloat? {
        let low = min(previous, current), high = max(previous, current)
        return stops.first { $0 > low * 0.999 && $0 <= high * 1.001 && abs(log($0 / previous)) > 0.001 }
    }

    /// Snap a value that is within 2% of a stop onto it so a release lands on the lens.
    static func snapped(_ value: CGFloat, to stops: [CGFloat], tolerance: CGFloat = 0.02) -> CGFloat {
        stops.first { abs(log(value / $0)) < tolerance } ?? value
    }
}

/// Exposure bias slider next to the focus reticle: dragging up brightens.
struct CameraExposureSlider {
    let minimum: Float
    let maximum: Float
    var pointsPerStop: CGFloat = 40
    var trackHeight: CGFloat = 132

    func clamped(_ value: Float) -> Float { min(maximum, max(minimum, value)) }

    /// Bias after a vertical drag that began at `start`; moving up (negative dy) raises exposure.
    func bias(from start: Float, verticalTranslation: CGFloat) -> Float {
        clamped(start - Float(verticalTranslation / pointsPerStop))
    }

    /// Vertical position of the sun icon within the track (0 = top = brightest).
    func knobOffset(for bias: Float) -> CGFloat {
        guard maximum > minimum else { return trackHeight / 2 }
        let fraction = CGFloat((maximum - clamped(bias)) / (maximum - minimum))
        return fraction * trackHeight
    }
}
