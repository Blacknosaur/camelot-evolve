import CoreGraphics
import Foundation
import simd

/// Sparse image correspondences, not player detections. Local normalized patches
/// tolerate exposure changes; consensus excludes independently moving objects.
/// All fitting is in normalized top-left image coordinates.
enum CameraFeatureRegistration {
    struct Match {
        var source: CGPoint
        var target: CGPoint
    }

    /// One decoded frame, owned by one camera pass. Reference features are reused
    /// until its anchor changes; fallback proposals reuse the same gray images.
    final class Frame {
        let image: CGImage
        let gray: GrayImage
        /// True where the pixel is turf or a bright marking on turf. Corners on
        /// the stands are a different plane from the pitch.
        let ground: [Bool]
        lazy var features: [(point: CGPoint, patch: [Float])] = gray.corners().compactMap { point in
            guard let patch = gray.patch(Int(point.x), Int(point.y)) else { return nil }
            return (point, patch)
        }

        init?(_ image: CGImage) {
            guard let gray = GrayImage(image) else { return nil }
            self.image = image
            self.gray = gray
            self.ground = Self.groundMask(image, width: gray.width, height: gray.height)
        }

        func isGround(_ point: CGPoint) -> Bool {
            guard ground.count == gray.width * gray.height, gray.width > 0, gray.height > 0 else { return false }
            let x = min(gray.width - 1, max(0, Int(point.x.rounded())))
            let y = min(gray.height - 1, max(0, Int(point.y.rounded())))
            return ground[y * gray.width + x]
        }

        /// Grass and the white paint on it. A corner on a shirt is rejected
        /// later by consensus; this mask only keeps the ground plane.
        private static func groundMask(_ image: CGImage, width: Int, height: Int) -> [Bool] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return [] }
            var mask = [Bool](repeating: false, count: width * height)
            func turf(_ x: Int, _ y: Int) -> Bool {
                let i = (y * width + x) * 4
                let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
                return g > 45 && g * 100 > r * 94 && g * 100 > b * 135
            }
            for y in 0..<height {
                for x in 0..<width where turf(x, y) { mask[y * width + x] = true }
            }
            var grown = mask
            guard height > 6, width > 6 else { return mask }
            for y in 3..<(height - 3) {
                for x in 3..<(width - 3) where !mask[y * width + x] {
                    let i = (y * width + x) * 4
                    let bright = (Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])) / 3 > 150
                    guard bright else { continue }
                    if mask[(y - 3) * width + x] || mask[(y + 3) * width + x]
                        || mask[y * width + (x - 3)] || mask[y * width + (x + 3)] {
                        grown[y * width + x] = true
                    }
                }
            }
            return grown
        }
    }

    struct GrayImage {
        let width: Int
        let height: Int
        let values: [Float]

        init?(_ image: CGImage) {
            let width = min(640, image.width)
            let height = max(2, Int(Double(image.height) * Double(width) / Double(image.width)))
            self.width = width; self.height = height
            var bytes = [UInt8](repeating: 0, count: width * height)
            let valid = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard valid else { return nil }
            values = bytes.map { Float($0) / 255 }
        }

        func patch(_ x: Int, _ y: Int) -> [Float]? {
            guard x >= 5, y >= 5, x < width - 5, y < height - 5 else { return nil }
            var patch: [Float] = []; patch.reserveCapacity(25)
            for dy in stride(from: -4, through: 4, by: 2) {
                for dx in stride(from: -4, through: 4, by: 2) { patch.append(values[(y + dy) * width + x + dx]) }
            }
            let mean = patch.reduce(0, +) / Float(patch.count)
            let centered = patch.map { $0 - mean }
            let norm = sqrt(centered.reduce(0) { $0 + $1 * $1 })
            guard norm > 0.14 else { return nil }
            return centered.map { $0 / norm }
        }

        func corners() -> [CGPoint] {
            var result: [CGPoint] = []
            // Equal spatial quotas prevent one crowded stand or a cluster of
            // players from dominating the camera estimate. Skip the very bottom.
            for row in 0..<6 {
                for column in 0..<8 {
                    var candidates: [(Float, Int, Int)] = []
                    let minX = max(8, column * width / 8), maxX = min(width - 8, (column + 1) * width / 8)
                    let minY = max(8, row * height * 9 / 60), maxY = min(height - 8, (row + 1) * height * 9 / 60)
                    for y in stride(from: minY, to: maxY, by: 3) {
                        for x in stride(from: minX, to: maxX, by: 3) {
                            var xx: Float = 0, yy: Float = 0, xy: Float = 0
                            for dy in -1...1 {
                                for dx in -1...1 {
                                    let i = (y + dy) * width + x + dx
                                    let gx = values[i + 1] - values[i - 1], gy = values[i + width] - values[i - width]
                                    xx += gx * gx; yy += gy * gy; xy += gx * gy
                                }
                            }
                            let strength = (xx + yy - sqrt((xx - yy) * (xx - yy) + 4 * xy * xy)) / 2
                            if strength > 0.012 { candidates.append((strength, x, y)) }
                        }
                    }
                    var chosen: [CGPoint] = []
                    for candidate in candidates.sorted(by: { $0.0 > $1.0 }) {
                        let point = CGPoint(x: candidate.1, y: candidate.2)
                        if chosen.allSatisfy({ hypot($0.x - point.x, $0.y - point.y) > 16 }) {
                            chosen.append(point)
                            if chosen.count == 3 { break }
                        }
                    }
                    result += chosen
                }
            }
            return result
        }

        func locate(_ patch: [Float], near point: CGPoint, radius: Int) -> (point: CGPoint, score: Float)? {
            let cx = Int(point.x.rounded()), cy = Int(point.y.rounded())
            guard cx > -radius, cy > -radius, cx < width + radius, cy < height + radius else { return nil }
            func score(_ x: Int, _ y: Int) -> Float {
                guard x >= 5, y >= 5, x < width - 5, y < height - 5 else { return -1 }
                var sum: Float = 0, squares: Float = 0, product: Float = 0, index = 0
                for dy in stride(from: -4, through: 4, by: 2) {
                    for dx in stride(from: -4, through: 4, by: 2) {
                        let value = values[(y + dy) * width + x + dx]
                        sum += value; squares += value * value; product += patch[index] * value; index += 1
                    }
                }
                let variance = squares - sum * sum / 25
                return variance > 0.0196 ? product / sqrt(variance) : -1
            }
            var best: (Int, Int, Float) = (cx, cy, -1)
            var scores: [(Int, Int, Float)] = []
            for y in stride(from: cy - radius, through: cy + radius, by: 2) {
                for x in stride(from: cx - radius, through: cx + radius, by: 2) {
                    let value = score(x, y); scores.append((x, y, value))
                    if value > best.2 { best = (x, y, value) }
                }
            }
            let coarse = best
            for y in (coarse.1 - 1)...(coarse.1 + 1) {
                for x in (coarse.0 - 1)...(coarse.0 + 1) {
                    let value = score(x, y)
                    if value > best.2 { best = (x, y, value) }
                }
            }
            let other = scores.filter { hypot(Double($0.0 - best.0), Double($0.1 - best.1)) > 4 }.map(\.2).max() ?? -1
            guard best.2 > 0.84, best.2 - other > 0.035 else { return nil }
            func offset(_ left: Float, _ right: Float) -> Double {
                // Do not invent subpixel motion on an exact integer match.
                if best.2 > 0.9999 { return 0 }
                let denominator = left - 2 * best.2 + right
                guard denominator < -0.0001 else { return 0 }
                return min(0.5, max(-0.5, Double((left - right) / (2 * denominator))))
            }
            return (.init(x: Double(best.0) + offset(score(best.0 - 1, best.1), score(best.0 + 1, best.1)),
                          y: Double(best.1) + offset(score(best.0, best.1 - 1), score(best.0, best.1 + 1))), best.2)
        }
    }

    static func register(previous: CGImage, current: CGImage, initial: CameraTransform) -> CameraTransform? {
        guard let previous = Frame(previous), let current = Frame(current) else { return nil }
        return register(previous: previous, current: current, initial: initial)
    }

    static func register(previous: Frame, current: Frame, initial: CameraTransform) -> CameraTransform? {
        let ground = previous.features.filter { previous.isGround($0.point) }
        // The pitch and the stands are different planes. A fit on the grass
        // keeps field lines and floor drawings still; too little paint falls
        // back to the whole frame so a clip without grass still tracks.
        if ground.count >= 18, let fitted = align(previous: previous, current: current, features: ground, initial: initial) {
            return fitted
        }
        return align(previous: previous, current: current, features: previous.features, initial: initial)
    }

    private static func align(previous: Frame, current: Frame, features: [(point: CGPoint, patch: [Float])], initial: CameraTransform) -> CameraTransform? {
        let a = previous.gray, b = current.gray
        guard a.width == b.width, a.height == b.height else { return nil }
        var matches: [Match] = []
        for (point, patch) in features {
            let source = CGPoint(x: point.x / Double(a.width), y: point.y / Double(a.height))
            guard let guess = initial.point(source),
                  let target = b.locate(patch, near: .init(x: guess.x * Double(b.width), y: guess.y * Double(b.height)), radius: 12),
                  let backPatch = b.patch(Int(target.point.x.rounded()), Int(target.point.y.rounded())),
                  let back = a.locate(backPatch, near: point, radius: 4),
                  hypot(back.point.x - point.x, back.point.y - point.y) < 1.5 else { continue }
            matches.append(.init(source: source, target: .init(x: target.point.x / Double(b.width), y: target.point.y / Double(b.height))))
        }
        return consensus(matches, size: CGSize(width: a.width, height: a.height))
    }

    static func consensus(_ matches: [Match], size: CGSize) -> CameraTransform? {
        guard matches.count >= 12 else { return nil }
        func residual(_ transform: CameraTransform, _ match: Match) -> Double {
            guard let point = transform.point(match.source) else { return .infinity }
            return hypot((point.x - match.target.x) * size.width, (point.y - match.target.y) * size.height)
        }
        var best: [Match] = [], bestError = Double.infinity, random: UInt64 = 0x43414D455241
        for _ in 0..<160 {
            var indices: Set<Int> = []
            while indices.count < 4 {
                random = random &* 6364136223846793005 &+ 1
                indices.insert(Int((random >> 32) % UInt64(matches.count)))
            }
            guard let candidate = fit(indices.sorted().map { matches[$0] }) else { continue }
            let inliers = matches.filter { residual(candidate, $0) < 1.6 }
            let error = inliers.reduce(0) { $0 + residual(candidate, $1) }
            if inliers.count > best.count || inliers.count == best.count && error < bestError { best = inliers; bestError = error }
        }
        guard best.count >= 12, best.count >= matches.count / 2,
              let minX = best.map(\.source.x).min(), let maxX = best.map(\.source.x).max(),
              let minY = best.map(\.source.y).min(), let maxY = best.map(\.source.y).max(),
              maxX - minX > 0.3, maxY - minY > 0.12 else { return nil }
        let cells = Set(best.map { Int($0.source.x * 4) + 4 * Int($0.source.y * 4) })
        guard cells.count >= 5, let fitted = fit(best), plausible(fitted) else { return nil }
        return fitted
    }

    static func plausible(_ transform: CameraTransform) -> Bool {
        let matrix = transform.matrix
        guard transform.values.allSatisfy(\.isFinite), matrix.determinant > 0.35, matrix.determinant < 3 else { return false }
        return GroundFieldOverlay.rectangle.allSatisfy { point in
            let homogeneous = matrix * SIMD3(Float(point.x), Float(point.y), 1)
            guard homogeneous.z > 0.2, let moved = transform.point(point) else { return false }
            return hypot(moved.x - point.x, moved.y - point.y) < 0.65
        }
    }

    /// Small normalized least-squares system. Pivoting rejects degenerate or
    /// near-collinear feature sets instead of producing unstable perspective.
    private static func fit(_ matches: [Match]) -> CameraTransform? {
        var system = Array(repeating: Array(repeating: 0.0, count: 9), count: 8)
        for match in matches {
            let x = match.source.x, y = match.source.y, u = match.target.x, v = match.target.y
            for (row, value) in [([x, y, 1, 0, 0, 0, -u * x, -u * y], u), ([0, 0, 0, x, y, 1, -v * x, -v * y], v)] {
                for i in 0..<8 {
                    for j in 0..<8 { system[i][j] += row[i] * row[j] }
                    system[i][8] += row[i] * value
                }
            }
        }
        for column in 0..<8 {
            let pivot = (column..<8).max { abs(system[$0][column]) < abs(system[$1][column]) }!
            guard abs(system[pivot][column]) > 1e-10 else { return nil }
            system.swapAt(column, pivot)
            let scale = system[column][column]
            for j in column...8 { system[column][j] /= scale }
            for row in 0..<8 where row != column {
                let factor = system[row][column]
                for j in column...8 { system[row][j] -= factor * system[column][j] }
            }
        }
        return .init(values: system.map { $0[8] } + [1])
    }
}
