import Foundation
import CoreML
import CoreGraphics
import Accelerate
import Vision   // VNImageCropAndScaleOption

enum MLEngineError: Error, CustomStringConvertible {
    case modelMissing(String), badInput(String), badOutput(String)
    var description: String {
        switch self {
        case .modelMissing(let n): return "model not found in bundle: \(n)"
        case .badInput(let n): return "unexpected model input: \(n)"
        case .badOutput(let n): return "unexpected model output: \(n)"
        }
    }
}

extension MLMultiArray {
    /// Copies contents into `[Float]`, converting from whatever storage the model uses.
    func floatArray() -> [Float] {
        let n = count
        var out = [Float](repeating: 0, count: n)
        switch dataType {
        case .float32:
            withUnsafeBytes { raw in
                guard let p = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                out.withUnsafeMutableBufferPointer { cblas_scopy(Int32(n), p, 1, $0.baseAddress!, 1) }
            }
        case .float16:
            withUnsafeBytes { raw in
                guard let p = raw.baseAddress else { return }
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: p),
                                        height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
                out.withUnsafeMutableBufferPointer { dst in
                    var d = vImage_Buffer(data: dst.baseAddress!, height: 1,
                                          width: vImagePixelCount(n), rowBytes: n * 4)
                    vImageConvert_Planar16FtoPlanarF(&src, &d, 0)
                }
            }
        case .double:
            withUnsafeBytes { raw in
                guard let p = raw.baseAddress?.assumingMemoryBound(to: Double.self) else { return }
                for i in 0..<n { out[i] = Float(p[i]) }
            }
        default:
            for i in 0..<n { out[i] = self[i].floatValue }
        }
        return out
    }
}

/// Shared plumbing for a single-input / single-output CoreML embedding model.
class EmbeddingModel: @unchecked Sendable {
    let model: MLModel
    let inputName: String
    let outputName: String
    private(set) var imageConstraint: MLImageConstraint?

    init(url: URL, inputName: String, outputName: String, computeUnits: MLComputeUnits = .all) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: cfg)
        self.inputName = inputName
        self.outputName = outputName

        guard let desc = model.modelDescription.inputDescriptionsByName[inputName] else {
            throw MLEngineError.badInput(inputName)
        }
        imageConstraint = desc.imageConstraint
        guard model.modelDescription.outputDescriptionsByName[outputName] != nil else {
            throw MLEngineError.badOutput(outputName)
        }
    }

    fileprivate func embedding(from out: MLFeatureProvider) throws -> [Float] {
        guard let arr = out.featureValue(for: outputName)?.multiArrayValue else {
            throw MLEngineError.badOutput(outputName)
        }
        var v = arr.floatArray()
        normalize(&v)
        return v
    }
}

/// ArcFace: 112x112 aligned RGB face -> 512-d identity embedding.
final class FaceEmbedder: EmbeddingModel {
    convenience init(url: URL) throws {
        try self.init(url: url, inputName: "image", outputName: "embedding")
    }

    func embed(_ aligned: CGImage) throws -> [Float] {
        guard let c = imageConstraint else { throw MLEngineError.badInput(inputName) }
        let fv = try MLFeatureValue(cgImage: aligned, constraint: c, options: nil)
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: fv])
        return try embedding(from: try model.prediction(from: provider))
    }

    /// Batched inference — materially faster on the Neural Engine than one-at-a-time.
    func embed(batch: [CGImage]) throws -> [[Float]] {
        guard !batch.isEmpty else { return [] }
        guard let c = imageConstraint else { throw MLEngineError.badInput(inputName) }
        let providers: [MLFeatureProvider] = try batch.map {
            let fv = try MLFeatureValue(cgImage: $0, constraint: c, options: nil)
            return try MLDictionaryFeatureProvider(dictionary: [inputName: fv])
        }
        let results = try model.predictions(from: MLArrayBatchProvider(array: providers), options: MLPredictionOptions())
        return try (0..<results.count).map { try embedding(from: results.features(at: $0)) }
    }
}

/// MobileCLIP image tower: 256x256 RGB -> 512-d joint-space embedding.
final class ClipImageEmbedder: EmbeddingModel {
    convenience init(url: URL) throws {
        try self.init(url: url, inputName: "image", outputName: "final_emb_1")
    }

    func embed(_ image: CGImage) throws -> [Float] {
        guard let c = imageConstraint else { throw MLEngineError.badInput(inputName) }
        // Match CLIP's eval transform: resize short side, then centre-crop.
        let fv = try MLFeatureValue(cgImage: image, constraint: c,
                                    options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue])
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: fv])
        return try embedding(from: try model.prediction(from: provider))
    }

    func embed(batch: [CGImage]) throws -> [[Float]] {
        guard !batch.isEmpty else { return [] }
        guard let c = imageConstraint else { throw MLEngineError.badInput(inputName) }
        let providers: [MLFeatureProvider] = try batch.map {
            let fv = try MLFeatureValue(cgImage: $0, constraint: c,
                                        options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue])
            return try MLDictionaryFeatureProvider(dictionary: [inputName: fv])
        }
        let results = try model.predictions(from: MLArrayBatchProvider(array: providers), options: MLPredictionOptions())
        return try (0..<results.count).map { try embedding(from: results.features(at: $0)) }
    }
}

/// MobileCLIP text tower: 77 BPE token ids -> 512-d joint-space embedding.
final class ClipTextEmbedder: EmbeddingModel {
    private let tokenizer: CLIPTokenizer

    init(url: URL, tokenizer: CLIPTokenizer) throws {
        self.tokenizer = tokenizer
        try super.init(url: url, inputName: "text", outputName: "final_emb_1")
    }

    func embed(_ text: String) throws -> [Float] {
        let tokens = tokenizer.tokenize(text)
        let arr = try MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)],
                                   dataType: .int32)
        arr.withUnsafeMutableBytes { raw, _ in
            let p = raw.baseAddress!.assumingMemoryBound(to: Int32.self)
            for (i, t) in tokens.enumerated() { p[i] = t }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: arr)])
        return try embedding(from: try model.prediction(from: provider))
    }
}
