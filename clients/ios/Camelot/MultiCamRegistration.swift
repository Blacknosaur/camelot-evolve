import CoreGraphics
import Foundation
import simd
import Vision

/// Finds where the second camera's frame sits inside (or beside) the main camera's frame.
/// Two cameras on a sideline are mostly a horizontal shift, so a coarse normalized
/// cross-correlation over downscaled greyscale finds that shift first; Vision's homographic
/// registration — good only for small misalignments — then refines the overlap.
enum MultiCamRegistration {
    /// Where the floating image's origin lands in reference pixels (top-left origin), and the
    /// normalized cross-correlation of the overlap at that placement (1 = identical).
    struct Shift: Equatable {
        var dx: CGFloat
        var dy: CGFloat
        var score: Double
    }

    /// Exhaustive search at 160 px wide, then refinement at 640 px. Returns nil when no
    /// placement overlaps at least a quarter of the narrower image with a meaningful score.
    static func coarseShift(reference: CGImage, floating: CGImage) -> Shift? {
        let coarse = Gray(reference, width: 160), coarseFloating = Gray(floating, scale: coarse.scale)
        let minimumOverlap = Int(Double(min(coarse.width, coarseFloating.width)) * 0.25)
        var best: (dx: Int, dy: Int, score: Double)?
        let dyLimit = max(2, coarse.height / 10)
        for dx in (minimumOverlap - coarseFloating.width)...(coarse.width - minimumOverlap) {
            for dy in stride(from: -dyLimit, through: dyLimit, by: 1) {
                let score = correlation(coarse, coarseFloating, dx: dx, dy: dy, minimumOverlap: minimumOverlap)
                if score > (best?.score ?? -1) { best = (dx, dy, score) }
            }
        }
        guard let best, best.score > 0.3 else { return nil }
        // Refine around the coarse answer at four times the resolution.
        let fine = Gray(reference, width: 640), fineFloating = Gray(floating, scale: fine.scale)
        let ratio = fine.scale / coarse.scale
        let centreX = Int((Double(best.dx) * ratio).rounded()), centreY = Int((Double(best.dy) * ratio).rounded())
        var refined = (dx: centreX, dy: centreY, score: -1.0)
        for dx in (centreX - 6)...(centreX + 6) {
            for dy in (centreY - 6)...(centreY + 6) {
                let score = correlation(fine, fineFloating, dx: dx, dy: dy, minimumOverlap: Int(Double(minimumOverlap) * ratio))
                if score > refined.score { refined = (dx, dy, score) }
            }
        }
        return Shift(dx: CGFloat(refined.dx) / fine.scale, dy: CGFloat(refined.dy) / fine.scale, score: refined.score)
    }

    /// The homography (floating → reference, pixel coordinates, bottom-left origin as Core Image and
    /// Vision use) for a pair of frames: the coarse shift, refined by Vision on the overlap when its
    /// answer stays close to that shift.
    static func homography(reference: CGImage, floating: CGImage) -> simd_float3x3? {
        guard let shift = coarseShift(reference: reference, floating: floating) else { return nil }
        // Top-left dy becomes bottom-left dy: the floating image's bottom edge sits at
        // referenceHeight − (dy + floatingHeight) in Core Image space.
        let dyBottomLeft = CGFloat(reference.height) - shift.dy - CGFloat(floating.height)
        let translation = simd_float3x3(rows: [simd_float3(1, 0, Float(shift.dx)), simd_float3(0, 1, Float(dyBottomLeft)), simd_float3(0, 0, 1)])
        let overlap = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
            .intersection(CGRect(x: shift.dx, y: shift.dy, width: CGFloat(floating.width), height: CGFloat(floating.height)))
        guard overlap.width > 64, overlap.height > 64,
              let referenceCrop = reference.cropping(to: overlap),
              let floatingCrop = floating.cropping(to: overlap.offsetBy(dx: -shift.dx, dy: -shift.dy)) else { return translation }
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: floatingCrop, options: [:])
        guard (try? VNImageRequestHandler(cgImage: referenceCrop, options: [:]).perform([request])) != nil,
              let residual = request.results?.first?.warpTransform else { return translation }
        // Both crops share the same origin offset in their images, so the residual applies directly
        // on top of the translation. Keep it only when it moves the corners a little.
        let corners = [CGPoint.zero, CGPoint(x: overlap.width, y: 0), CGPoint(x: overlap.width, y: overlap.height), CGPoint(x: 0, y: overlap.height)]
        guard let moved = MultiCamStitchLayout.warp(corners, by: residual) else { return translation }
        let tolerance = min(overlap.width, overlap.height) * 0.08
        let small = zip(corners, moved).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < tolerance }
        return small ? translation * residual : translation
    }

    // MARK: Greyscale search

    private struct Gray {
        let width: Int, height: Int
        let scale: Double
        let pixels: [Float]

        init(_ image: CGImage, width targetWidth: Int) {
            self.init(image, scale: Double(targetWidth) / Double(image.width))
        }

        init(_ image: CGImage, scale: Double) {
            self.scale = scale
            width = max(1, Int((Double(image.width) * scale).rounded()))
            height = max(1, Int((Double(image.height) * scale).rounded()))
            var bytes = [UInt8](repeating: 0, count: width * height)
            if let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            pixels = bytes.map { Float($0) }
        }
    }

    /// Zero-mean normalized cross-correlation of the overlap when `floating` is placed at (dx, dy).
    private static func correlation(_ reference: Gray, _ floating: Gray, dx: Int, dy: Int, minimumOverlap: Int) -> Double {
        let x0 = max(0, dx), x1 = min(reference.width, dx + floating.width)
        let y0 = max(0, dy), y1 = min(reference.height, dy + floating.height)
        guard x1 - x0 >= minimumOverlap, y1 - y0 >= 8 else { return -1 }
        var sumA: Float = 0, sumB: Float = 0, count: Float = 0
        for y in y0..<y1 {
            let rowA = y * reference.width, rowB = (y - dy) * floating.width - dx
            for x in x0..<x1 { sumA += reference.pixels[rowA + x]; sumB += floating.pixels[rowB + x] }
            count += Float(x1 - x0)
        }
        let meanA = sumA / count, meanB = sumB / count
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for y in y0..<y1 {
            let rowA = y * reference.width, rowB = (y - dy) * floating.width - dx
            for x in x0..<x1 {
                let a = reference.pixels[rowA + x] - meanA, b = floating.pixels[rowB + x] - meanB
                dot += a * b; normA += a * a; normB += b * b
            }
        }
        guard normA > 0, normB > 0 else { return -1 }
        return Double(dot / (normA.squareRoot() * normB.squareRoot()))
    }
}
