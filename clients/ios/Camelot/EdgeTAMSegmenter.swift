import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import ImageIO
import Foundation

/// EdgeTAM (Meta, Apache 2.0) running on device through Core ML, with its
/// temporal memory.
///
/// This is video object segmentation, not per-frame segmentation. Each frame is
/// conditioned on a memory bank built from the frames before it, which is what
/// lets the mask follow a player through fast motion: the prompt is given once,
/// and after that the object is carried by memory rather than re-derived from a
/// stale box every frame.
///
/// The memory modules are not part of Meta's Core ML export — they are in the
/// checkpoint but the upstream converter only emits the image path. See
/// `EDGETAM_NOTICE.md` for the conversion and what had to be changed to make it
/// convert at all.
///
/// Layout, fixed because Core ML wants static shapes:
///
///     7 spatial slots x 512 tokens   slot 0 is the prompted frame, 1...6 the
///                                    most recent, oldest first
///     16 object pointers x 256       newest first
final class EdgeTAMSegmenter: PlayerTemporalSegmenter {
    var carriesTemporalMemory: Bool { true }

    private static let inputSize = 1024
    private static let maskSize = 256
    private static let featureSide = 64
    private static let hiddenDim = 256
    private static let memoryDim = 64
    private static let slots = 7
    private static let tokensPerSlot = 512
    private static let pointers = 16

    private let encoder: MLModel
    private let prompter: MLModel
    private let attention: MLModel
    private let memoryEncoder: MLModel
    private let decoder: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false])
    /// Added to the first frame's features in place of memory attention, which
    /// has nothing to attend to yet.
    private let noMemoryEmbed: [Float]

    /// Slot 0 is the prompted frame; the rest is a ring of recent frames.
    private var conditioningMemory: (features: MLMultiArray, pos: MLMultiArray)?
    private var recent: [(features: MLMultiArray, pos: MLMultiArray)] = []
    private var objectPointers: [MLMultiArray] = []
    /// Prompt embeddings for propagated frames: no real points, so the decoder
    /// has to rely on memory. Matches how SAM 2 propagates.
    private var emptyPrompt: (sparse: MLMultiArray, dense: MLMultiArray)?
    /// Where the ROI was when memory was last written, so a mask can be mapped
    /// back even though each frame's crop differs.
    private var lastROI: PlayerROI?

    init(bundle: Bundle = .main) throws {
        func load(_ name: String) throws -> MLModel {
            guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
                throw AnalysisError.reader("The EdgeTAM model \(name) is missing from this installation.")
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        encoder = try load("edgetam_image_encoder_pos")
        prompter = try load("edgetam_prompt_encoder")
        attention = try load("edgetam_memory_attention")
        memoryEncoder = try load("edgetam_memory_encoder")
        decoder = try load("edgetam_mask_decoder_mem")

        guard let url = bundle.url(forResource: "edgetam_no_mem_embed_f32", withExtension: "bin"),
              let data = try? Data(contentsOf: url), data.count == Self.hiddenDim * 4 else {
            throw AnalysisError.reader("The EdgeTAM no-memory embedding is missing from this installation.")
        }
        noMemoryEmbed = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: - Segmenter

    func begin(frame: CVPixelBuffer, orientation: CGImagePropertyOrientation,
               roi: PlayerROI, prompt box: CGRect) throws -> PlayerSegmentation? {
        // Spatial memory belongs to this crop coordinate system. A new prompt
        // starts a new bank; player identity is retained by the track manager.
        reset()
        guard let features = try encode(frame, orientation: orientation, roi: roi) else { return nil }
        // No memory yet: SAM 2 adds a learned "no memory" vector instead of
        // running attention over an empty bank.
        let conditioned = try addNoMemoryEmbed(features.vision)
        let prompt = try boxPrompt(roi.local(box))
        guard let result = try decode(conditioned: conditioned, features: features,
                                      prompt: prompt, roi: roi) else { return nil }
        try remember(features: features, result: result, conditioning: true)
        lastROI = roi
        return result.segmentation
    }

    func next(frame: CVPixelBuffer, orientation: CGImagePropertyOrientation,
              roi: PlayerROI) throws -> PlayerSegmentation? {
        guard conditioningMemory != nil, lastROI == roi, !objectPointers.isEmpty else { return nil }
        guard let features = try encode(frame, orientation: orientation, roi: roi) else { return nil }
        let conditioned = try conditionOnMemory(features)
        // Propagated frames carry no point prompt; the object comes from memory.
        let prompt = try emptyPromptEmbeddings()
        guard let result = try decode(conditioned: conditioned, features: features,
                                      prompt: prompt, roi: roi) else { return nil }
        // IoU predicts mask quality, not identity. Poor shapes must not become
        // the next frame's memory even when the outer tracker holds the player.
        if result.segmentation.confidence >= PlayerTrackConfidence.usable {
            try remember(features: features, result: result, conditioning: false)
        }
        lastROI = roi
        return result.segmentation
    }

    func forgetRecentMemory() {
        // Keep the prompted frame and the identity pointers; drop the recent
        // ring, which is exactly the memory of frames we could not see.
        recent.removeAll()
    }

    private func reset() {
        conditioningMemory = nil
        recent.removeAll()
        objectPointers.removeAll()
        lastROI = nil
    }

    // MARK: - Stages

    private struct Features {
        let vision: MLMultiArray
        let pos: MLMultiArray
        let high0: MLMultiArray
        let high1: MLMultiArray
    }

    private struct Decoded {
        let segmentation: PlayerSegmentation
        let highResMask: MLMultiArray
        let objectScore: MLMultiArray
        let pointer: MLMultiArray
    }

    private func encode(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                        roi: PlayerROI) throws -> Features? {
        guard let input = crop(buffer, orientation: orientation, roi: roi) else { return nil }
        let out = try encoder.prediction(from: try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: input)]))
        guard let vision = out.featureValue(for: "vision_features")?.multiArrayValue,
              let pos = out.featureValue(for: "vision_pos_enc")?.multiArrayValue,
              let high0 = out.featureValue(for: "high_res_feat_0")?.multiArrayValue,
              let high1 = out.featureValue(for: "high_res_feat_1")?.multiArrayValue else { return nil }
        return Features(vision: vision, pos: pos, high0: high0, high1: high1)
    }

    private func addNoMemoryEmbed(_ vision: MLMultiArray) throws -> MLMultiArray {
        let out = try MLMultiArray(shape: vision.shape, dataType: .float16)
        let source = vision.dataPointer.assumingMemoryBound(to: Float16.self)
        let target = out.dataPointer.assumingMemoryBound(to: Float16.self)
        let plane = Self.featureSide * Self.featureSide
        for channel in 0..<Self.hiddenDim {
            let bias = Float16(noMemoryEmbed[channel])
            let base = channel * plane
            for index in 0..<plane { target[base + index] = source[base + index] + bias }
        }
        return out
    }

    private func conditionOnMemory(_ features: Features) throws -> MLMultiArray {
        let memoryFeatures = try MLMultiArray(
            shape: [NSNumber(value: Self.slots), 1, NSNumber(value: Self.tokensPerSlot), NSNumber(value: Self.memoryDim)],
            dataType: .float16)
        let memoryPos = try MLMultiArray(shape: memoryFeatures.shape, dataType: .float16)
        // Slot 0 is the prompted frame. The recent ring fills 1...6 oldest
        // first; while it is short the prompted frame stands in, because it is
        // the one observation we know is the right player.
        var filled: [(features: MLMultiArray, pos: MLMultiArray)] = []
        if let conditioningMemory {
            filled.append(conditioningMemory)
            let tail = recent.suffix(Self.slots - 1)
            filled += Array(repeating: conditioningMemory, count: max(0, Self.slots - 1 - tail.count))
            filled += tail
        }
        let slotStride = Self.tokensPerSlot * Self.memoryDim
        let featureTarget = memoryFeatures.dataPointer.assumingMemoryBound(to: Float16.self)
        let posTarget = memoryPos.dataPointer.assumingMemoryBound(to: Float16.self)
        for (slot, entry) in filled.prefix(Self.slots).enumerated() {
            let f = entry.features.dataPointer.assumingMemoryBound(to: Float16.self)
            let p = entry.pos.dataPointer.assumingMemoryBound(to: Float16.self)
            for index in 0..<slotStride {
                featureTarget[slot * slotStride + index] = f[index]
                posTarget[slot * slotStride + index] = p[index]
            }
        }

        let pointerArray = try MLMultiArray(
            shape: [NSNumber(value: Self.pointers), 1, NSNumber(value: Self.hiddenDim)], dataType: .float16)
        let pointerTarget = pointerArray.dataPointer.assumingMemoryBound(to: Float16.self)
        for slot in 0..<Self.pointers {
            // Newest first; repeat the newest while history is short.
            let source = objectPointers[min(slot, max(0, objectPointers.count - 1))]
            let values = source.dataPointer.assumingMemoryBound(to: Float16.self)
            for index in 0..<Self.hiddenDim { pointerTarget[slot * Self.hiddenDim + index] = values[index] }
        }

        let out = try attention.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "vision_features": MLFeatureValue(multiArray: features.vision),
            "vision_pos": MLFeatureValue(multiArray: features.pos),
            "memory_features": MLFeatureValue(multiArray: memoryFeatures),
            "memory_pos": MLFeatureValue(multiArray: memoryPos),
            "obj_ptrs": MLFeatureValue(multiArray: pointerArray),
        ]))
        guard let conditioned = out.featureValue(for: "conditioned_features")?.multiArrayValue else {
            throw AnalysisError.reader("EdgeTAM memory attention produced no features.")
        }
        return conditioned
    }

    private func decode(conditioned: MLMultiArray, features: Features,
                        prompt: (sparse: MLMultiArray, dense: MLMultiArray),
                        roi: PlayerROI) throws -> Decoded? {
        let out = try decoder.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "image_embeddings": MLFeatureValue(multiArray: conditioned),
            "sparse_prompt_embeddings": MLFeatureValue(multiArray: prompt.sparse),
            "dense_prompt_embeddings": MLFeatureValue(multiArray: prompt.dense),
            "high_res_feat_0": MLFeatureValue(multiArray: features.high0),
            "high_res_feat_1": MLFeatureValue(multiArray: features.high1),
        ]))
        guard let low = out.featureValue(for: "low_res_mask")?.multiArrayValue,
              let high = out.featureValue(for: "high_res_mask")?.multiArrayValue,
              let iou = out.featureValue(for: "iou")?.multiArrayValue,
              let pointer = out.featureValue(for: "obj_ptr")?.multiArrayValue,
              let score = out.featureValue(for: "object_score_logits")?.multiArrayValue else { return nil }
        guard let shape = trace(low, roi: roi) else { return nil }
        let confidence = min(1, max(0, Float(truncating: iou[[0, 0] as [NSNumber]])))
        return Decoded(
            segmentation: PlayerSegmentation(silhouette: shape.silhouette, box: shape.box, confidence: confidence),
            highResMask: high, objectScore: score, pointer: pointer)
    }

    private func remember(features: Features, result: Decoded, conditioning: Bool) throws {
        let out = try memoryEncoder.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "vision_features": MLFeatureValue(multiArray: features.vision),
            "high_res_mask": MLFeatureValue(multiArray: result.highResMask),
            "object_score_logits": MLFeatureValue(multiArray: result.objectScore),
        ]))
        guard let memory = out.featureValue(for: "memory_features")?.multiArrayValue,
              let pos = out.featureValue(for: "memory_pos")?.multiArrayValue else { return }
        // The first conditioning frame is the user's own selection: the only
        // observation known to be the right player. A later reacquisition is a
        // hypothesis that passed its gates, so it joins the recent ring rather
        // than replacing the anchor.
        if conditioning, conditioningMemory == nil {
            conditioningMemory = (memory, pos)
        } else {
            recent.append((memory, pos))
            if recent.count > Self.slots - 1 { recent.removeFirst() }
        }
        objectPointers.insert(result.pointer, at: 0)
        if objectPointers.count > Self.pointers { objectPointers.removeLast() }
    }

    // MARK: - Inputs

    private func crop(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                      roi: PlayerROI) -> CVPixelBuffer? {
        let upright = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let extent = upright.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let crop = CGRect(x: extent.minX + roi.region.minX * extent.width,
                          y: extent.minY + (1 - roi.region.maxY) * extent.height,
                          width: roi.region.width * extent.width,
                          height: roi.region.height * extent.height).intersection(extent)
        guard crop.width > 1, crop.height > 1 else { return nil }
        let side = CGFloat(Self.inputSize)
        let image = upright
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: side / crop.width, y: side / crop.height))
        var output: CVPixelBuffer?
        CVPixelBufferCreate(nil, Self.inputSize, Self.inputSize, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output)
        guard let output else { return nil }
        context.render(image, to: output)
        return output
    }

    /// A box prompt as SAM 2 encodes one internally: two corner points labelled
    /// 2 and 3. The converted prompt encoder ignores its own `boxes` input.
    private func boxPrompt(_ box: CGRect) throws -> (sparse: MLMultiArray, dense: MLMultiArray) {
        let side = Float(Self.inputSize)
        return try prompt(points: [
            (Float(box.minX) * side, Float(box.minY) * side, 2),
            (Float(box.maxX) * side, Float(box.maxY) * side, 3),
        ])
    }

    /// No points at all, every slot marked "not a point". Propagated frames take
    /// the object from memory, so a stale box prompt would only drag the mask
    /// back towards where the player used to be.
    private func emptyPromptEmbeddings() throws -> (sparse: MLMultiArray, dense: MLMultiArray) {
        if let emptyPrompt { return emptyPrompt }
        let built = try prompt(points: [])
        emptyPrompt = built
        return built
    }

    private func prompt(points: [(Float, Float, Float)]) throws -> (sparse: MLMultiArray, dense: MLMultiArray) {
        let coords = try MLMultiArray(shape: [1, 4, 2], dataType: .float16)
        let labels = try MLMultiArray(shape: [1, 4], dataType: .float16)
        for slot in 0..<4 {
            let entry = slot < points.count ? points[slot] : (0, 0, -1)
            coords[[0, NSNumber(value: slot), 0] as [NSNumber]] = NSNumber(value: entry.0)
            coords[[0, NSNumber(value: slot), 1] as [NSNumber]] = NSNumber(value: entry.1)
            labels[[0, NSNumber(value: slot)] as [NSNumber]] = NSNumber(value: entry.2)
        }
        let out = try prompter.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "point_coords": MLFeatureValue(multiArray: coords),
            "point_labels": MLFeatureValue(multiArray: labels),
            "boxes": MLFeatureValue(multiArray: try MLMultiArray(shape: [1, 4], dataType: .float16)),
            "mask_input": MLFeatureValue(multiArray: try MLMultiArray(shape: [1, 1, 256, 256], dataType: .float16)),
        ]))
        guard let sparse = out.featureValue(for: "sparse_embeddings")?.multiArrayValue,
              let dense = out.featureValue(for: "dense_embeddings")?.multiArrayValue else {
            throw AnalysisError.reader("EdgeTAM prompt encoding failed.")
        }
        return (sparse, dense)
    }

    /// Mask logits to a display-space silhouette and box, traced per row so the
    /// result matches every other silhouette in the app.
    private func trace(_ mask: MLMultiArray, roi: PlayerROI) -> (silhouette: PlayerSilhouette, box: CGRect)? {
        let side = Self.maskSize
        guard mask.shape.count == 4, mask.shape[2].intValue == side, mask.shape[3].intValue == side else { return nil }
        let pointer = mask.dataPointer.assumingMemoryBound(to: Float16.self)
        let strides = mask.strides.map(\.intValue)

        var left: [CGPoint] = [], right: [CGPoint] = []
        var minX = side, maxX = 0, minY = side, maxY = 0
        let step = max(1, side / 28)
        var row = 0
        while row < side {
            var lowest = -1, highest = -1
            let line = row * strides[2]
            for column in 0..<side where pointer[line + column * strides[3]] > 0 {
                if lowest < 0 { lowest = column }
                highest = column
            }
            if lowest >= 0 {
                let y = (CGFloat(row) + 0.5) / CGFloat(side)
                left.append(roi.display(CGPoint(x: CGFloat(lowest) / CGFloat(side), y: y)))
                right.append(roi.display(CGPoint(x: CGFloat(highest + 1) / CGFloat(side), y: y)))
                minX = min(minX, lowest); maxX = max(maxX, highest + 1)
                minY = min(minY, row); maxY = max(maxY, row + 1)
            }
            row += step
        }
        guard left.count >= 3, minX < maxX, minY < maxY,
              let silhouette = PlayerSilhouette(left + right.reversed()) else { return nil }
        let box = roi.display(CGRect(x: CGFloat(minX) / CGFloat(side), y: CGFloat(minY) / CGFloat(side),
                                     width: CGFloat(maxX - minX) / CGFloat(side),
                                     height: CGFloat(maxY - minY) / CGFloat(side)))
        return (silhouette, box)
    }
}
