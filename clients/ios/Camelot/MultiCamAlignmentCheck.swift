import Combine
import CoreImage
import CoreVideo
import Foundation

/// Live "are these two cameras aimed so they can be joined?" check for the two-camera setup.
/// It runs the same shift search the stitcher uses, on downscaled live frames, so what the pad
/// says before kick-off is what the wide view will do afterwards.
@MainActor
final class MultiCamAlignmentCheck: ObservableObject {
    enum Verdict: Equatable {
        case searching
        case noOverlap
        case tooLittle(percent: Int)
        case good(percent: Int)
        case tooMuch(percent: Int)

        var message: String {
            switch self {
            case .searching: "Checking the two views…"
            case .noOverlap: "No shared view — aim both phones at the same part of the pitch"
            case let .tooLittle(percent): "Only \(percent)% shared — turn the phones towards each other"
            case let .good(percent): "\(percent)% shared — good to record"
            case let .tooMuch(percent): "\(percent)% shared — turn them apart for a wider view"
            }
        }
        var isGood: Bool { if case .good = self { return true }; return false }
    }

    @Published private(set) var verdict: Verdict = .searching
    /// How far the second camera sits below (+) or above (−) the first, as a share of frame height.
    @Published private(set) var verticalDrift: Double = 0
    /// Which side the second camera is on, so the preview can put it there.
    @Published private(set) var cameraOnRight = true

    private var task: Task<Void, Never>?
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// Samples both cameras about every 1.5 s; the search itself runs off the main actor.
    func start(local: @escaping @MainActor () -> CVPixelBuffer?, remote: @escaping @MainActor () -> CVPixelBuffer?) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let reference = local().flatMap({ self.image(from: $0) }),
                   let floating = remote().flatMap({ self.image(from: $0) }) {
                    let result = await Task.detached(priority: .utility) {
                        MultiCamRegistration.coarseShift(reference: reference, floating: floating)
                    }.value
                    if Task.isCancelled { return }
                    self.apply(result, width: CGFloat(reference.width), height: CGFloat(reference.height))
                }
                try? await Task.sleep(for: .milliseconds(1_500))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    private func apply(_ shift: MultiCamRegistration.Shift?, width: CGFloat, height: CGFloat) {
        guard let shift, shift.score > 0.35 else { verdict = .noOverlap; return }
        // `dx` is where the second frame's left edge lands in the first frame's pixels.
        let overlap = max(0, width - abs(shift.dx))
        let percent = Int((overlap / width * 100).rounded())
        cameraOnRight = shift.dx >= 0
        verticalDrift = Double(shift.dy / height)
        verdict = switch percent {
        case ..<8: .noOverlap
        case 8..<15: .tooLittle(percent: percent)
        case 15...55: .good(percent: percent)
        default: .tooMuch(percent: percent)
        }
    }

    /// A small greyscale-friendly still; the search downsamples again, so 480 px is plenty.
    private func image(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = 480 / max(source.extent.width, 1)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
