import Foundation
import MLX
import MLXLMCommon
import MLXNN

struct DirectShardLoadReceipt: Codable {
    let verifiedAggregateSHA256: String
    let sourceModelTensorBytes: Int
    let sourceFFNTensorBytes: Int
    let sourceShardedFFNTensorBytes: Int
    let sourceShardedTensorBytes: Int
    let loadedTensorBytes: Int
    let largestHostTensorBytes: Int
    let tensorCount: Int
    let sourceTensorCount: Int
    let rank: Int
    let partitionStorage: PartitionStorageCommitment
}

func loadDirectQwenPartition(
    model: any LanguageModel, directory: URL, originalConfiguration: Data,
    policy: BaseConfiguration.PerLayerQuantization, rank: Int, plan: QwenPartitionPlan,
    localCorrectness: Bool = false, expectedAggregateSHA256: String? = nil
) throws -> DirectShardLoadReceipt {
    guard (0..<2).contains(rank) else { throw ProbeError("Invalid direct-loading rank") }
    guard !localCorrectness || (!plan.isMoE && expectedAggregateSHA256 != nil) else {
        throw ProbeError("Local correctness loading requires dense Qwen and an expected aggregate")
    }
    let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: originalConfiguration,
        expectedAggregateSHA256: expectedAggregateSHA256,
        maximumPayloadBytes: localCorrectness ? LocalCorrectnessStorage.maximumManifestPayloadBytes : nil)
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
        if path.contains(".mlp.") || (plan.kind == .full && path.contains(".layers.")) {
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
    var totalBytes = 0, ffnBytes = 0, shardedFFNBytes = 0, shardedBytes = 0, loadedBytes = 0, largest = 0
    let convertBF16 = (ProcessInfo.processInfo.environment["DARKBLOOM_BF16_WEIGHTS"] ?? "1") == "1"
    let storage = try makePartitionStorage(tensors: canonical.map { name, tensor in
        PartitionStorageTensor(name: name, shape: tensor.shape, sourceDType: tensor.dtype,
            loadedDType: convertBF16 && tensor.dtype == .float16 ? .bfloat16 : tensor.dtype,
            byteCount: tensor.byteCount, isFeedForward: name.contains(".mlp."))
    }) { try plan.selection(name: $0, shape: $1, rank: $2) }
    if localCorrectness {
        try LocalCorrectnessStorage.validate(storage: storage, tensors: canonical, plan: plan)
    }
    for name in canonical.keys.sorted() {
        let tensor = canonical[name]!
        totalBytes += tensor.byteCount
        let selection = try plan.selection(name: name, shape: tensor.shape, rank: rank)
        if name.contains(".mlp.") {
            ffnBytes += tensor.byteCount
            if selection != .all { shardedFFNBytes += tensor.byteCount }
        }
        if selection != .all { shardedBytes += tensor.byteCount }
        try autoreleasepool {
            let read = try tensor.read(selection)
            let sanitized = model.sanitize(weights: [name: read.array])
            guard sanitized.count == 1, var array = sanitized[name], array.shape == expected[name] else {
                throw ProbeError("Direct loader produced the wrong shape or key: \(name)")
            }
            if convertBF16 && array.dtype == .float16 { array = array.asType(.bfloat16) }
            eval(array)
            try model.update(parameters: ModuleParameters.unflattened([name: array]),
                             verify: [.noUnusedKeys, .shapeMismatch])
            loadedBytes += read.copiedBytes
            largest = max(largest, read.largestHostTensorBytes)
        }
    }
    try checkpoint.checkUnchanged()
    model.freeze()
    eval(model)
    guard shardedFFNBytes > 0, shardedFFNBytes <= ffnBytes,
        shardedBytes % 2 == 0, loadedBytes == totalBytes - shardedBytes / 2,
        loadedBytes == storage.ranks[rank].loadedTensorBytes,
        modelParameterLayout(model) == storage.ranks[rank].parameterLayoutSHA256 else {
        throw ProbeError("Direct loader's partition byte accounting failed")
    }
    return DirectShardLoadReceipt(
        verifiedAggregateSHA256: checkpoint.aggregate, sourceModelTensorBytes: totalBytes,
        sourceFFNTensorBytes: ffnBytes, sourceShardedFFNTensorBytes: shardedFFNBytes,
        sourceShardedTensorBytes: shardedBytes, loadedTensorBytes: loadedBytes,
        largestHostTensorBytes: largest, tensorCount: expected.count,
        sourceTensorCount: canonicalSources.count, rank: rank, partitionStorage: storage)
}
