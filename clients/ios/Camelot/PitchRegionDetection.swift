import CoreGraphics
import CoreML
import Vision
@preconcurrency import AVFoundation

/// On-device semantic segmentation supplies a starting pose, never an
/// automatically accepted metric calibration. The user reviews the field overlay.
enum PitchRegionDetection {
    struct ReferenceFrame: Sendable {
        let time: Double
        let proposal: Proposal
        var score: Double { proposal.score }
    }

    /// Bounded search: prefer the chosen frame, then clip-wide candidates and
    /// a nearby alternative that can avoid a fast pan or transient occlusion.
    /// Every proposal is snapped to the painted markings; the search stops at
    /// the first frame whose snapped alignment grades well.
    static func findReference(url: URL, range: ClosedRange<Double>, preferred: Double,
                              pitchLength: Double = 105, pitchWidth: Double = 68) async throws -> ReferenceFrame? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = .init(width: 1920,height: 1920)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let span = range.upperBound-range.lowerBound
        let third = range.lowerBound+span/3
        let candidates = [preferred,third,max(range.lowerBound,third-min(1,span/12)),range.lowerBound+span*2/3]
        let model = try makeModel()
        var fallback: ReferenceFrame?
        for time in candidates {
            try Task.checkCancellation()
            let frame = try await generator.image(at: CMTime(seconds: time,preferredTimescale: 600))
            let proposals = try detect(in: frame.image, model: model, pitchLength: pitchLength, pitchWidth: pitchWidth)
            guard let best = proposals.first else { continue }
            let candidate = ReferenceFrame(time: time, proposal: best)
            if best.registration?.quality.grade == .good { return candidate }
            if fallback == nil || candidate.score > fallback!.score { fallback = candidate }
        }
        return fallback
    }

    struct Proposal: Identifiable, Sendable {
        let landmark: GroundLandmark
        let corners: [CGPoint]
        var circle: GroundCircleReference? = nil
        /// The proposal snapped to painted markings, when that succeeded.
        var registration: PitchRegistration.Result? = nil
        var id: GroundLandmark { landmark }

        /// Ranks proposals: snapped grade first, then evidence coverage. A
        /// complete refined circle still beats an unsnapped area proposal.
        var score: Double {
            guard let quality = registration?.quality else { return circle != nil ? 0.5 : 0 }
            let base: Double = switch quality.grade { case .good: 3; case .check: 2; case .poor: 1 }
            return base + min(0.9, quality.coverage)
        }
    }

    /// Proposals are ordered best first. Pitch dimensions feed the snapped
    /// template; they are editable in the sheet and not measured here.
    static func detect(in image: CGImage, pitchLength: Double = 105, pitchWidth: Double = 68) throws -> [Proposal] {
        try detect(in: image, model: makeModel(), pitchLength: pitchLength, pitchWidth: pitchWidth)
    }

    private static let modelLock = NSLock()
    nonisolated(unsafe) private static var cachedModel: VNCoreMLModel?

    /// Loading and preparing the model is by far the slowest step; keep one
    /// prepared instance for the app's lifetime.
    private static func makeModel() throws -> VNCoreMLModel {
        modelLock.lock(); defer { modelLock.unlock() }
        if let cachedModel { return cachedModel }
        guard let url = Bundle.main.url(forResource: "PitchRegions", withExtension: "mlmodelc") else {
            throw AnalysisError.noVideoTrack
        }
        let model = try VNCoreMLModel(for: MLModel(contentsOf: url))
        cachedModel = model
        return model
    }

    private static func detect(in image: CGImage, model: VNCoreMLModel, pitchLength: Double, pitchWidth: Double) throws -> [Proposal] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        try Task.checkCancellation()
        guard let output = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue,
              output.shape.map(\.intValue) == [1, 6, 136, 240] else { return [] }
        let markings = try FieldLineDetection.detect(in: image)
        var proposals: [Proposal] = []
        for (channel, landmark) in [(1, GroundLandmark.centreCircle), (2, .penaltyArea), (4, .goalArea)] {
            try Task.checkCancellation()
            let points = largestRegion(output, channel: channel)
            guard points.count >= 80,
                  points.allSatisfy({ $0.x > 0.008 && $0.x < 0.992 && $0.y > 0.015 && $0.y < 0.985 }) else { continue }
            let corners: [CGPoint]
            if landmark == .centreCircle {
                guard let ellipse = circleCorners(points, markings: markings) else { continue }
                var halfway = [CGPoint(x: (ellipse[0].x+ellipse[3].x)/2, y: (ellipse[0].y+ellipse[3].y)/2),
                               CGPoint(x: (ellipse[1].x+ellipse[2].x)/2, y: (ellipse[1].y+ellipse[2].y)/2)]
                let outline = refinedCircleOutline(in: image, seed: ellipse, halfway: &halfway)
                guard let circle = GroundCircleReference.fit(outline: outline, halfway: halfway,
                    imageSize: .init(width: image.width, height: image.height)), let anchors = circle.anchors else { continue }
                corners = GroundFieldOverlay.calibrationCorners(anchors: anchors, landmark: .centreCircle)
                proposals.append(.init(landmark: landmark, corners: corners, circle: circle))
                continue
            } else {
                corners = rectangleCorners(points)
            }
            guard corners.count == 4, AnalysisFieldGuide.projection(corners: corners) != nil else { continue }
            proposals.append(.init(landmark: landmark, corners: corners))
        }
        guard !proposals.isEmpty, let evidence = PitchRegistration.Evidence(image: image) else { return proposals }
        for index in proposals.indices {
            try Task.checkCancellation()
            let proposal = proposals[index]
            var draft = GroundCalibration(mode: .plane, points: proposal.corners,
                lengthMeters: proposal.landmark.defaultLengthMeters, widthMeters: proposal.landmark.defaultWidthMeters,
                referenceTime: 0, imageAspectRatio: Double(image.width) / Double(max(1, image.height)))
            draft.fieldReference = .init(landmark: proposal.landmark, pitchLength: pitchLength, pitchWidth: pitchWidth)
            proposals[index].registration = PitchRegistration.snap(draft, evidence: evidence)
        }
        return proposals.sorted { $0.score > $1.score }
    }

    /// The network only locates the search area. Refine the painted curve using
    /// source-resolution colour/contrast evidence, excluding players as outliers.
    private static func refinedCircleOutline(in image: CGImage, seed: [CGPoint], halfway: inout [CGPoint]) -> [CGPoint] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width*height*4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0,y: 0,width: width,height: height)); return true
        }
        guard drawn, seed.count == 4 else { return [] }
        let center = CGPoint(x: seed.map(\.x).reduce(0,+)/4, y: seed.map(\.y).reduce(0,+)/4)
        let a = CGPoint(x: (seed[1].x-seed[0].x)/2, y: (seed[1].y-seed[0].y)/2)
        let b = CGPoint(x: (seed[3].x-seed[0].x)/2, y: (seed[3].y-seed[0].y)/2)
        func whiteness(_ x: Double, _ y: Double) -> Double {
            let ix = Int(x.rounded()), iy = Int(y.rounded())
            guard ix >= 0, ix < width, iy >= 0, iy < height else { return 0 }
            let i = (iy*width+ix)*4
            let r = Double(pixels[i]), g = Double(pixels[i+1]), blue = Double(pixels[i+2])
            guard r > g*0.8, blue > g*0.65 else { return 0 }
            return max(0,min(r,g,blue)-0.5*max(r,g,blue))
        }
        // Refine the halfway direction too: the coarse Hough angle should not
        // decide where a distant goal line is projected.
        if halfway.count == 2 {
            let start = CGPoint(x: halfway[0].x*Double(width),y: halfway[0].y*Double(height))
            let dx = (halfway[1].x-halfway[0].x)*Double(width), dy = (halfway[1].y-halfway[0].y)*Double(height)
            let length = hypot(dx,dy)
            if length > 20 {
                let nx = -dy/length, ny = dx/length
                var support: [CGPoint] = []
                for i in 2..<39 {
                    let t = 0.15 + Double(i-2)/36 * 0.7
                    let x = start.x+t*dx, y = start.y+t*dy
                    var best: (score: Double, point: CGPoint)?
                    let searchRadius = max(12, min(64, width/40))
                    for offset in -searchRadius...searchRadius {
                        let px = x+Double(offset)*nx, py = y+Double(offset)*ny
                        let value = whiteness(px,py)
                        let background = (whiteness(px-5*nx,py-5*ny)+whiteness(px+5*nx,py+5*ny))/2
                        let score = value-background
                        if value > 25, score > 12, score > (best?.score ?? 0) { best = (score,.init(x: px,y: py)) }
                    }
                    if let best { support.append(best.point) }
                }
                if support.count >= 25 {
                    let count = Double(support.count)
                    let mx = support.reduce(0.0) { $0+$1.x }/count, my = support.reduce(0.0) { $0+$1.y }/count
                    let xx = support.reduce(0.0) { $0+pow($1.x-mx,2) }, yy = support.reduce(0.0) { $0+pow($1.y-my,2) }
                    let xy = support.reduce(0.0) { $0+($1.x-mx)*($1.y-my) }
                    let angle = atan2(2*xy,xx-yy)/2, ux = cos(angle), uy = sin(angle)
                    let error = support.map { abs(($0.x-mx)*uy-($0.y-my)*ux) }.sorted()[support.count*3/4]
                    if error < 2, abs((ux*dx+uy*dy)/length) > 0.98 {
                        halfway = [-1.0,1.0].map { sign -> CGPoint in
                            let offset = sign * length / 2
                            let x = (mx + offset * ux) / Double(width)
                            let y = (my + offset * uy) / Double(height)
                            return CGPoint(x: x, y: y)
                        }
                    }
                }
            }
        }
        var result: [CGPoint] = []
        for index in 0..<180 {
            let angle = Double(index)*2*Double.pi/180
            let dx = (a.x*cos(angle)+b.x*sin(angle))*Double(width)
            let dy = (a.y*cos(angle)+b.y*sin(angle))*Double(height)
            let radius = hypot(dx,dy)
            guard radius > 8 else { continue }
            let ux = dx/radius, uy = dy/radius
            let px = center.x*Double(width)+dx, py = center.y*Double(height)+dy
            let window = min(60,max(12,Int(radius*0.18)))
            var best: (score: Double, point: CGPoint)?
            for offset in -window...window {
                let x = px+Double(offset)*ux, y = py+Double(offset)*uy
                let value = whiteness(x,y)
                let background = (whiteness(x-5*ux,y-5*uy)+whiteness(x+5*ux,y+5*uy))/2
                let score = value-background-Double(abs(offset))*0.12
                if value > 25, score > 12, score > (best?.score ?? 0) {
                    best = (score,.init(x: x/Double(width),y: y/Double(height)))
                }
            }
            if let best { result.append(best.point) }
        }
        return result.count >= 130 ? result : []
    }

    private static func largestRegion(_ array: MLMultiArray, channel: Int) -> [CGPoint] {
        let width = 240, height = 136
        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height { for x in 0..<width {
            mask[y*width+x] = array[[0, NSNumber(value: channel), NSNumber(value: y), NSNumber(value: x)]].doubleValue > 0.65
        } }
        var largest: [Int] = []
        for index in mask.indices where mask[index] {
            var queue = [index], head = 0; mask[index] = false
            while head < queue.count {
                let p = queue[head]; head += 1
                let x = p % width, y = p / width
                let adjacent = [(x-1,y), (x+1,y), (x,y-1), (x,y+1)]
                for (x,y) in adjacent where x >= 0 && x < width && y >= 0 && y < height {
                    let next = y*width+x
                    if mask[next] { mask[next] = false; queue.append(next) }
                }
            }
            if queue.count > largest.count { largest = queue }
        }
        return largest.map { .init(x: (Double($0 % width)+0.5)/Double(width), y: (Double($0 / width)+0.5)/Double(height)) }
    }

    /// Affine ellipse initialization; it intentionally does not invent a camera
    /// perspective from one circle. Visible-line fitting / handle refinement is
    /// available before the user accepts it.
    private static func circleCorners(_ points: [CGPoint], markings: [FieldLineDetection.Segment]) -> [CGPoint]? {
        let n = CGFloat(points.count)
        let center = CGPoint(x: points.reduce(CGFloat.zero) { $0 + $1.x } / n, y: points.reduce(CGFloat.zero) { $0 + $1.y } / n)
        let xx: CGFloat = points.reduce(CGFloat.zero) { sum, p in let d = p.x-center.x; return sum+d*d } * 4 / n
        let yy: CGFloat = points.reduce(CGFloat.zero) { sum, p in let d = p.y-center.y; return sum+d*d } * 4 / n
        let xy: CGFloat = points.reduce(CGFloat.zero) { $0 + ($1.x-center.x)*($1.y-center.y) } * 4 / n
        let determinant = xx*yy-xy*xy
        guard determinant > 1e-9, yy > 0.0001 else { return nil }
        let qxx = yy/determinant, qxy = -xy/determinant, qyy = xx/determinant
        func magnitude(_ p: CGPoint) -> CGFloat { sqrt(max(0, qxx*p.x*p.x + 2*qxy*p.x*p.y + qyy*p.y*p.y)) }
        let candidates = markings.filter {
            let dx = $0.end.x-$0.start.x, dy = $0.end.y-$0.start.y
            let distance = abs(dx*(center.y-$0.start.y)-dy*(center.x-$0.start.x)) / max(0.001,hypot(dx,dy))
            return abs(dy) > abs(dx)*0.5 && distance < sqrt(yy)*0.5
        }
        let halfway = candidates.max { hypot($0.end.x-$0.start.x,$0.end.y-$0.start.y) < hypot($1.end.x-$1.start.x,$1.end.y-$1.start.y) }
        var direction = halfway.map { CGPoint(x: $0.end.x-$0.start.x, y: $0.end.y-$0.start.y) } ?? CGPoint(x: 0,y: 1)
        if direction.y < 0 { direction.x *= -1; direction.y *= -1 }
        let radius = magnitude(direction)
        guard radius > 0 else { return nil }
        let v = CGPoint(x: direction.x/radius, y: direction.y/radius)
        let perpendicular = CGPoint(x: qxy*v.x+qyy*v.y, y: -(qxx*v.x+qxy*v.y))
        let r = magnitude(perpendicular)
        guard r > 0 else { return nil }
        let w = CGPoint(x: perpendicular.x/r, y: perpendicular.y/r)
        // Most predicted pixels must agree with an ellipse, not an arbitrary blob.
        guard points.filter({ magnitude(.init(x: $0.x-center.x,y: $0.y-center.y)) < 1.15 }).count > points.count*9/10 else { return nil }
        let signs: [CGPoint] = [.init(x: -1, y: -1), .init(x: 1, y: -1), .init(x: 1, y: 1), .init(x: -1, y: 1)]
        return signs.map { p -> CGPoint in
            let x: CGFloat = center.x + p.x * v.x + p.y * w.x
            let y: CGFloat = center.y + p.x * v.y + p.y * w.y
            return CGPoint(x: x, y: y)
        }
    }

    private static func rectangleCorners(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ a: CGPoint,_ b: CGPoint,_ c: CGPoint) -> Double { (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) }
        func half(_ points: [CGPoint]) -> [CGPoint] {
            var hull: [CGPoint] = []
            for p in points {
                while hull.count >= 2 && cross(hull[hull.count-2],hull[hull.count-1],p) <= 0 { hull.removeLast() }
                hull.append(p)
            }
            return hull
        }
        var hull = Array(half(sorted).dropLast()) + Array(half(sorted.reversed()).dropLast())
        guard hull.count >= 4 else { return [] }
        while hull.count > 4 {
            let i = hull.indices.min { abs(cross(hull[($0+hull.count-1)%hull.count],hull[$0],hull[($0+1)%hull.count])) < abs(cross(hull[($1+hull.count-1)%hull.count],hull[$1],hull[($1+1)%hull.count])) }!
            hull.remove(at: i)
        }
        let right = points.reduce(0) { $0+$1.x } / Double(points.count) > 0.5
        let goal = hull.indices.max { a,b in
            let lhs = (hull[a].x+hull[(a+1)%4].x)*(right ? 1 : -1)
            let rhs = (hull[b].x+hull[(b+1)%4].x)*(right ? 1 : -1)
            return lhs < rhs
        }!
        let next = (goal+1)%4
        return hull[goal].y < hull[next].y
            ? (0..<4).map { hull[(goal+$0)%4] }
            : (0..<4).map { hull[(next-$0+4)%4] }
    }
}
