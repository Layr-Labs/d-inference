import Foundation

/// Pure admission of a Prism Hadamard pack's declaration and its rewriting for
/// one layer stage. Like `QwenStageMetadata`, CPU metadata only: no model is
/// constructed, no transform is decoded and no tensor is read here.
///
/// The pack is the dense Qwen3.5 text model (`base_model_type`) with every
/// packed module declared in `modules`: its path below the text model, the
/// block size of the signed Hadamard transform in front of it and whether it
/// is the embedding (whose transform is applied after the lookup instead).
/// The transforms themselves are in the artifact's `hadamard.json`. The checks
/// below are the ones the pinned SDK makes before it loads such a pack
/// (`PrismHadamardCheckpointConfiguration`), plus a closed set of root keys.
enum QwenPrismStageConfiguration {
    static let rootModelType = "prism_hadamard_qwen35"
    /// What a stage's construction configuration declares instead: the
    /// SDK's public dense constructor, into which the stage loader installs
    /// the packed modules this stage owns.
    static let stageModelType = "qwen3_5"
    static let stageAdapter = "qwen35-prism-hadamard-layer-stage-v1"
    static let planAdapter = "qwen35-prism-hadamard-two-layer-stages-v1"
    static let transformFile = "hadamard.json"
    static let blockSize = 1024, bits = 2, groupSize = 128
    static let embeddingPath = "model.embed_tokens"
    /// The pack is always the wrapped model: its tensors and modules live
    /// under the wrapper's text model.
    static let namespace = "language_model."
    /// The suffix of the tensor that stores a packed module's transform signs.
    static let signsSuffix = "signs"

    private static let rootKeys: Set<String> = ["schema_version", "model_type", "base_model_type", "text_config",
        "quantization", "requires_runtime", "hadamard_config", "tensor_namespace", "gdn_activation_layout",
        "components", "modules", "vision_config", "image_token_id", "video_token_id", "vision_start_token_id",
        "vision_end_token_id", "tie_word_embeddings"]

    struct PackedModule: Equatable {
        /// Below the text model, without the wrapper's namespace.
        let path: String
        let block: Int
        let embedding: Bool

        var object: [String: Any] { ["path": path, "block": block, "embedding": embedding, "dtype": "float16"] }
    }

    struct Declaration {
        /// In the artifact's own order.
        let modules: [PackedModule]

        func packedPaths(namespace: String) -> Set<String> { Set(modules.map { namespace + $0.path }) }

        /// Every module the dense model can pack is packed, except each
        /// gated-delta layer's two small projections, which the pack stores
        /// plain. Anything else is a different pack.
        func requireModules(quantizable: Set<String>, namespace: String) throws {
            let plain = quantizable.filter { $0.hasSuffix(".linear_attn.in_proj_a") || $0.hasSuffix(".linear_attn.in_proj_b") }
            guard packedPaths(namespace: namespace) == quantizable.subtracting(plain) else {
                throw ProbeError("Prism pack declares a different set of packed modules than the dense model has")
            }
        }

        /// The stage's own records, re-indexed to its local layers: the
        /// embedding belongs to stage 0 and the head to stage 1.
        func stageModules(range: Range<Int>, index: Int) -> [PackedModule] {
            modules.compactMap { module in
                QwenStageMetadata.localModule(module.path, namespace: "", range: range, index: index).map {
                    PackedModule(path: $0, block: module.block, embedding: module.embedding)
                }
            }
        }

        /// A stage root as the Plan rewrote it for any dense model, now naming
        /// the dense constructor and carrying only this stage's records.
        func stageRoot(_ root: [String: Any], range: Range<Int>, index: Int) -> [String: Any] {
            var stage = root
            stage["model_type"] = QwenPrismStageConfiguration.stageModelType
            stage["modules"] = stageModules(range: range, index: index).map(\.object)
            return stage
        }
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else { return nil }
        return number.boolValue
    }

    private static func modules(_ value: Any?, stage: Bool) throws -> [PackedModule] {
        guard let records = value as? [[String: Any]], records.count <= 10_000, stage || !records.isEmpty else {
            throw ProbeError("Prism pack requires a bounded list of packed module declarations")
        }
        let modules = try records.map { record -> PackedModule in
            guard Set(record.keys) == ["path", "block", "embedding", "dtype"],
                  let path = record["path"] as? String, (1...256).contains(path.utf8.count),
                  path.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ part in
                      !part.isEmpty && part.utf8.allSatisfy {
                          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
                      }
                  }),
                  BoundedProbeInput.integer(record["block"]) == blockSize,
                  let embedding = boolean(record["embedding"]), embedding == (path == embeddingPath),
                  record["dtype"] as? String == "float16" else {
                throw ProbeError("Prism pack has an invalid packed module declaration")
            }
            return PackedModule(path: path, block: blockSize, embedding: embedding)
        }
        guard Set(modules.map(\.path)).count == modules.count else {
            throw ProbeError("Prism pack declares a packed module twice")
        }
        return modules
    }

    /// Nil for a configuration that is not a Prism pack's; the other checks
    /// then apply unchanged.
    static func admit(root: [String: Any], nested: Bool) throws -> Declaration? {
        guard root["model_type"] as? String == rootModelType else { return nil }
        guard nested, Set(root.keys).isSubset(of: rootKeys), let text = root["text_config"] as? [String: Any],
              BoundedProbeInput.integer(root["schema_version"]) == 2,
              root["base_model_type"] as? String == "qwen3_5",
              root["gdn_activation_layout"] as? String == "grouped",
              root["tensor_namespace"] as? String == "mlx-vlm-qwen3_5",
              root["hadamard_config"] as? String == transformFile,
              let components = root["components"] as? [String: Any], Set(components.keys) == ["text", "vision", "mtp"],
              boolean(components["text"]) == true, boolean(components["vision"]) != nil,
              boolean(components["mtp"]) == false,
              text["mtp_num_hidden_layers"] == nil || BoundedProbeInput.integer(text["mtp_num_hidden_layers"]) == 0,
              // One policy for every packed module and no per-module override.
              let quantization = root["quantization"] as? [String: Any],
              Set(quantization.keys) == ["bits", "group_size", "mode"],
              BoundedProbeInput.integer(quantization["bits"]) == bits,
              BoundedProbeInput.integer(quantization["group_size"]) == groupSize,
              quantization["mode"] as? String == "affine" else {
            throw ProbeError("Unsupported Prism Hadamard architecture or packing declaration")
        }
        let declared = try modules(root["modules"], stage: false)
        guard declared.filter(\.embedding).count == 1 else {
            throw ProbeError("Prism pack must declare exactly one packed embedding")
        }
        return Declaration(modules: declared)
    }

    /// The records a stage's construction configuration carries.
    static func stageModules(constructionConfiguration: Data) throws -> [PackedModule] {
        guard let root = try JSONSerialization.jsonObject(with: constructionConfiguration) as? [String: Any],
              root["model_type"] as? String == stageModelType else {
            throw ProbeError("Prism stage configuration does not name the dense constructor")
        }
        return try modules(root["modules"], stage: true)
    }
}
