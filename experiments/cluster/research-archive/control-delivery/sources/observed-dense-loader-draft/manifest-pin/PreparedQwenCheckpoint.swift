import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Shared descriptor and quantization preparation. No checkpoint tensor payload
/// is materialized here; callers validate their full or selected shapes/budgets
/// before reading. Retaining this value keeps every verified file descriptor open.
struct PreparedQwenCheckpoint {
    let checkpoint: VerifiedCheckpoint
    let canonical: [String: QwenCheckpointTensor]
    let sourceTensorCount: Int
    let expectedShapes: [String: [Int]]

    init(model: any LanguageModel, directory: URL, originalConfiguration: Data,
         policy: BaseConfiguration.PerLayerQuantization, partitionKind: QwenPartitionKind? = nil,
         expectedAggregateSHA256: String? = nil, maximumPayloadBytes: Int? = nil,
         expectedManifestSHA256: String? = nil) throws {
        let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: originalConfiguration,
            expectedAggregateSHA256: expectedAggregateSHA256,
            maximumPayloadBytes: maximumPayloadBytes, expectedManifestSHA256: expectedManifestSHA256)
        let descriptors = try tensorDescriptors(checkpoint: checkpoint)
        var canonicalSources: [String: TensorDescriptor] = [:]
        // Only converted MLX Qwen layouts are supported. This makes per-tensor sanitize equivalent
        // to the ordinary whole-checkpoint sanitize; raw HF norm shifting is deliberately rejected.
        for (source, tensor) in descriptors {
            let names = model.sanitize(weights: [source: MLXArray.zeros([1], dtype: tensor.dtype)]).keys
            guard names.count <= 1 else { throw ProbeError("Unsupported multi-output tensor sanitizer") }
            guard let name = names.first else { continue }
            if name.contains("conv1d.weight") && tensor.shape.last != 1 {
                throw ProbeError("Direct loading requires already-converted MLX conv/norm weights")
            }
            guard canonicalSources[name] == nil else { throw ProbeError("Sanitized tensor name collision: \(name)") }
            canonicalSources[name] = tensor
        }
        let canonical = try composeQwenCheckpointTensors(canonicalSources)
        var policies: [String: BaseConfiguration.Quantization] = [:]
        for (path, _) in model.leafModules().flattened() where canonical[path + ".scales"] != nil {
            guard let quantization = resolveQuantization(path: path, perLayerQuantization: policy,
                aliasing: model as? QuantizationPathAliasing) else {
                throw ProbeError("Missing quantization policy for \(path)")
            }
            if partitionKind != nil && (path.contains(".mlp.") || (partitionKind == .full && path.contains(".layers."))) {
                guard quantization.mode == .affine, quantization.bits == 4, quantization.groupSize == 64 else {
                    throw ProbeError("Partitioned projections require affine W4/G64: \(path)")
                }
            }
            for sourcePath in canonical[path + ".scales"]!.sourceModulePaths {
                guard let sourcePolicy = resolveQuantization(path: sourcePath, perLayerQuantization: policy,
                    aliasing: model as? QuantizationPathAliasing),
                    sourcePolicy.bits == quantization.bits, sourcePolicy.groupSize == quantization.groupSize,
                    sourcePolicy.mode == quantization.mode else {
                    throw ProbeError("Stored gate/up policies cannot be represented by the fused projection: \(path)")
                }
            }
            policies[path] = quantization
        }
        quantize(model: model) { path, _ in policies[path]?.asTuple }
        let expected = Dictionary(uniqueKeysWithValues: model.parameters().flattened().map { ($0.0, $0.1.shape) })
        guard Set(expected.keys) == Set(canonical.keys) else {
            let missing = Set(expected.keys).subtracting(canonical.keys).sorted()
            let extra = Set(canonical.keys).subtracting(expected.keys).sorted()
            throw ProbeError("Direct loader model keys mismatch; missing=\(missing.prefix(8)), extra=\(extra.prefix(8))")
        }
        self.checkpoint = checkpoint
        self.canonical = canonical
        self.sourceTensorCount = canonicalSources.count
        self.expectedShapes = expected
    }
}
