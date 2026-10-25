import Foundation
import MLX

/// The exact inline assistant is replicated; the target embedding, norm and
/// genuinely sharded vocabulary head are borrowed. Only verified descriptors
/// enter this inventory, and no weight bytes are read while deriving it. Its
/// shapes follow the row's own configuration (`Head`): one dense decoder layer
/// under `mtp.`, as the 9B's and the 27B's artifacts ship it.
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
        guard QwenTensorParallelMTPPolicy.models.contains(specification.model),
              source.metadata.profile.model == specification.model,
              checkpoint.aggregate == specification.artifactSHA256,
              checkpoint.configurationSHA256 == specification.configurationSHA256,
              checkpoint.verifiedManifestSHA256 == specification.manifestSHA256,
              sha256(configuration) == specification.configurationSHA256 else {
            throw ProbeError("Qwen TP assistant differs from its exact registered artifact")
        }
        try checkpoint.requireConfiguration(configuration)
        let head = try Head(configuration: configuration)
        let descriptors = try tensorDescriptors(checkpoint: checkpoint).filter { $0.key.hasPrefix("mtp.") }
        let footprint = try Self.footprint(tensors: descriptors.mapValues { ($0.shape, $0.dtype, $0.byteCount) },
            specification: specification, configuration: configuration, allocationBound: allocationBound)
        entries = head.expectedShapes.keys.sorted().map {
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
                          specification: QwenDenseRegisteredSpecification, configuration: Data,
                          allocationBound: (Int) throws -> Int) throws -> Footprint {
        guard QwenTensorParallelMTPPolicy.models.contains(specification.model),
              sha256(configuration) == specification.configurationSHA256 else {
            throw ProbeError("Tensor assistant inventory requires a registered row's own assistant and configuration")
        }
        let head = try Head(configuration: configuration)
        try validateStoredTensors(tensors, head: head)
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func bound(_ bytes: Int) throws -> Int {
            let result = try allocationBound(bytes)
            guard result >= bytes else { throw ProbeError("Qwen TP assistant allocator bound is too small") }
            return result
        }
        let ordered = head.expectedShapes.keys.sorted()
        let storage = try sum(ordered.map { tensors[$0]!.byteCount })
        guard ordered.count == 31, ordered.count == tensors.count else {
            throw ProbeError("Qwen TP assistant stored tensor count differs")
        }
        let sourceAllocations = try ordered.map { try bound(tensors[$0]!.byteCount) }
        let allocated = try sum(sourceAllocations)
        let largest = ordered.map { tensors[$0]!.byteCount }.max()!
        // Two complete FP32 matrix copies cover lazy construction and
        // quantization intermediates; exact packed source stays additive.
        let matrices = try head.linearDimensions.values.map { input, output in try bound(product([input, output, 4])) }
        let norms = try head.expectedShapes.filter { $0.value.count != 2 }.values.map { try bound(product($0 + [4])) }
        let construction = try sum(matrices.map { try product([2, $0]) } + norms)
        let load = try sum([allocated, construction, largest, largest,
            CheckpointAlignedReadPlan.maximumScratchAllocationBytes])
        // The schema tag keeps its first name: a pinned Qwen27 inventory is unchanged.
        let fingerprint = sha256(Data((["qwen27-tp-mtp-inventory-v1", specification.artifactSHA256,
            specification.configurationSHA256] + ordered.map {
                "\(String($0.dropFirst("mtp.".count)))|\(tensors[$0]!.shape)|\(tensors[$0]!.byteCount)"
            }).joined(separator: "\n").utf8))
        return .init(fingerprint: fingerprint, storageBytes: storage, allocationBytes: allocated,
            largestTensorBytes: largest, constructionBytes: construction, loadBytes: load,
            largestAllocationBytes: (sourceAllocations + matrices + norms).max()!)
    }

    static func validateStoredTensors(_ tensors: [String: (shape: [Int], dtype: DType, byteCount: Int)],
                                      head: Head) throws {
        let expected = head.expectedShapes
        guard Set(tensors.keys) == Set(expected.keys) else {
            throw ProbeError("Qwen TP assistant has missing or unexpected source tensors")
        }
        for (name, shape) in expected {
            let value = tensors[name]!
            let packed = name.hasSuffix(".weight") && head.linearDimensions[String(name.dropLast(".weight".count))] != nil
            let dtype: DType = packed ? .uint32 : .bfloat16
            guard value.shape == shape, value.dtype == dtype,
                  value.byteCount == (try QwenLongPrefillCheckedBytes.product(shape + [dtype.size])) else {
                throw ProbeError("Qwen TP assistant source shape or dtype differs")
            }
        }
    }

    /// The one-layer inline head a row's configuration describes: its affine
    /// projections' original input/output channels (not tensor-shard
    /// dimensions; the head predicts proposals on both ranks) and every
    /// stored shape, in the head's own packing (`mtplx_mtp_quantization`).
    struct Head {
        let linearDimensions: [String: (Int, Int)]
        let expectedShapes: [String: [Int]]

        init(configuration: Data) throws {
            guard let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
                  let text = root["text_config"] as? [String: Any],
                  let packing = (root["mtplx_mtp_quantization"] ?? root["quantization"]) as? [String: Any],
                  let group = packing["group_size"] as? Int, let bits = packing["bits"] as? Int,
                  (packing["mode"] as? String ?? "affine") == "affine", group == 64, bits == 4,
                  text["mtp_num_hidden_layers"] as? Int == 1, text["attn_output_gate"] as? Bool == true,
                  let h = text["hidden_size"] as? Int, let i = text["intermediate_size"] as? Int,
                  let hq = text["num_attention_heads"] as? Int, let hkv = text["num_key_value_heads"] as? Int,
                  let d = text["head_dim"] as? Int, [h, i, hq, hkv, d].allSatisfy({ $0 > 0 }) else {
                throw ProbeError("Qwen TP assistant needs one dense affine4/group64 inline head layer")
            }
            linearDimensions = [
                "mtp.fc": (2 * h, h),
                "mtp.layers.0.mlp.down_proj": (i, h),
                "mtp.layers.0.mlp.gate_proj": (h, i),
                "mtp.layers.0.mlp.up_proj": (h, i),
                "mtp.layers.0.self_attn.q_proj": (h, 2 * hq * d),
                "mtp.layers.0.self_attn.k_proj": (h, hkv * d),
                "mtp.layers.0.self_attn.v_proj": (h, hkv * d),
                "mtp.layers.0.self_attn.o_proj": (hq * d, h),
            ]
            var shapes: [String: [Int]] = [:]
            for (path, (input, output)) in linearDimensions {
                shapes[path + ".weight"] = [output, input * bits / 32]
                shapes[path + ".scales"] = [output, input / group]
                shapes[path + ".biases"] = [output, input / group]
            }
            for path in ["mtp.pre_fc_norm_embedding", "mtp.pre_fc_norm_hidden", "mtp.norm",
                         "mtp.layers.0.input_layernorm", "mtp.layers.0.post_attention_layernorm"] {
                shapes[path + ".weight"] = [h]
            }
            for path in ["mtp.layers.0.self_attn.q_norm", "mtp.layers.0.self_attn.k_norm"] {
                shapes[path + ".weight"] = [d]
            }
            expectedShapes = shapes
        }
    }
}
