import Foundation

/// CPU metadata only. These descriptors do not construct/evaluate a model,
/// verify checkpoint bytes, allocate weights, or promise pipeline correctness.
/// Public Qwen35DecoderLayer chooses its type from the LOCAL index and interval;
/// therefore both stage starts must retain that phase (Qwen35.swift:1475).
/// This describes the harness's MLXLLM constructQwenModel path, not a VLM factory.
/// Qwen35Configuration (Qwen35MoE.swift:24–34) accepts nested text_config or a
/// flat fallback; either qwen3_5 form constructs a language_model wrapper.
/// qwen3_5_text constructs Qwen35TextModel directly and uses bare model.* paths.
struct QwenLayerStagePlan {
    struct Layer: Codable, Equatable {
        let globalIndex: Int
        let localIndex: Int
        let kind: String
    }
    struct InertModule: Codable, Equatable {
        let path: String
        let responsibility: String
    }
    struct PolicyMapping: Codable, Equatable {
        let sourcePath: String
        let localPath: String
        let policyJSON: String
    }
    struct Stage {
        let index: Int
        let sourceRange: Range<Int>
        let layers: [Layer]
        let constructionConfiguration: Data
        let fingerprint: String
        let activeModuleRoots: [String]
        let inertModules: [InertModule]
        let quantizationMappings: [PolicyMapping]
        let excludedQuantizationPaths: [String]
    }
    struct Parameter: Codable, Equatable {
        let sourceName: String
        let stage: Int
        let localName: String
    }

    let originalConfiguration: Data
    let fingerprint: String
    let layers: Int
    let interval: Int
    let stages: [Stage]
    /// Optional artifact MTP is allowed but is never attached to a stage.
    let excludedSourceComponents = ["vision", "mtp"]
    private let namespace: String
    private let quantizablePaths: Set<String>
    private let requiredParameterNames: Set<String>

    init(configuration: Data, ranges: [Range<Int>], activeMTP: Bool = false) throws {
        guard !activeMTP, configuration.count <= 1_048_576,
            var root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any]
        else { throw ProbeError("Layer stages require bounded configuration and disabled active MTP") }
        let nested = root["text_config"] != nil
        guard let type = root["model_type"] as? String,
            ["qwen3_5", "qwen3_5_text"].contains(type), !nested || type == "qwen3_5",
            !nested || root["text_config"] is [String: Any] else {
            throw ProbeError("Layer stages require a dense Qwen text model or its standard wrapper")
        }
        var text = nested ? root["text_config"] as! [String: Any] : root
        try QwenStageMetadata.validate(text: text, root: root, nested: nested)
        let layers = try QwenStageMetadata.integer(text, "num_hidden_layers", limit: 128)
        let interval = try QwenStageMetadata.integer(text, "full_attention_interval", limit: 128)
        guard interval > 1, ranges.count == 2,
            ranges[0].lowerBound == 0, ranges[0].upperBound == ranges[1].lowerBound,
            ranges[1].upperBound == layers,
            ranges.allSatisfy({ $0.count >= interval && $0.lowerBound % interval == 0 }) else {
            throw ProbeError("Two nonempty contiguous stages must cover all layers at interval phase boundaries")
        }
        let expectedTypes = (0..<layers).map {
            ($0 + 1) % interval == 0 ? "full_attention" : "linear_attention"
        }
        if let declared = text["layer_types"] {
            guard declared as? [String] == expectedTypes else {
                throw ProbeError("Layer policy disagrees with the public Qwen interval constructor")
            }
        }
        let namespace = type == "qwen3_5" ? "language_model." : ""
        let inventory = QwenStageMetadata.moduleInventory(namespace: namespace, layerTypes: expectedTypes, text: text)
        let policy = try QwenStageMetadata.policy(root: root, modules: inventory.modules,
            inputWidths: inventory.inputWidths, namespace: namespace)
        let embedding = namespace + "model.embed_tokens"
        let norm = namespace + "model.norm", head = namespace + "lm_head"
        // Setting zero removes attachment regardless of the process-global MTP flag.
        text["mtp_num_hidden_layers"] = 0
        if var mtp = root["mtplx_mtp"] as? [String: Any] {
            mtp["included"] = false; root["mtplx_mtp"] = mtp
            if !nested { text["mtplx_mtp"] = mtp }
        }
        var stages: [Stage] = []
        for (index, range) in ranges.enumerated() {
            let layerMap = range.map { Layer(globalIndex: $0, localIndex: $0 - range.lowerBound,
                kind: expectedTypes[$0]) }
            let inert = index == 0 ? [
                InertModule(path: norm, responsibility: "Replace before parameter evaluation; stage 0 exports pre-final-norm hidden"),
                InertModule(path: head, responsibility: "Replace before parameter evaluation; stage 0 discards lazy logits"),
            ] : [InertModule(path: embedding,
                responsibility: "Replace before parameter evaluation; incoming residual bypasses embedding; preserve checkpoint activation dtype")]
            let active = (index == 0 ? [embedding] : [norm, head])
                + range.map { namespace + "model.layers.\($0 - range.lowerBound)" }
            var mappedPolicy = policy.defaults
            var mappings: [PolicyMapping] = [], excluded: [String] = []
            for path in policy.overrides.keys.sorted() {
                let value = policy.overrides[path]!
                if let local = QwenStageMetadata.localModule(path, namespace: namespace,
                    range: range, index: index) {
                    guard mappedPolicy[local] == nil else { throw ProbeError("Stage quantization mapping collision") }
                    mappedPolicy[local] = value
                    mappings.append(PolicyMapping(sourcePath: path, localPath: local,
                        policyJSON: String(decoding: try QwenStageMetadata.json(value), as: UTF8.self)))
                } else { excluded.append(path) }
            }
            // Inactive placeholders must not inherit the checkpoint default policy.
            if policy.present { for entry in inert { mappedPolicy[entry.path] = false } }
            var stageText = text
            stageText["num_hidden_layers"] = range.count
            stageText["layer_types"] = layerMap.map(\.kind)
            var stageRoot = root
            if nested { stageRoot["text_config"] = stageText } else { stageRoot = stageText }
            for key in policy.containerKeys { stageRoot[key] = mappedPolicy }
            let data = try QwenStageMetadata.json(stageRoot)
            let identity: [String: Any] = ["adapter": "qwen35-dense-layer-stage-v1",
                "sourceConfigurationSHA256": sha256(configuration), "stage": index,
                "sourceLayerStart": range.lowerBound, "sourceLayerEnd": range.upperBound,
                "constructionConfigurationSHA256": sha256(data), "activeModuleRoots": active.sorted(),
                "inertModules": try JSONSerialization.jsonObject(with: JSONEncoder().encode(inert)),
                "excludedSourceComponents": ["vision", "mtp"], "activeMTP": false]
            stages.append(Stage(index: index, sourceRange: range, layers: layerMap,
                constructionConfiguration: data, fingerprint: sha256(try QwenStageMetadata.json(identity)),
                activeModuleRoots: active.sorted(), inertModules: inert,
                quantizationMappings: mappings, excludedQuantizationPaths: excluded))
        }
        self.originalConfiguration = configuration
        self.layers = layers; self.interval = interval; self.stages = stages
        self.namespace = namespace
        self.quantizablePaths = Set(inventory.inputWidths.keys); self.requiredParameterNames = inventory.required
        self.fingerprint = sha256(try QwenStageMetadata.json([
            "adapter": "qwen35-dense-two-layer-stages-v1", "sourceConfigurationSHA256": sha256(configuration),
            "stages": stages.map(\.fingerprint)]))
    }

    /// Input names must already be sanitized by the original model. No raw-HF
    /// conversion, name guessing, payload selection, fusion or dtype conversion.
    /// MTP/vision are explicit exclusions; every other unknown path is an error.
    func parameter(canonicalSourceName name: String) throws -> Parameter? {
        if QwenStageMetadata.excluded(name, namespace: namespace) { return nil }
        let pieces = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let suffix = pieces.last, !pieces.contains(""),
            requiredParameterNames.contains(name)
                || (["scales", "biases"].contains(suffix)
                    && quantizablePaths.contains(pieces.dropLast().joined(separator: "."))) else {
            throw ProbeError("Unknown canonical dense Qwen parameter: \(name)")
        }
        for stage in stages {
            // A_log/dt_bias are direct parameters, all other suffixes belong to modules.
            let module = ["A_log", "dt_bias"].contains(suffix) ? name : pieces.dropLast().joined(separator: ".")
            if let local = QwenStageMetadata.localModule(module, namespace: namespace,
                range: stage.sourceRange, index: stage.index) {
                return Parameter(sourceName: name, stage: stage.index,
                    localName: ["A_log", "dt_bias"].contains(suffix) ? local : local + "." + suffix)
            }
        }
        throw ProbeError("Canonical parameter has no owning stage: \(name)")
    }

    /// Completeness here covers the pinned model's mandatory parameter names,
    /// not actual shape/dtype/quantization-triplet validity. Config dimensions
    /// and declared group divisibility do not prove descriptor geometry. The
    /// verified stage loader must compare its actual constructed inventory and
    /// verify descriptors, full widths, dtypes and budgets before any read.
    func parameters(canonicalSourceNames names: [String]) throws -> [Parameter] {
        guard Set(names).count == names.count, requiredParameterNames.isSubset(of: Set(names)) else {
            throw ProbeError("Stage parameter inventory is duplicated or misses mandatory model tensors")
        }
        let result = try names.sorted().compactMap { try parameter(canonicalSourceName: $0) }
        guard Set(result.map { "\($0.stage):\($0.localName)" }).count == result.count else {
            throw ProbeError("Stage parameter mapping is not injective")
        }
        return result
    }
}
