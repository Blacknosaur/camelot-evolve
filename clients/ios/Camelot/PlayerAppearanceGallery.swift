@preconcurrency import AVFoundation
import CoreImage
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

/// Several learned references of one player's look, from Vision's on-device
/// image feature print of the body crop. References cover poses, sides and
/// lighting, and help reject mismatches. A generic image embedding alone cannot
/// establish which same-kit teammate returned after motion continuity was lost.
struct PlayerAppearanceGallery: Codable, Equatable, Sendable {
    /// Rounded to three decimals for storage; comparisons are cosine similarity.
    var prints: [[Float]] = []
    var times: [Double] = []
    static let capacity = 8
    /// Feature prints of bodies shorter than this (frame units) are not
    /// reliable enough to learn from or to reject a candidate.
    static let minimumBodyHeight: CGFloat = 0.08
    /// Two clear, temporally separated views are enough to start automatic
    /// re-identification. A third view improves the gate, but waiting for it
    /// made short appearances (such as May 11) permanently manual.
    static let minimumReferences = 2

    var isReady: Bool { prints.count >= Self.minimumReferences }

    /// Match any trusted view. Forcing every pose to resemble the first view
    /// rejected valid turns in the soccer clip; update quality protects the bank.
    func similarity(to print: [Float]) -> Float? {
        guard let anchor = prints.first, anchor.count == print.count else { return nil }
        return prints.map { Self.cosine($0, print) }.max()
    }

    /// How alike the player's own references are, as the basis for a gate:
    /// another body must look less like this player than the player looks
    /// like themself on a bad day.
    var gate: Float {
        guard prints.count >= 2 else { return 0.7 }
        var lowest: Float = 1
        for i in prints.indices { for j in prints.indices where j > i { lowest = min(lowest, Self.cosine(prints[i], prints[j])) } }
        return min(0.8, max(0.5, lowest - 0.03))
    }

    /// Keep the first reference as the anchor; afterwards prefer diversity by
    /// replacing the reference most similar to the newcomer once full.
    mutating func add(_ print: [Float], at time: Double) {
        guard !print.isEmpty, print.allSatisfy(\.isFinite),
              print.contains(where: { $0 != 0 }),
              prints.first.map({ $0.count == print.count }) ?? true else { return }
        let rounded = print.map { ($0 * 1000).rounded() / 1000 }
        // Replacing a diverse reference leaves times out of order. Check all
        // nearby observations, including backward passes, instead of times.last.
        if times.contains(where: { abs(time - $0) < 0.4 }) { return }
        if prints.count < Self.capacity { prints.append(rounded); times.append(time); return }
        var closest = 1, best: Float = -1
        for index in 1..<prints.count {
            let value = Self.cosine(prints[index], rounded)
            if value > best { best = value; closest = index }
        }
        prints[closest] = rounded; times[closest] = time
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for index in a.indices { dot += a[index] * b[index]; na += a[index] * a[index]; nb += b[index] * b[index] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}

/// Feature prints of body crops on the current frame. One request per frame
/// source; the region of interest selects the body.
final class PlayerAppearancePrinter {
    private let request = VNGenerateImageFeaturePrintRequest()

    init() { request.imageCropAndScaleOption = .scaleFill }

    func print(_ buffer: CVPixelBuffer, box: CGRect, orientation: CGImagePropertyOrientation) -> [Float]? {
        let padded = box.insetBy(dx: -box.width * 0.1, dy: -box.height * 0.04).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !padded.isNull, padded.width > 0.004, padded.height > 0.01 else { return nil }
        request.regionOfInterest = CGRect(x: padded.minX, y: 1 - padded.maxY, width: padded.width, height: padded.height)
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNFeaturePrintObservation else { return nil }
        let count = observation.elementCount
        guard count > 0, observation.elementType == .float else { return nil }
        var values = [Float](repeating: 0, count: count)
        values.withUnsafeMutableBytes { raw in observation.data.copyBytes(to: raw) }
        return values
    }
}


enum PlayerIdentityView: String, Codable, CaseIterable, Identifiable, Sendable {
    case unspecified, front, back, left, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unspecified: "Selected view"
        case .front: "Front"
        case .back: "Back"
        case .left: "Left side"
        case .right: "Right side"
        }
    }
}

/// Match all available parts against the SAME confirmed view. Mixing one
/// player's shirt with a different view's head would make the gate too broad.
struct PlayerIdentityReference: Codable, Equatable, Sendable {
    var view: PlayerIdentityView
    var observation: PlayerObservation

    func kitSimilarity(to other: PlayerObservation) -> Float {
        guard let shirt = observation.jersey, let candidate = other.jersey else { return 0 }
        let agreement = shirt.similarity(to: candidate)
        if let a = observation.chroma, let b = other.chroma, a.similarity(to: b) < 0.5 { return 0 }
        return agreement
    }

    func similarity(to other: PlayerObservation) -> Float? {
        guard let shirt = observation.jersey, let candidate = other.jersey else { return nil }
        var score = shirt.similarity(to: candidate)
        if score < 0.55 { return 0 }
        if let a = observation.chroma, let b = other.chroma {
            let agreement = a.similarity(to: b)
            if agreement < 0.5 { return 0 }
            if agreement < 0.65 { score *= 0.7 }
        }
        if let a = observation.shorts, let b = other.shorts { score = score * 0.85 + min(score, a.similarity(to: b)) * 0.15 }
        for (a, b) in [(observation.head, other.head), (observation.legs, other.legs)] {
            guard let a, let b else { continue }
            let agreement = a.similarity(to: b)
            if agreement < 0.4 { return 0 }
            if agreement < 0.55 { score *= 0.6 }
            else if agreement < 0.7 { score *= 0.85 }
        }
        if let a = observation.print, let b = other.print,
           min(observation.box.height, other.box.height) >= PlayerAppearanceGallery.minimumBodyHeight {
            let appearance = PlayerAppearanceGallery.cosine(a, b)
            if appearance < 0.5 { return 0 }
            if appearance < 0.6 { score *= 0.7 }
            score = min(score, 0.98 + 0.02 * max(0, appearance))
        }
        return score
    }
}

extension PlayerAppearancePrinter {
    /// Expensive features are requested only for selected/shortlisted bodies.
    func enrich(_ observation: inout PlayerObservation, buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                bodyExtent: CGRect? = nil) {
        let body = bodyExtent ?? observation.box
        let upper = CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.4)
        let visible = observation.box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        if body.height >= PlayerAppearanceGallery.minimumBodyHeight,
           visible.contains(upper), !observation.crowded {
            observation.upperBodyPrint = print(buffer, box: upper, orientation: orientation)
        }
        guard observation.isPartial != true else { return }
        guard observation.box.height >= PlayerAppearanceGallery.minimumBodyHeight else { return }
        observation.print = print(buffer, box: observation.box, orientation: orientation)
        let box = observation.box
        let swapped = [CGImagePropertyOrientation.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let width = CGFloat(swapped ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetWidth(buffer))
        let height = CGFloat(swapped ? CVPixelBufferGetWidth(buffer) : CVPixelBufferGetHeight(buffer))
        // Actual source pixels, not the number of repeated histogram samples.
        guard box.width * width >= 24, box.height * height >= 128, !observation.crowded,
              !PlayerBodyExtent.isCropped(box) else { return }
        let crown = CGRect(x: box.minX + box.width * 0.35, y: box.minY + box.height * 0.01,
                           width: box.width * 0.3, height: box.height * 0.035)
        if crown.width * width >= 8, crown.height * height >= 4 {
            observation.hair = PlayerJerseySignature.sample(buffer, box: box, orientation: orientation, region: crown)
        }
        let faces = VNDetectFaceRectanglesRequest()
        faces.regionOfInterest = CGRect(x: box.minX, y: 1 - box.minY - box.height * 0.23, width: box.width, height: box.height * 0.23)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard (try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation).perform([faces])) != nil,
              let face = faces.results?.first, face.confidence >= 0.8,
              face.boundingBox.width * width >= 12, face.boundingBox.height * height >= 12 else { return }
        let bounds = face.boundingBox
        guard box.contains(CGPoint(x: bounds.midX, y: 1 - bounds.midY)) else { return }
        let cheek = CGRect(x: bounds.minX + bounds.width * 0.2, y: 1 - bounds.maxY + bounds.height * 0.45,
                           width: bounds.width * 0.6, height: bounds.height * 0.25)
        observation.skin = PlayerJerseySignature.sample(buffer, box: box, orientation: orientation, region: cheek)
    }

    static func reference(url: URL, box: CGRect, at time: Double) async throws -> PlayerObservation {
        let image = try await FieldFrameSource(url: url).image(at: time)
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { throw AnalysisError.reader("Cannot read the selected player") }
        CIContext(options: [.cacheIntermediates: false]).render(CIImage(cgImage: image), to: buffer)
        let boxes = try SportsPlayerDetector().playerBoxes(in: buffer, orientation: .up)
        var observation = PlayerObservation.observe(buffer, box: box, orientation: .up, among: boxes.filter { PlayerTracker.overlap($0, box) < 0.65 })
        observation.time = time
        observation.number = ShirtNumberReader().read(buffer, box: box, orientation: .up)
        PlayerAppearancePrinter().enrich(&observation, buffer: buffer, orientation: .up)
        return observation
    }
}
