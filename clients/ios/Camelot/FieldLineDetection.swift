import CoreGraphics
import Foundation

/// Finds visible straight white markings on turf, not semantic pitch landmarks.
/// Deliberately returns reviewable segments rather than inventing a full pitch
/// from a partial view. No model download or network access is required.
enum FieldLineDetection {
    struct Segment: Identifiable, Sendable {
        let id: Int
        let start: CGPoint
        let end: CGPoint
    }

    static func detect(in image: CGImage) throws -> [Segment] {
        let width = min(640, image.width)
        let height = max(1, image.height * width / image.width)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, width > 16, height > 16 else { return [] }
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * width + x) * 4
            return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
        }
        func turf(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            let (r, g, b) = rgb(x, y)
            return g > 45 && g > r * 0.94 && g > b * 1.35
        }
        var points: [CGPoint] = []
        for y in 6..<(height - 6) {
            try Task.checkCancellation()
            for x in 6..<(width - 6) {
                let (r, g, b) = rgb(x, y)
                guard (r + g + b) / 3 > 100, r > g * 0.72, b > g * 0.53 else { continue }
                let neighbours = [(x - 5, y), (x + 5, y), (x, y - 5), (x, y + 5)]
                let grass = neighbours.filter { turf($0.0, $0.1) }
                guard grass.count >= 2 else { continue }
                var total = 0.0
                for neighbour in grass {
                    let (nr, ng, nb) = rgb(neighbour.0, neighbour.1)
                    total += (nr + ng + nb) / 3
                }
                let background = total / Double(grass.count)
                if (r + g + b) / 3 > background + 16 { points.append(.init(x: x, y: y)) }
            }
        }
        guard points.count >= 30 else { return [] }
        let radius = Int(ceil(hypot(Double(width), Double(height))))
        let bins = radius * 2 + 1
        let angles = (0..<180).map { Double($0) * .pi / 180 }
        let cosines = angles.map(cos), sines = angles.map(sin)
        var votes = [Int](repeating: 0, count: 180 * bins)
        for angle in 0..<180 {
            try Task.checkCancellation()
            for point in points {
                let rho = Int((point.x * cosines[angle] + point.y * sines[angle]).rounded()) + radius
                votes[angle * bins + rho] += 1
            }
        }
        let peaks = votes.indices.filter { votes[$0] >= 35 }.sorted { votes[$0] > votes[$1] }
        var result: [Segment] = []
        for peak in peaks.prefix(160) {
            try Task.checkCancellation()
            let angle = peak / bins, rho = Double(peak % bins - radius)
            let nx = cosines[angle], ny = sines[angle], dx = -ny, dy = nx
            let support = points.filter { abs($0.x * nx + $0.y * ny - rho) < 1.3 }
                .map { $0.x * dx + $0.y * dy }.sorted()
            guard let first = support.first else { continue }
            var runs: [(Double, Double, Int)] = [], start = first, previous = first, count = 0
            for position in support {
                if position - previous > 10 {
                    runs.append((start, previous, count)); start = position; count = 0
                }
                previous = position; count += 1
            }
            runs.append((start, previous, count))
            for (low, high, count) in runs.sorted(by: { $0.1 - $0.0 > $1.1 - $1.0 }) {
                let length = high - low
                guard length > Double(width) * 0.09, Double(count) / length > 0.55 else { continue }
                let a = CGPoint(x: nx * rho + dx * low, y: ny * rho + dy * low)
                let b = CGPoint(x: nx * rho + dx * high, y: ny * rho + dy * high)
                // Reject fences, shirts and advertising: a marking needs turf on
                // both sides over most of its length, not just near one endpoint.
                var turfSamples = 0
                for step in 0..<20 {
                    let t = low + length * (Double(step) + 0.5) / 20
                    let x = nx * rho + dx * t, y = ny * rho + dy * t
                    if turf(Int(x + nx * 5), Int(y + ny * 5)) && turf(Int(x - nx * 5), Int(y - ny * 5)) { turfSamples += 1 }
                }
                guard turfSamples >= 13 else { continue }
                let duplicate = result.contains { segment in
                    let px = Double(segment.start.x) * Double(width), py = Double(segment.start.y) * Double(height)
                    let qx = Double(segment.end.x) * Double(width), qy = Double(segment.end.y) * Double(height)
                    let alongNormal = (qx - px) * nx + (qy - py) * ny
                    let parallel = abs(alongNormal) / max(1, hypot(qx - px, qy - py)) < 0.18
                    let pT = px * dx + py * dy, qT = qx * dx + qy * dy
                    let overlapStart = max(low, min(pT, qT)), overlapEnd = min(high, max(pT, qT))
                    guard parallel, overlapEnd > overlapStart, abs(qT - pT) > 1 else { return false }
                    // Compare at the overlapping portion, not the midpoint of a
                    // much longer segment (which can exaggerate angle rounding).
                    let fraction = ((overlapStart + overlapEnd) / 2 - pT) / (qT - pT)
                    let x = px + (qx - px) * fraction, y = py + (qy - py) * fraction
                    return abs(x * nx + y * ny - rho) < 5
                }
                if !duplicate {
                    result.append(.init(id: result.count, start: .init(x: a.x / Double(width), y: a.y / Double(height)),
                                        end: .init(x: b.x / Double(width), y: b.y / Double(height))))
                }
                if result.count == 8 { return result }
            }
        }
        return result
    }
}
