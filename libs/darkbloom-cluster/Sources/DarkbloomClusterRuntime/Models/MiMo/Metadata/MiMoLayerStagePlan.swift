import Foundation

/// CPU metadata only: how the registered 48-layer text model divides into two
/// contiguous layer ranges, each constructed by the product's own
/// `MiMoV26TextModel` from a compact configuration. Nothing here constructs or
/// evaluates a model, reads a tensor or promises pipeline correctness, and
/// nothing here imports MLX: a capability record is described from this file.
/// The product's own configuration type parses each compact configuration,
/// and checks it against its parse of the source, where a stage model is
/// constructed (`productConfiguration(stage:)`).
///
/// A MiMo decoder layer is `x + attention(norm(x))` then `+ mlp(norm(.))`; its
/// attention state belongs to that layer alone and positions come from each
/// layer's own cache offset. So any layer boundary is a cut, and the only
/// thing that crosses it is the residual `[1, tokens, hidden]` in the
/// activation dtype. Stage 0 owns the token embedding and exports the residual
/// after its last layer, before any final norm. Stage 1 takes that residual and
/// owns the final norm and the readout. The embedded MTP heads, the vision
/// tower and the audio encoder belong to no stage: text, greedy, MTP off.
struct MiMoLayerStagePlan {
    struct Layer: Codable, Equatable {
        let globalIndex: Int
        let localIndex: Int
        /// "full" or "sliding".
        let attention: String
        /// "dense" or "moe".
        let feedForward: String
    }
    struct InertModule: Codable, Equatable {
        let path: String
        let responsibility: String
    }
    struct Stage {
        let index: Int
        let sourceRange: Range<Int>
        let layers: [Layer]
        /// The compact configuration's canonical bytes. The stage model is
        /// constructed from the product's parse of exactly these.
        let constructionConfiguration: Data
        let fingerprint: String
        let activeModuleRoots: [String]
        let inertModules: [InertModule]
    }
    struct Parameter: Codable, Equatable {
        let sourceName: String
        let stage: Int
        let localName: String
    }

    static let sourceNamespace = "language_model."
    /// Indexed components no stage loads.
    static let excludedSourcePrefixes = ["language_model.model.mtp.", "vision_tower.", "audio_encoder.",
                                         "speech_embeddings."]

    let originalConfiguration: Data
    let fingerprint: String
    let layers: Int
    let stages: [Stage]

    init(configuration: Data, cut: Int) throws {
        guard (1...1_048_576).contains(configuration.count),
              let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            throw ProbeError("MiMo layer stages require a bounded configuration object")
        }
        // One flag per layer: 1 is a sliding window (or a routed MLP), 0 is not.
        func flags(_ key: String) throws -> [Int] {
            guard let values = root[key] as? [Any] else { throw ProbeError("MiMo configuration lacks \(key)") }
            return try values.map {
                guard let value = BoundedProbeInput.integer($0), (0...1).contains(value) else {
                    throw ProbeError("MiMo configuration has an unknown layer kind in \(key)")
                }
                return value
            }
        }
        let layers = try QwenStageMetadata.integer(root, "num_hidden_layers", limit: 128)
        let pattern = try flags("hybrid_layer_pattern"), frequency = try flags("moe_layer_freq")
        guard layers >= 2, (1..<layers).contains(cut), pattern.count == layers, frequency.count == layers,
              let tied = root["tie_word_embeddings"] as? Bool, !tied, root["dtype"] as? String == "bfloat16" else {
            throw ProbeError("MiMo layer stages require two nonempty contiguous ranges of an untied bfloat16 text model")
        }
        var stages: [Stage] = []
        for (index, range) in [0..<cut, cut..<layers].enumerated() {
            let map = range.map { Layer(globalIndex: $0, localIndex: $0 - range.lowerBound,
                attention: pattern[$0] == 1 ? "sliding" : "full", feedForward: frequency[$0] == 1 ? "moe" : "dense") }
            var fields = root
            fields["num_hidden_layers"] = range.count
            fields["hybrid_layer_pattern"] = range.map { pattern[$0] }
            fields["moe_layer_freq"] = range.map { frequency[$0] }
            // No stage carries the heads, the tower or the encoder, and a
            // compact stage must not describe a checkpoint layout it does not have.
            fields["num_nextn_predict_layers"] = 0
            for key in ["vision_config", "audio_config", "processor_config", "omlx_mimo_mtp",
                        "quantization", "quantization_config"] { fields[key] = nil }
            // Stage 0 has no readout at all: with tied embeddings the class
            // builds no head module, and its logits output is never evaluated.
            fields["tie_word_embeddings"] = index == 0
            let data = try QwenStageMetadata.json(fields)
            let inert = index == 0
                ? [InertModule(path: "model.norm",
                    responsibility: "Placeholder weight; stage 0 exports the residual before any final norm")]
                : [InertModule(path: "model.embed_tokens",
                    responsibility: "Replaced before parameter evaluation; the incoming residual bypasses the embedding")]
            let active = (index == 0 ? ["model.embed_tokens"] : ["model.norm", "lm_head"])
                + range.map { "model.layers.\($0 - range.lowerBound)" }
            struct Identity: Encodable {
                let adapter = "mimo-v26-layer-stage-v1"
                let sourceConfigurationSHA256: String, stage: Int, sourceLayerStart: Int, sourceLayerEnd: Int
                let constructionConfigurationSHA256: String, activeModuleRoots: [String]
                let inertModules: [InertModule], layers: [Layer]
                let excludedSourcePrefixes: [String]
                let activeMTP = false
            }
            let identity = Identity(sourceConfigurationSHA256: sha256(configuration), stage: index,
                sourceLayerStart: range.lowerBound, sourceLayerEnd: range.upperBound,
                constructionConfigurationSHA256: sha256(data), activeModuleRoots: active.sorted(),
                inertModules: inert, layers: map, excludedSourcePrefixes: Self.excludedSourcePrefixes)
            stages.append(Stage(index: index, sourceRange: range, layers: map,
                constructionConfiguration: data, fingerprint: sha256(try canonicalJSONData(identity)),
                activeModuleRoots: active.sorted(), inertModules: inert))
        }
        self.originalConfiguration = configuration
        self.layers = layers; self.stages = stages
        self.fingerprint = sha256(try canonicalJSONData(["mimo-v26-two-layer-stages-v1", sha256(configuration)]
            + stages.map(\.fingerprint)))
    }

    /// The owner of one indexed tensor, or nil for an excluded component. Any
    /// other unknown name is an error: nothing is skipped by guessing.
    func parameter(sourceName name: String) throws -> Parameter? {
        if Self.excludedSourcePrefixes.contains(where: name.hasPrefix) { return nil }
        guard name.hasPrefix(Self.sourceNamespace) else {
            throw ProbeError("Unknown MiMo source tensor: \(name)")
        }
        let local = String(name.dropFirst(Self.sourceNamespace.count))
        let pieces = local.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !pieces.contains("") else { throw ProbeError("Malformed MiMo source tensor name: \(name)") }
        if local.hasPrefix("model.embed_tokens.") { return .init(sourceName: name, stage: 0, localName: local) }
        if local == "model.norm.weight" || local.hasPrefix("lm_head.") {
            return .init(sourceName: name, stage: 1, localName: local)
        }
        guard pieces.count >= 5, pieces[0] == "model", pieces[1] == "layers", let global = Int(pieces[2]),
              String(global) == pieces[2], (0..<layers).contains(global),
              let stage = stages.first(where: { $0.sourceRange.contains(global) }) else {
            throw ProbeError("Unknown MiMo source tensor: \(name)")
        }
        let rest = pieces.dropFirst(3).joined(separator: ".")
        return .init(sourceName: name, stage: stage.index,
            localName: "model.layers.\(global - stage.sourceRange.lowerBound).\(rest)")
    }

    func parameters(sourceNames names: [String]) throws -> [Parameter] {
        guard Set(names).count == names.count else { throw ProbeError("MiMo source tensor inventory is duplicated") }
        let result = try names.sorted().compactMap { try parameter(sourceName: $0) }
        guard Set(result.map { "\($0.stage):\($0.localName)" }).count == result.count else {
            throw ProbeError("MiMo stage parameter mapping is not injective")
        }
        return result
    }

    /// The indexed module a local module's parameters come from.
    func sourceModulePath(stage index: Int, localModulePath path: String) throws -> String {
        guard stages.indices.contains(index) else { throw ProbeError("Unknown MiMo stage") }
        let pieces = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if pieces.count >= 3, pieces[0] == "model", pieces[1] == "layers", let local = Int(pieces[2]),
           stages[index].layers.indices.contains(local) {
            let global = stages[index].sourceRange.lowerBound + local
            return Self.sourceNamespace + (["model", "layers", String(global)] + pieces.dropFirst(3)).joined(separator: ".")
        }
        return Self.sourceNamespace + path
    }
}
