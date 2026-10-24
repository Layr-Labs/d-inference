import Foundation
import MLX

/// The exact inline assistant is replicated; the target embedding, norm and
/// genuinely sharded vocabulary head are borrowed. Only verified descriptors
/// enter this inventory, and no weight bytes are read while deriving it.
struct QwenTensorParallelMTPInventory {
    struct Entry {
        let name: String
        let descriptor: TensorDescriptor
    }
    let entries: [Entry]
    let artifactSHA256: String
    let configurationSHA256: String
    let fingerprint: String
    let storageBytes: Int
    let allocationBytes: Int
    let largestTensorBytes: Int
    /// Bounds the temporary floating model and quantization graph before the
    /// exact packed parameters replace it. This is LOAD-only, never residency.
    let constructionBytes: Int
    let loadBytes: Int
    let largestAllocationBytes: Int

    init(source: QwenResidentLocalSource, configuration: Data,
         specification: QwenDenseRegisteredSpecification,
         allocationBound: (Int) throws -> Int) throws {
        let checkpoint = source.payload.checkpoint
        guard specification.model == .qwen38TwentySevenB,
              source.metadata.profile.model == specification.model,
              checkpoint.aggregate == specification.artifactSHA256,
              checkpoint.configurationSHA256 == specification.configurationSHA256,
              checkpoint.verifiedManifestSHA256 == specification.manifestSHA256,
              sha256(configuration) == specification.configurationSHA256 else {
            throw ProbeError("Qwen TP assistant differs from its exact registered artifact")
        }
        try checkpoint.requireConfiguration(configuration)
        let descriptors = try tensorDescriptors(checkpoint: checkpoint).filter { $0.key.hasPrefix("mtp.") }
        let footprint = try Self.footprint(tensors: descriptors.mapValues { ($0.shape, $0.dtype, $0.byteCount) },
            specification: specification, allocationBound: allocationBound)
        entries = Self.expectedShapes.keys.sorted().map {
            .init(name: String($0.dropFirst("mtp.".count)), descriptor: descriptors[$0]!)
        }
        artifactSHA256 = checkpoint.aggregate; configurationSHA256 = specification.configurationSHA256
        fingerprint = footprint.fingerprint; storageBytes = footprint.storageBytes
        allocationBytes = footprint.allocationBytes; largestTensorBytes = footprint.largestTensorBytes
        constructionBytes = footprint.constructionBytes; loadBytes = footprint.loadBytes
        largestAllocationBytes = footprint.largestAllocationBytes
        try checkpoint.checkUnchanged()
    }

    /// Shared by the metadata helper and verified native inventory. Header
    /// shape/type/byte validation and every allocator rounding happen here.
    struct Footprint {
        let fingerprint: String
        let storageBytes: Int
        let allocationBytes: Int
        let largestTensorBytes: Int
        let constructionBytes: Int
        let loadBytes: Int
        let largestAllocationBytes: Int
    }

    static func footprint(tensors: [String: (shape: [Int], dtype: DType, byteCount: Int)],
                          specification: QwenDenseRegisteredSpecification,
                          allocationBound: (Int) throws -> Int) throws -> Footprint {
        guard specification.model == .qwen38TwentySevenB else {
            throw ProbeError("Tensor assistant inventory requires the exact registered Qwen27 model")
        }
        try validateStoredTensors(tensors)
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func bound(_ bytes: Int) throws -> Int {
            let result = try allocationBound(bytes)
            guard result >= bytes else { throw ProbeError("Qwen TP assistant allocator bound is too small") }
            return result
        }
        let ordered = expectedShapes.keys.sorted()
        let storage = try sum(ordered.map { tensors[$0]!.byteCount })
        guard ordered.count == 31, storage == 238_930_944 else {
            throw ProbeError("Qwen TP assistant stored byte count differs")
        }
        let sourceAllocations = try ordered.map { try bound(tensors[$0]!.byteCount) }
        let allocated = try sum(sourceAllocations)
        let largest = ordered.map { tensors[$0]!.byteCount }.max()!
        // Two complete FP32 matrix copies cover lazy construction and
        // quantization intermediates; exact packed source stays additive.
        let matrices = try linearDimensions.values.map { input, output in try bound(product([input, output, 4])) }
        let norms = try expectedShapes.filter { $0.value.count != 2 }.values.map { try bound(product($0 + [4])) }
        let construction = try sum(matrices.map { try product([2, $0]) } + norms)
        let load = try sum([allocated, construction, largest, largest,
            CheckpointAlignedReadPlan.maximumScratchAllocationBytes])
        let fingerprint = sha256(Data((["qwen27-tp-mtp-inventory-v1", specification.artifactSHA256,
            specification.configurationSHA256] + ordered.map {
                "\(String($0.dropFirst("mtp.".count)))|\(tensors[$0]!.shape)|\(tensors[$0]!.byteCount)"
            }).joined(separator: "\n").utf8))
        return .init(fingerprint: fingerprint, storageBytes: storage, allocationBytes: allocated,
            largestTensorBytes: largest, constructionBytes: construction, loadBytes: load,
            largestAllocationBytes: (sourceAllocations + matrices + norms).max()!)
    }

    static func validateStoredTensors(_ tensors: [String: (shape: [Int], dtype: DType, byteCount: Int)]) throws {
        let expected = expectedShapes
        guard Set(tensors.keys) == Set(expected.keys) else {
            throw ProbeError("Qwen TP assistant has missing or unexpected source tensors")
        }
        for (name, shape) in expected {
            let value = tensors[name]!
            let packed = name.hasSuffix(".weight") && linearDimensions[String(name.dropLast(".weight".count))] != nil
            let dtype: DType = packed ? .uint32 : .bfloat16
            guard value.shape == shape, value.dtype == dtype,
                  value.byteCount == (try QwenLongPrefillCheckedBytes.product(shape + [dtype.size])) else {
                throw ProbeError("Qwen TP assistant source shape or dtype differs")
            }
        }
    }

    /// Input/output channels of the original affine4/group64 assistant, not
    /// tensor-shard dimensions. The head predicts proposals on both ranks.
    static let linearDimensions: [String: (Int, Int)] = [
        "mtp.fc": (10_240, 5_120),
        "mtp.layers.0.mlp.down_proj": (17_408, 5_120),
        "mtp.layers.0.mlp.gate_proj": (5_120, 17_408),
        "mtp.layers.0.mlp.up_proj": (5_120, 17_408),
        "mtp.layers.0.self_attn.q_proj": (5_120, 12_288),
        "mtp.layers.0.self_attn.k_proj": (5_120, 1_024),
        "mtp.layers.0.self_attn.v_proj": (5_120, 1_024),
        "mtp.layers.0.self_attn.o_proj": (6_144, 5_120),
    ]
    static var expectedShapes: [String: [Int]] {
        var result: [String: [Int]] = [:]
        for (path, (input, output)) in linearDimensions {
            result[path + ".weight"] = [output, input / 8]
            result[path + ".scales"] = [output, input / 64]
            result[path + ".biases"] = [output, input / 64]
        }
        for path in ["mtp.pre_fc_norm_embedding", "mtp.pre_fc_norm_hidden", "mtp.norm",
                     "mtp.layers.0.input_layernorm", "mtp.layers.0.post_attention_layernorm"] {
            result[path + ".weight"] = [5_120]
        }
        for path in ["mtp.layers.0.self_attn.q_norm", "mtp.layers.0.self_attn.k_norm"] {
            result[path + ".weight"] = [256]
        }
        return result
    }
}
