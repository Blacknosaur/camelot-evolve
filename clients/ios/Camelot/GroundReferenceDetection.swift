import CoreGraphics
import Foundation

/// Conservative geometry for proposing a visible reference rectangle.
///
/// This is deliberately unaware of pitch semantics. A caller must show the
/// proposal to the user and obtain confirmation (including dimensions).
enum GroundReferenceDetection {
    struct Result: Sendable {
        let corners: [CGPoint]
        let intersections: [CGPoint]
    }

    static func detect(in image: CGImage) throws -> Result {
        propose(from: try FieldLineDetection.detect(in: image))
    }

    /// Finds intersections supported by the finite segments and, only when a
    /// single unambiguous closed convex cycle is present, proposes its corners.
    static func propose(from segments: [FieldLineDetection.Segment]) -> Result {
        // Keep the quadratic work bounded even if a detector returns junk.
        let usable = Array(segments.prefix(8)).filter { segment in
            finite(segment.start) && finite(segment.end) && distance(segment.start, segment.end) > 0.0001
        }
        var unique: [FieldLineDetection.Segment] = []
        for segment in usable where !unique.contains(where: { sameSegment($0, segment) }) {
            unique.append(segment)
        }

        var pairIntersections: [((Int, Int), CGPoint)] = []
        for i in unique.indices {
            for j in unique.indices where j > i {
                if let point = intersection(unique[i], unique[j]) {
                    pairIntersections.append(((i, j), point))
                }
            }
        }
        var intersections: [CGPoint] = []
        for (_, point) in pairIntersections where !intersections.contains(where: { distance($0, point) < 0.012 }) {
            intersections.append(point)
        }

        var candidates: [[CGPoint]] = []
        if unique.count >= 4 {
            for a in 0..<(unique.count - 3) {
                for b in (a + 1)..<(unique.count - 2) {
                    for c in (b + 1)..<(unique.count - 1) {
                        for d in (c + 1)..<unique.count {
                            let subset = [a, b, c, d]
                            for order in permutations(of: subset) where order[0] == a {
                                guard let p01 = intersection(unique[order[0]], unique[order[1]]),
                                      let p12 = intersection(unique[order[1]], unique[order[2]]),
                                      let p23 = intersection(unique[order[2]], unique[order[3]]),
                                      let p30 = intersection(unique[order[3]], unique[order[0]]) else { continue }
                                let points = [p01, p12, p23, p30]
                                guard points.allSatisfy({ point in finite(point) }),
                                      pointsAreDistinct(points),
                                      pointsAreSupported(points, by: order.map { unique[$0] }),
                                      isConvex(points),
                                      polygonArea(points) > 0.002 else { continue }
                                if !candidates.contains(where: { samePointSet($0, points) }) {
                                    candidates.append(clockwise(points))
                                }
                            }
                        }
                    }
                }
            }
        }

        return Result(corners: candidates.count == 1 ? candidates[0] : [], intersections: intersections)
    }

    private static func intersection(_ lhs: FieldLineDetection.Segment, _ rhs: FieldLineDetection.Segment) -> CGPoint? {
        let r = CGPoint(x: lhs.end.x - lhs.start.x, y: lhs.end.y - lhs.start.y)
        let s = CGPoint(x: rhs.end.x - rhs.start.x, y: rhs.end.y - rhs.start.y)
        let denominator = cross(r, s)
        guard abs(denominator) > 0.035 * hypot(r.x, r.y) * hypot(s.x, s.y) else { return nil }
        let delta = CGPoint(x: rhs.start.x - lhs.start.x, y: rhs.start.y - lhs.start.y)
        let t = cross(delta, s) / denominator
        let u = cross(delta, r) / denominator
        // Do not use infinite-line intersections: both markings must support
        // the proposed corner at their visible, finite portions.
        guard t >= -0.02, t <= 1.02, u >= -0.02, u <= 1.02 else { return nil }
        return CGPoint(x: lhs.start.x + t * r.x, y: lhs.start.y + t * r.y)
    }

    private static func pointsAreSupported(_ points: [CGPoint], by segments: [FieldLineDetection.Segment]) -> Bool {
        zip(points, points.indices).allSatisfy { point, index in
            // points[index] is the intersection of side[index] and the
            // following side. The other endpoint of side[index] is the
            // preceding intersection.
            let previous = points[(index + points.count - 1) % points.count]
            let segment = segments[index]
            return distance(point, previous) > 0.03 && pointOnSegment(point, segment) && pointOnSegment(previous, segment)
        }
    }

    private static func pointOnSegment(_ point: CGPoint, _ segment: FieldLineDetection.Segment) -> Bool {
        let length = distance(segment.start, segment.end)
        let crossDistance = abs(cross(CGPoint(x: segment.end.x - segment.start.x, y: segment.end.y - segment.start.y),
                                      CGPoint(x: point.x - segment.start.x, y: point.y - segment.start.y))) / length
        let dot = (point.x - segment.start.x) * (segment.end.x - segment.start.x) +
            (point.y - segment.start.y) * (segment.end.y - segment.start.y)
        return crossDistance < 0.012 && dot >= -0.02 * length * length && dot <= (length * length) * 1.02
    }

    private static func isConvex(_ points: [CGPoint]) -> Bool {
        let signs = (0..<4).map { i in
            let a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4]
            return cross(CGPoint(x: b.x - a.x, y: b.y - a.y), CGPoint(x: c.x - b.x, y: c.y - b.y))
        }
        return signs.allSatisfy { $0 > 0.0001 } || signs.allSatisfy { $0 < -0.0001 }
    }

    private static func clockwise(_ points: [CGPoint]) -> [CGPoint] {
        let ordered = polygonAreaSigned(points) >= 0 ? points : Array(points.reversed())
        guard let first = ordered.indices.min(by: { lhs, rhs in
            let left = ordered[lhs], right = ordered[rhs]
            let leftScore = left.x + left.y, rightScore = right.x + right.y
            if leftScore != rightScore { return leftScore < rightScore }
            if left.y != right.y { return left.y < right.y }
            return left.x < right.x
        }) else { return ordered }
        return Array(ordered[first...]) + Array(ordered[..<first])
    }

    private static func sameSegment(_ lhs: FieldLineDetection.Segment, _ rhs: FieldLineDetection.Segment) -> Bool {
        (distance(lhs.start, rhs.start) < 0.012 && distance(lhs.end, rhs.end) < 0.012) ||
            (distance(lhs.start, rhs.end) < 0.012 && distance(lhs.end, rhs.start) < 0.012)
    }

    private static func samePointSet(_ lhs: [CGPoint], _ rhs: [CGPoint]) -> Bool {
        lhs.allSatisfy { point in rhs.contains { distance(point, $0) < 0.012 } }
    }

    private static func pointsAreDistinct(_ points: [CGPoint]) -> Bool {
        for i in points.indices { for j in (i + 1)..<points.count where distance(points[i], points[j]) < 0.012 { return false } }
        return true
    }

    private static func permutations(of values: [Int]) -> [[Int]] {
        values.count == 1 ? [values] : values.flatMap { value in permutations(of: values.filter { $0 != value }).map { [value] + $0 } }
    }

    private static func finite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func cross(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.y - a.y * b.x }
    private static func polygonArea(_ points: [CGPoint]) -> CGFloat { abs(polygonAreaSigned(points)) }
    private static func polygonAreaSigned(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst() + points.prefix(1)).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y } / 2
    }
}
