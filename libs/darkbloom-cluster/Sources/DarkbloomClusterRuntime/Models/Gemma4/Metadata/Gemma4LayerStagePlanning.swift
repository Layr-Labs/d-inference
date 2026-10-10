import Foundation

/// CPU metadata only: the two-stage plan of a registered Gemma 4 26B artifact.
/// A stage is built from the original configuration and its range of layers,
/// each layer keeping its index in the whole model, so any cut is structurally
/// valid. The plan's stage descriptor is an identity document, never a
/// configuration a model is constructed from.
enum Gemma4LayerStagePlanning {
    static let namespace = "language_model."
    static let embeddingModule = namespace + "model.embed_tokens"
    static let normModule = namespace + "model.norm"
    /// Stage 0 layer counts a pair may be loaded at, ascending: the four cuts
    /// at a full-attention boundary and three inside a run of sliding layers.
    static let supportedCuts = [6, 8, 10, 12, 15, 18, 24]

    static func layerRoot(_ index: Int) -> String { namespace + "model.layers.\(index)" }

    static func plan(specification: Gemma4RegisteredSpecification, configuration: Data,
                     cut: Int) throws -> QwenLayerStagePlan {
        guard sha256(configuration) == specification.configurationSHA256, supportedCuts.contains(cut) else {
            throw ProbeError("Gemma stage plan requires the registered configuration and one of its cuts")
        }
        let decoded = try Gemma4StageGeometry.decode(configuration,
            defaultQuantizationBits: specification.defaultQuantizationBits)
        let layerCount = Gemma4StageGeometry.layerCount
        let source = sha256(configuration)
        var stages: [QwenLayerStagePlan.Stage] = []
        for (index, range) in [0..<cut, cut..<layerCount].enumerated() {
            let layers = range.map {
                QwenLayerStagePlan.Layer(globalIndex: $0, localIndex: $0 - range.lowerBound,
                    kind: Gemma4StageGeometry.kind(globalLayerIndex: $0))
            }
            // The tied embedding is on both ranks: lookup on rank 0, output head on rank 1.
            let active = ([embeddingModule] + (index == 1 ? [normModule] : [])
                + layers.map { layerRoot($0.localIndex) }).sorted()
            var policy = decoded.quantizationDefaults
            var mappings: [QwenLayerStagePlan.PolicyMapping] = [], excluded: [String] = []
            for path in decoded.quantizationOverrides.keys.sorted() {
                guard let local = localModule(path, range: range, stage: index) else {
                    excluded.append(path); continue
                }
                guard policy[local] == nil, let value = decoded.quantizationOverrides[path] else {
                    throw ProbeError("Gemma stage quantization mapping collision")
                }
                policy[local] = value
                mappings.append(.init(sourcePath: path, localPath: local,
                    policyJSON: String(decoding: try QwenStageMetadata.json(value), as: UTF8.self)))
            }
            let descriptor = try QwenStageMetadata.json([
                "adapter": "gemma4-layer-stage-descriptor-v1", "source_configuration_sha256": source,
                "stage": index, "source_layer_start": range.lowerBound, "source_layer_end": range.upperBound,
                "text_config": ["num_hidden_layers": range.count,
                    "hidden_size": Gemma4StageGeometry.hiddenSize, "vocab_size": Gemma4StageGeometry.vocabularySize,
                    "max_position_embeddings": 262_144, "layer_types": layers.map(\.kind)],
                "quantization": policy,
            ] as [String: Any])
            let identity: [String: Any] = ["adapter": "gemma4-layer-stage-v1",
                "sourceConfigurationSHA256": source, "stage": index,
                "sourceLayerStart": range.lowerBound, "sourceLayerEnd": range.upperBound,
                "constructionConfigurationSHA256": sha256(descriptor), "activeModuleRoots": active,
                "inertModules": [String](), "excludedSourceComponents": ["vision"], "activeMTP": false]
            stages.append(.init(index: index, sourceRange: range, layers: layers,
                constructionConfiguration: descriptor, fingerprint: sha256(try QwenStageMetadata.json(identity)),
                activeModuleRoots: active, inertModules: [],
                quantizationMappings: mappings, excludedQuantizationPaths: excluded))
        }
        let fingerprint = sha256(try QwenStageMetadata.json([
            "adapter": "gemma4-two-layer-stages-v1", "sourceConfigurationSHA256": source,
            "stages": stages.map(\.fingerprint)] as [String: Any]))
        return .init(originalConfiguration: configuration, fingerprint: fingerprint, layers: layerCount,
            interval: Gemma4StageGeometry.fullAttentionInterval, stages: stages)
    }

    /// A module of the whole model as the stage that owns it names it, or nil.
    static func localModule(_ path: String, range: Range<Int>, stage: Int) -> String? {
        let prefix = namespace + "model.layers."
        if path.hasPrefix(prefix) {
            let pieces = path.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
            guard let first = pieces.first, let layer = Int(first), String(layer) == String(first),
                  range.contains(layer), pieces.count > 1, pieces.allSatisfy({ !$0.isEmpty }) else { return nil }
            return layerRoot(layer - range.lowerBound) + "." + pieces.dropFirst().joined(separator: ".")
        }
        if path == embeddingModule || (stage == 1 && path == normModule) { return path }
        return nil
    }

    /// Every text tensor's owners. Names are the artifact's own (already in the
    /// model's layout); a name no stage owns is an error, never a skip. The
    /// three embedding tensors have two owners; every other tensor has one.
    static func parameters(plan: QwenLayerStagePlan,
                           canonicalSourceNames names: [String]) throws -> [QwenLayerStagePlan.Parameter] {
        guard plan.stages.count == 2, Set(names).count == names.count else {
            throw ProbeError("Gemma stage parameter inventory is duplicated")
        }
        var result: [QwenLayerStagePlan.Parameter] = []
        for name in names.sorted() {
            let pieces = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count > 1, !pieces.contains("") else { throw ProbeError("Malformed Gemma tensor name: \(name)") }
            // `layer_scalar`, `router.scale` and `router.per_expert_scale` are
            // parameters of their module; every other suffix names a tensor of one.
            var owners = 0
            for stage in plan.stages {
                let module = pieces.dropLast().joined(separator: ".")
                let local: String?
                if let owned = localModule(module, range: stage.sourceRange, stage: stage.index) {
                    local = owned + "." + pieces[pieces.count - 1]
                } else if let direct = localModule(name, range: stage.sourceRange, stage: stage.index),
                          name != embeddingModule, name != normModule {
                    local = direct
                } else { local = nil }
                if let local {
                    result.append(.init(sourceName: name, stage: stage.index, localName: local)); owners += 1
                }
            }
            let expected = name.hasPrefix(embeddingModule + ".") ? 2 : 1
            guard owners == expected else { throw ProbeError("Gemma tensor has no owning stage: \(name)") }
        }
        guard Set(result.map { "\($0.stage):\($0.localName)" }).count == result.count else {
            throw ProbeError("Gemma stage parameter mapping is not injective")
        }
        return result
    }
}
