import Foundation

/// Pure identity/geometry admission. It owns retained CPU metadata only. Even a
/// successful value does not prove payload verification, device eligibility,
/// workspace sufficiency, model construction, numerical parity or execution.
struct QwenRegisteredDenseModelProfile {
    let model: QwenRegisteredDenseModel
    let configuration: Data, manifest: Data
    let configurationSHA256: String, manifestSHA256: String, artifactAggregateSHA256: String
    let canonicalInventorySHA256: String, canonicalTensors: [QwenDenseCanonicalTensor]
    let geometry: QwenLongPrefillBudgetGeometry
    let vocabularySize: Int, manifestPayloadBytes: Int, sourceTensorBytes: Int, largestSourceTensorBytes: Int
    let fingerprint: String
    let requiredNativeDType = "bfloat16", requiredBF16ConversionPolicy = true
    let runtimeExecutionAuthorized = false, actualPayloadVerificationEstablished = false
    let providerEligibilityEstablished = false
    let supportedPlanningRoles = QwenDenseStorageRole.allCases
    private let residentPlanningCuts: [Int]?

    private init(spec: QwenDenseRegisteredSpecification, configuration: Data, manifest: Data,
                 tensors: [QwenDenseCanonicalTensor], geometry: QwenLongPrefillBudgetGeometry,
                 residentDefinition: QwenResidentModelDefinition? = nil) {
        self.residentPlanningCuts = residentDefinition?.planningScopeFields.isEmpty == false
            ? residentDefinition?.supportedCuts : nil
        self.model = spec.model; self.configuration = configuration; self.manifest = manifest
        self.configurationSHA256 = spec.configurationSHA256; self.manifestSHA256 = spec.manifestSHA256
        self.artifactAggregateSHA256 = spec.artifactSHA256; self.canonicalInventorySHA256 = spec.inventorySHA256
        self.canonicalTensors = tensors; self.geometry = geometry; self.vocabularySize = 248_320
        self.manifestPayloadBytes = spec.manifestBytes; self.sourceTensorBytes = spec.sourceBytes
        self.largestSourceTensorBytes = spec.largestTensorBytes
        self.fingerprint = QwenDenseProfileIdentity.fingerprint([
            "qwen-registered-dense-metadata-profile-v1", spec.model.rawValue,
            spec.configurationSHA256, spec.manifestSHA256, spec.artifactSHA256, spec.inventorySHA256,
            "manifest=\(spec.manifestBytes)", "source=\(spec.sourceBytes)", "count=\(spec.tensorCount)",
            "largest=\(spec.largestTensorBytes)", "native=bfloat16", "bf16Policy=true", "executionAuthorized=false",
        ] + (residentDefinition?.planningScopeFields ?? []))
    }

    static func admit(configuration: Data, manifest: Data, expectedArtifactAggregateSHA256: String,
                      canonicalTensors: [QwenDenseCanonicalTensor],
                      residentDefinition: QwenResidentModelDefinition? = nil) throws -> Self {
        guard (1...1_048_576).contains(configuration.count), (1...4_194_304).contains(manifest.count),
              (1...2048).contains(canonicalTensors.count) else {
            throw QwenDenseProfileError("Registered metadata exceeds its explicit bounded input scope")
        }
        let configurationSHA = QwenDenseProfileIdentity.sha256(configuration)
        guard let spec = QwenDenseRegisteredSpecification.all.first(where: { $0.configurationSHA256 == configurationSHA }),
              QwenDenseProfileIdentity.sha256(manifest) == spec.manifestSHA256,
              expectedArtifactAggregateSHA256 == spec.artifactSHA256 else {
            throw QwenDenseProfileError("Configuration, manifest or expected artifact is not the exact registered model")
        }
        if let residentDefinition {
            guard residentDefinition.specification.model == spec.model,
                  residentDefinition.specification.configurationSHA256 == spec.configurationSHA256 else {
                throw QwenDenseProfileError("Resident planning definition differs from the registered source")
            }
        }
        struct Manifest: Decodable {
            struct Entry: Decodable { let path: String, sha256: String; let size_bytes: Int }
            let aggregate_sha256: String, file_count: Int, total_size_bytes: Int, files: [Entry]
        }
        let declared = try JSONDecoder().decode(Manifest.self, from: manifest)
        guard declared.aggregate_sha256 == spec.artifactSHA256, declared.file_count == spec.manifestFileCount,
              declared.files.count == declared.file_count, Set(declared.files.map(\.path)).count == declared.file_count,
              declared.total_size_bytes == spec.manifestBytes,
              try QwenLongPrefillCheckedBytes.sum(declared.files.map(\.size_bytes)) == spec.manifestBytes,
              declared.files.first(where: { $0.path == "config.json" })?.sha256 == configurationSHA,
              let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              root["model_type"] as? String == "qwen3_5", let text = root["text_config"] as? [String: Any] else {
            throw QwenDenseProfileError("Pinned registered manifest/configuration semantics differ")
        }
        try QwenStageMetadata.validate(text: text, root: root, nested: true)
        func n(_ key: String) throws -> Int { try QwenStageMetadata.integer(text, key, limit: 1_048_576) }
        let geometry = try QwenLongPrefillBudgetGeometry(layers: n("num_hidden_layers"),
            fullAttentionInterval: n("full_attention_interval"), hiddenSize: n("hidden_size"),
            queryHeads: n("num_attention_heads"), kvHeads: n("num_key_value_heads"), headDimension: n("head_dim"),
            linearKeyHeads: n("linear_num_key_heads"), linearValueHeads: n("linear_num_value_heads"),
            linearKeyDimension: n("linear_key_head_dim"), linearValueDimension: n("linear_value_head_dim"),
            convolutionKernel: n("linear_conv_kernel_dim"))
        guard geometry == (try spec.expectedGeometry()), try n("vocab_size") == 248_320,
              try n("max_position_embeddings") >= 8193 else {
            throw QwenDenseProfileError("Registered geometry differs from independently pinned expectations")
        }
        for tensor in canonicalTensors { try tensor.validate() }
        let tensors = canonicalTensors.sorted { $0.name < $1.name }
        guard tensors.count == spec.tensorCount, Set(tensors.map(\.name)).count == tensors.count,
              QwenDenseProfileIdentity.fingerprint(tensors.map(\.identity)) == spec.inventorySHA256,
              try QwenLongPrefillCheckedBytes.sum(tensors.map(\.byteCount)) == spec.sourceBytes,
              tensors.map(\.byteCount).max() == spec.largestTensorBytes else {
            throw QwenDenseProfileError("Canonical registered inventory differs in name, shape, source dtype or bytes")
        }
        let plan = try QwenLayerStagePlan(configuration: configuration,
            ranges: [0..<(geometry.layers / 2), (geometry.layers / 2)..<geometry.layers])
        let mappings = try plan.parameters(canonicalSourceNames: tensors.map(\.name))
        guard mappings.count == tensors.count, Set(mappings.map(\.sourceName)) == Set(tensors.map(\.name)) else {
            throw QwenDenseProfileError("Registered descriptor names do not match actual dense Plan inventory")
        }
        let state = try QwenLongPrefillTensorBudget.estimate(geometry: geometry, maximumTokens: 8193, chunkSize: 512)
        guard state.conservativeStateAndBoundaryBytes == spec.namedStateBytes else {
            throw QwenDenseProfileError("Registered independently checked state term vector differs")
        }
        return Self(spec: spec, configuration: configuration, manifest: manifest, tensors: tensors,
            geometry: geometry, residentDefinition: residentDefinition)
    }

    func makePlanningPlan(stageCut: Int? = nil) throws -> QwenLayerStagePlan {
        let cut = stageCut ?? geometry.layers / 2
        let legal = try QwenLayerStageCandidates.structuralCuts(layerCount: geometry.layers,
            fullAttentionInterval: geometry.fullAttentionInterval)
        guard legal.contains(cut), model == .qwen35NineB || cut == 32 || residentPlanningCuts?.contains(cut) == true else {
            throw QwenDenseProfileError("The initial27B planning scope is explicit32/32; legacy9B legal cuts are preserved")
        }
        return try QwenLayerStagePlan(configuration: configuration, ranges: [0..<cut, cut..<geometry.layers])
    }
}
