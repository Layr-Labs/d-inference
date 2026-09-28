import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Direct reader for converted, split-expert Gemma4Model checkpoints. The
/// registered W8 and mixed W4/W8 artifacts already use this canonical root.
/// Raw fused expert tensors require a different adapter and fail closed here.
func loadDirectGemmaPartition(
    model: any LanguageModel, directory: URL, originalConfiguration: Data,
    policy: BaseConfiguration.PerLayerQuantization, rank: Int, plan: GemmaPartitionPlan
) throws -> DirectShardLoadReceipt {
    guard (0..<2).contains(rank), model is Gemma4Model,
        plan.originalConfiguration == originalConfiguration else {
        throw ProbeError("Gemma direct loading requires a two-rank Gemma4Model wrapper")
    }
    let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: originalConfiguration)
    let descriptors = try tensorDescriptors(checkpoint: checkpoint)
    var canonical: [String: TensorDescriptor] = [:]
    for source in descriptors.keys.sorted() {
        let tensor = descriptors[source]!
        guard !source.hasSuffix(".experts.gate_up_proj"),
            !source.hasSuffix(".experts.down_proj") else {
            throw ProbeError("Gemma direct loading does not support raw multi-output expert sanitization: \(source)")
        }
        let sanitized = model.sanitize(weights: [source: MLXArray.zeros([1], dtype: tensor.dtype)])
        guard sanitized.count <= 1 else { throw ProbeError("Unsupported Gemma multi-output sanitizer") }
        guard let name = sanitized.keys.first else { continue }
        guard source == name, name.hasPrefix("language_model.model.") else {
            throw ProbeError("Gemma direct loading requires canonical converted text names: \(source)")
        }
        guard canonical[name] == nil else { throw ProbeError("Duplicate Gemma canonical tensor: \(name)") }
        canonical[name] = tensor
    }

    var policies: [String: BaseConfiguration.Quantization] = [:]
    for (path, _) in model.leafModules().flattened() where canonical[path + ".scales"] != nil {
        guard let quantization = resolveQuantization(path: path, perLayerQuantization: policy,
            aliasing: model as? QuantizationPathAliasing),
            quantization.mode == .affine, [4, 8].contains(quantization.bits),
            quantization.groupSize == 64 else {
            throw ProbeError("Gemma converted projections require an explicit affine W4/W8 G64 policy: \(path)")
        }
        guard let weight = canonical[path + ".weight"], weight.dtype == .uint32,
            let scales = canonical[path + ".scales"], let biases = canonical[path + ".biases"],
            scales.shape == biases.shape, scales.dtype == biases.dtype,
            [.float16, .bfloat16, .float32].contains(scales.dtype) else {
            throw ProbeError("Malformed Gemma quantized tensor triplet: \(path)")
        }
        policies[path] = quantization
    }
    quantize(model: model) { path, _ in policies[path]?.asTuple }
    let expected = Dictionary(uniqueKeysWithValues: model.parameters().flattened().map { ($0.0, $0.1.shape) })
    guard Set(expected.keys) == Set(canonical.keys) else {
        let missing = Set(expected.keys).subtracting(canonical.keys).sorted()
        let extra = Set(canonical.keys).subtracting(expected.keys).sorted()
        throw ProbeError("Gemma direct loader keys mismatch; missing=\(missing.prefix(8)), extra=\(extra.prefix(8))")
    }
    let convertBF16 = (ProcessInfo.processInfo.environment["DARKBLOOM_BF16_WEIGHTS"] ?? "1") == "1"
    let storageTensors = try canonical.keys.sorted().map { name -> PartitionStorageTensor in
        let tensor = canonical[name]!
        let modulePath = String(name.prefix(through: name.lastIndex(of: ".")!).dropLast())
        let packed = name.hasSuffix(".weight") && policies[modulePath] != nil
        guard (packed ? tensor.dtype == .uint32 : [.float16, .bfloat16, .float32].contains(tensor.dtype)) else {
            throw ProbeError("Unexpected Gemma stored tensor dtype: \(name)")
        }
        return PartitionStorageTensor(name: name, shape: tensor.shape, sourceDType: tensor.dtype,
            loadedDType: convertBF16 && tensor.dtype == .float16 ? .bfloat16 : tensor.dtype,
            byteCount: tensor.byteCount,
            isFeedForward: plan.isFeedForwardTensor(name: name))
    }
    // Commit both rank layouts and payloads from source metadata before any
    // selected tensor is read. Unequal group-aligned widths are intentional.
    let storage = try makePartitionStorage(tensors: storageTensors) { name, shape, selectedRank in
        try plan.selection(name: name, shape: shape, rank: selectedRank)
    }
    guard storage.ranks.count == 2, storage.ranks[rank].rank == rank,
        storage.sourceShardedFFNTensorBytes > 0 else {
        throw ProbeError("Invalid Gemma partition storage commitment")
    }
    for name in canonical.keys.sorted() {
        let selected = try plan.selection(name: name, shape: canonical[name]!.shape, rank: rank)
        guard try selected.resultShape(canonical[name]!.shape) == expected[name] else {
            throw ProbeError("Gemma constructed rank shape differs from its committed selection: \(name)")
        }
    }

    var loadedBytes = 0, largestHostTensorBytes = 0
    for name in canonical.keys.sorted() {
        let tensor = canonical[name]!
        let selection = try plan.selection(name: name, shape: tensor.shape, rank: rank)
        try autoreleasepool {
            // TensorDescriptor reads only the selected rows/groups into one
            // bounded Data allocation and copies them into MLX-owned storage.
            let read = try tensor.read(selection)
            var array = read.array
            if convertBF16 && array.dtype == .float16 { array = array.asType(.bfloat16) }
            eval(array)
            guard array.shape == expected[name] else { throw ProbeError("Gemma selected tensor shape mismatch: \(name)") }
            try model.update(parameters: ModuleParameters.unflattened([name: array]),
                             verify: [.noUnusedKeys, .shapeMismatch])
            loadedBytes += array.nbytes
            largestHostTensorBytes = max(largestHostTensorBytes, read.copiedBytes)
        }
    }
    try checkpoint.checkUnchanged()
    model.freeze()
    eval(model)
    let layout = model.parameters().flattened().map { name, value in
        "\(name):\(value.dtype):\(value.shape)"
    }.sorted().joined(separator: "\n")
    guard sha256(Data(layout.utf8)) == storage.ranks[rank].parameterLayoutSHA256,
        loadedBytes == storage.ranks[rank].loadedTensorBytes else {
        throw ProbeError("Loaded Gemma parameters differ from the committed rank layout or payload")
    }
    return DirectShardLoadReceipt(
        verifiedAggregateSHA256: checkpoint.aggregate, sourceModelTensorBytes: storage.sourceModelTensorBytes,
        sourceFFNTensorBytes: storage.sourceFFNTensorBytes,
        sourceShardedFFNTensorBytes: storage.sourceShardedFFNTensorBytes,
        sourceShardedTensorBytes: storage.sourceShardedTensorBytes, loadedTensorBytes: loadedBytes,
        largestHostTensorBytes: largestHostTensorBytes, tensorCount: expected.count,
        sourceTensorCount: canonical.count, rank: rank, partitionStorage: storage)
}
