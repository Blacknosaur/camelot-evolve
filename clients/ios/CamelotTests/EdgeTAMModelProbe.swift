import CoreML
import CoreVideo
import XCTest
@testable import Camelot

/// Which converted EdgeTAM model fails, and under which compute units.
///
/// Core ML's error -5 ("invalid input data or broken/unsupported model") says
/// nothing about which stage or why, so each model is exercised on its own with
/// synthetic inputs of exactly the declared shape and dtype.
final class EdgeTAMModelProbe: XCTestCase {
    private func model(_ name: String, units: MLComputeUnits) throws -> MLModel {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
                                "\(name).mlmodelc missing from the bundle")
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    private func array(_ shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float16)
        for index in 0..<array.count { array[index] = 0.1 }
        return array
    }

    private func image() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1024, 1024, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            memset(base, 128, CVPixelBufferGetBytesPerRow(pixels) * 1024)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    func testEachModelRunsAlone() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Core ML models cannot create an inference context on the simulator")
        #endif
        var report: [String] = ["", "=== EDGETAM MODEL PROBE ==="]

        for (label, units) in [("all", MLComputeUnits.all),
                               ("cpuAndGPU", .cpuAndGPU),
                               ("cpuOnly", .cpuOnly)] {
            report.append("--- computeUnits: \(label)")

            // 1. Image encoder.
            var encoded: MLFeatureProvider?
            do {
                let encoder = try model("edgetam_image_encoder", units: units)
                encoded = try encoder.prediction(from: try MLDictionaryFeatureProvider(
                    dictionary: ["image": MLFeatureValue(pixelBuffer: image())]))
                let features = encoded?.featureValue(for: "vision_features")?.multiArrayValue
                report.append("    image_encoder  OK  vision_features \(features?.shape.map(\.intValue) ?? [])")
            } catch {
                report.append("    image_encoder  FAIL \(error.localizedDescription)")
            }

            // 2. Prompt encoder.
            var prompted: MLFeatureProvider?
            do {
                let prompter = try model("edgetam_prompt_encoder", units: units)
                prompted = try prompter.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
                    "point_coords": MLFeatureValue(multiArray: try array([1, 4, 2])),
                    "point_labels": MLFeatureValue(multiArray: try array([1, 4])),
                    "boxes": MLFeatureValue(multiArray: try array([1, 4])),
                    "mask_input": MLFeatureValue(multiArray: try array([1, 1, 256, 256])),
                ]))
                let sparse = prompted?.featureValue(for: "sparse_embeddings")?.multiArrayValue
                report.append("    prompt_encoder OK  sparse \(sparse?.shape.map(\.intValue) ?? [])")
            } catch {
                report.append("    prompt_encoder FAIL \(error.localizedDescription)")
            }

            // 3. Mask decoder, fed from the two above where possible.
            do {
                let decoder = try model("edgetam_mask_decoder", units: units)
                let embeddings = try encoded?.featureValue(for: "vision_features")?.multiArrayValue ?? array([1, 256, 64, 64])
                let high0 = try encoded?.featureValue(for: "high_res_feat_0")?.multiArrayValue ?? array([1, 32, 256, 256])
                let high1 = try encoded?.featureValue(for: "high_res_feat_1")?.multiArrayValue ?? array([1, 64, 128, 128])
                let sparse = try prompted?.featureValue(for: "sparse_embeddings")?.multiArrayValue ?? array([1, 5, 256])
                let dense = try prompted?.featureValue(for: "dense_embeddings")?.multiArrayValue ?? array([1, 256, 64, 64])
                let out = try decoder.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
                    "image_embeddings": MLFeatureValue(multiArray: embeddings),
                    "image_pe": MLFeatureValue(multiArray: try array([1, 256, 64, 64])),
                    "sparse_prompt_embeddings": MLFeatureValue(multiArray: sparse),
                    "dense_prompt_embeddings": MLFeatureValue(multiArray: dense),
                    "high_res_feat_0": MLFeatureValue(multiArray: high0),
                    "high_res_feat_1": MLFeatureValue(multiArray: high1),
                    "multimask_output": MLFeatureValue(multiArray: try array([1])),
                ]))
                let masks = out.featureValue(for: "masks")?.multiArrayValue
                report.append("    mask_decoder   OK  masks \(masks?.shape.map(\.intValue) ?? [])")
            } catch {
                report.append("    mask_decoder   FAIL \(error.localizedDescription)")
            }
        }
        report.append("=== END ===")
        let text = report.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "edgetam-probe"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
