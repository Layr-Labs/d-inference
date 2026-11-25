import Foundation

/// Additional storage only. The target Plan, source conservation receipt and
/// MTP-off generation admission remain unchanged. No request state is implied.
struct QwenResidentMTPPlacement: Encodable {
    let targetPlanSHA256: String
    let ownerRank = 1
    let embeddingSourceOwnerRank = 0
    let embeddingIsExplicitReplica = true
    let generationEnabled = false
    let head: [QwenDenseCanonicalTensor]
    let embedding: [QwenDenseCanonicalTensor]
    let headBytes: Int
    let replicatedEmbeddingBytes: Int
    let additionalTensorBytes: Int
    var tensorsInReadOrder: [QwenDenseCanonicalTensor] { embedding + head }
    static let embeddingRoot = "language_model.model.embed_tokens"

    static func requireOwner(rank: Int) throws {
        guard rank == 1 else { throw ProbeError("Inline MTP storage belongs only to the final rank") }
    }

    static func derive(configuration: Data, plan: QwenLayerStagePlan,
        head: [QwenDenseCanonicalTensor], embedding: [QwenDenseCanonicalTensor]
    ) throws -> Self {
        guard let spec = QwenDenseRegisteredSpecification.all.first(where: { $0.model == .qwen35NineB }),
              sha256(configuration) == spec.configurationSHA256,
              configuration == plan.originalConfiguration, plan.stages.count == 2,
              let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              let text = root["text_config"] as? [String: Any],
              let inline = root["mtplx_mtp"] as? [String: Any],
              inline["included"] as? Bool == true, inline["prefix"] as? String == "mtp.",
              inline["shares_target_embeddings"] as? Bool == true,
              inline["shares_target_lm_head"] as? Bool == true,
              BoundedProbeInput.integer(inline["block_size"]) == 3,
              BoundedProbeInput.integer(text["mtp_num_hidden_layers"]) == 1,
              text["mtp_use_dedicated_embeddings"] as? Bool == false else {
            throw ProbeError("MTP storage requires the exact registered 9B inline shared-head artifact")
        }
        let rebuilt = try QwenLayerStagePlan(configuration: configuration,
            ranges: plan.stages.map(\.sourceRange), activeMTP: false)
        guard rebuilt.fingerprint == plan.fingerprint else { throw ProbeError("MTP target Plan differs") }
        let g = try spec.expectedGeometry(), h = g.hiddenSize
        let middle = try QwenStageMetadata.integer(text, "intermediate_size", limit: 131072)
        let vocabulary = try QwenStageMetadata.integer(text, "vocab_size", limit: 262144)
        var shapes: [String: [Int]] = [:]
        for name in ["pre_fc_norm_hidden", "pre_fc_norm_embedding", "norm",
                     "layers.0.input_layernorm", "layers.0.post_attention_layernorm"] {
            shapes["mtp." + name + ".weight"] = [h]
        }
        for name in ["q_norm", "k_norm"] {
            shapes["mtp.layers.0.self_attn." + name + ".weight"] = [g.headDimension]
        }
        let projections: [(String, Int, Int)] = [
            ("fc", 2*h, h),
            ("layers.0.self_attn.q_proj", h, 2*g.queryHeads*g.headDimension),
            ("layers.0.self_attn.k_proj", h, g.kvHeads*g.headDimension),
            ("layers.0.self_attn.v_proj", h, g.kvHeads*g.headDimension),
            ("layers.0.self_attn.o_proj", g.queryHeads*g.headDimension, h),
            ("layers.0.mlp.gate_proj", h, middle), ("layers.0.mlp.up_proj", h, middle),
            ("layers.0.mlp.down_proj", middle, h)]
        for (name, input, output) in projections {
            shapes["mtp." + name + ".weight"] = [output, input/8]
            for suffix in ["scales", "biases"] { shapes["mtp." + name + "." + suffix] = [output, input/64] }
        }
        let replicaShapes = [embeddingRoot + ".weight": [vocabulary, h/8],
            embeddingRoot + ".scales": [vocabulary, h/64], embeddingRoot + ".biases": [vocabulary, h/64]]
        func validate(_ values: [QwenDenseCanonicalTensor], _ expected: [String: [Int]]) throws {
            guard values.count == expected.count, Set(values.map(\.name)) == Set(expected.keys) else {
                throw ProbeError("MTP storage has missing, extra or duplicate tensors")
            }
            for value in values {
                try value.validate()
                let packed = value.name.hasSuffix(".weight") && value.shape.count == 2
                guard value.shape == expected[value.name],
                      (packed ? value.sourceDType == "U32" : value.sourceDType == "BF16") else {
                    throw ProbeError("MTP storage shape or source dtype differs: \(value.name)")
                }
            }
        }
        try validate(head, shapes); try validate(embedding, replicaShapes)
        let headBytes = try QwenLongPrefillCheckedBytes.sum(head.map(\.byteCount))
        let embeddingBytes = try QwenLongPrefillCheckedBytes.sum(embedding.map(\.byteCount))
        return .init(targetPlanSHA256: plan.fingerprint, head: head.sorted { $0.name < $1.name },
            embedding: embedding.sorted { $0.name < $1.name }, headBytes: headBytes,
            replicatedEmbeddingBytes: embeddingBytes,
            additionalTensorBytes: try QwenLongPrefillCheckedBytes.sum([headBytes, embeddingBytes]))
    }
}
