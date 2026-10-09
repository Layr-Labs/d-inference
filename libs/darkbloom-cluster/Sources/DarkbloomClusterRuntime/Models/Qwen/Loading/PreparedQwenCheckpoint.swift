import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Shared descriptor and quantization preparation, for descriptors of any
/// origin: verified files or a pinned inventory. No tensor payload is
/// materialized here; callers validate their full or selected shapes/budgets
/// before reading. Descriptors of verified files keep those files open for as
/// long as something holds them, which after preparation is the payload source.
struct PreparedQwenCheckpoint<Stored: QwenStoredTensorDescribing> {
    let canonical: [String: QwenCheckpointTensor<Stored>]
    let sourceTensorCount: Int
    let expectedShapes: [String: [Int]]
    /// The verified transforms of a Prism Hadamard pack, whose packed modules
    /// were installed below; nil for every other artifact.
    let prism: QwenPrismHadamardSource?

    /// This grants no materialization permission; the caller still validates its
    /// source inventory and its independently admitted loading/resource scope.
    init(model: any LanguageModel, descriptors: [String: Stored],
         policy: BaseConfiguration.PerLayerQuantization, partitionKind: QwenPartitionKind? = nil,
         prism: QwenPrismHadamardSource? = nil) throws {
        // A Prism pack cannot be prepared without its verified transforms.
        guard (model is any PrismHadamardLoading) == (prism != nil) else {
            throw ProbeError("A Prism Hadamard pack requires its verified transform metadata, and only it")
        }
        var canonicalSources: [String: Stored] = [:]
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
        if let prism {
            try prism.install(model: model, policies: policies)
        } else {
            quantize(model: model) { path, _ in policies[path]?.asTuple }
        }
        let expected = Dictionary(uniqueKeysWithValues: model.parameters().flattened().map { ($0.0, $0.1.shape) })
        guard Set(expected.keys) == Set(canonical.keys) else {
            let missing = Set(expected.keys).subtracting(canonical.keys).sorted()
            let extra = Set(canonical.keys).subtracting(expected.keys).sorted()
            throw ProbeError("Direct loader model keys mismatch; missing=\(missing.prefix(8)), extra=\(extra.prefix(8))")
        }
        self.canonical = canonical
        self.sourceTensorCount = canonicalSources.count
        self.expectedShapes = expected
        self.prism = prism
    }
}

extension PreparedQwenCheckpoint where Stored == TensorDescriptor {
    /// Reuses a fully verified descriptor owner without a second full-file hash.
    init(model: any LanguageModel, checkpoint: VerifiedCheckpoint, originalConfiguration: Data,
         policy: BaseConfiguration.PerLayerQuantization, partitionKind: QwenPartitionKind? = nil) throws {
        try checkpoint.requireConfiguration(originalConfiguration)
        try checkpoint.checkUnchanged()
        var descriptors = try tensorDescriptors(checkpoint: checkpoint)
        // A Prism pack's sign tensors are checked against its transform file
        // here and are not descriptors of the model; nil for any other model.
        let prism = try QwenPrismHadamardSource.verify(model: model, checkpoint: checkpoint, descriptors: &descriptors)
        try self.init(model: model, descriptors: descriptors,
                      policy: policy, partitionKind: partitionKind, prism: prism)
    }
}
