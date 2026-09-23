import Vision

/// One live Vision tracker per selected player. A fresh detector observation
/// starts a NEW Vision identity; release the previous one before re-anchoring.
/// Merely replacing inputObservation on the same handler exhausts its pool.
final class VisionPlayerTracker {
    private var handler: VNSequenceRequestHandler?
    private var request: VNTrackObjectRequest?
    private var lastBuffer: CVPixelBuffer?
    private var lastObservation: VNDetectedObjectObservation?
    private var orientation: CGImagePropertyOrientation = .up

    init(seed: CGRect) { reseed(seed) }

    func reseed(_ box: CGRect) {
        finish()
        handler = VNSequenceRequestHandler()
        let next = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
        next.trackingLevel = .accurate
        request = next
    }

    func track(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> VNDetectedObjectObservation? {
        guard let handler, let request else { return nil }
        self.orientation = orientation
        try handler.perform([request], on: buffer, orientation: orientation)
        lastBuffer = buffer
        lastObservation = request.results?.first as? VNDetectedObjectObservation
        if let lastObservation { request.inputObservation = lastObservation }
        return lastObservation
    }

    /// Also called on cancellation, loss, EOF and failure. Processing a final
    /// request, rather than only setting isLastFrame, returns its pool slot.
    func finish() {
        if let handler, let request, let lastBuffer, let lastObservation {
            request.inputObservation = lastObservation
            request.isLastFrame = true
            try? handler.perform([request], on: lastBuffer, orientation: orientation)
        }
        request = nil; handler = nil; lastBuffer = nil; lastObservation = nil
    }
}
