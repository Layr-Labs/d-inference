import Foundation

/// Identity and geometry admission of the registered Nemotron 3.5 Lightning
/// artifact, into the profile type the stage loader reads. The checks are the
/// registered profile's own, in the same order, with this family's
/// configuration semantics in place of the Qwen text configuration. Like that
/// profile, a successful value proves no payload, device or execution.
enum NemotronRegisteredProfile {
    static func admit(specification spec: QwenDenseRegisteredSpecification, configuration: Data, manifest: Data,
                      canonicalTensors: [QwenDenseCanonicalTensor]) throws -> QwenRegisteredDenseModelProfile {
        struct Manifest: Decodable {
            struct Entry: Decodable { let path: String, sha256: String; let size_bytes: Int }
            let aggregate_sha256: String, file_count: Int, total_size_bytes: Int, files: [Entry]
        }
        let configurationSHA = QwenDenseProfileIdentity.sha256(configuration)
        let declared = try JSONDecoder().decode(Manifest.self, from: manifest)
        guard spec.model == .nemotron35Lightning, configurationSHA == spec.configurationSHA256,
              declared.aggregate_sha256 == spec.artifactSHA256, declared.file_count == spec.manifestFileCount,
              declared.files.count == declared.file_count, Set(declared.files.map(\.path)).count == declared.file_count,
              declared.total_size_bytes == spec.manifestBytes,
              try QwenLongPrefillCheckedBytes.sum(declared.files.map(\.size_bytes)) == spec.manifestBytes,
              declared.files.first(where: { $0.path == "config.json" })?.sha256 == configurationSHA,
              let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            throw QwenDenseProfileError("Pinned registered manifest/configuration semantics differ")
        }
        // What the configuration bytes declare must equal what is pinned here
        // independently of them: block pattern, every width and the vocabulary.
        let declaredGeometry = try NemotronStageMetadata.geometry(root: root)
        let geometry = try NemotronRegisteredLightning.stateGeometry(declaredGeometry, kinds: declaredGeometry.kinds)
        guard declaredGeometry == NemotronRegisteredLightning.geometry,
              geometry == (try spec.expectedGeometry()), declaredGeometry.layers == spec.layers,
              declaredGeometry.hiddenSize == spec.hidden, declaredGeometry.attentionHeads == spec.queryHeads,
              declaredGeometry.keyValueHeads == spec.kvHeads else {
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
        let cut = NemotronRegisteredLightning.planningCut
        let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<cut, cut..<geometry.layers])
        let mappings = try plan.parameters(canonicalSourceNames: tensors.map(\.name))
        guard mappings.count == tensors.count, Set(mappings.map(\.sourceName)) == Set(tensors.map(\.name)) else {
            throw QwenDenseProfileError("Registered descriptor names do not match actual Nemotron Plan inventory")
        }
        let state = try QwenLongPrefillTensorBudget.estimate(geometry: geometry, maximumTokens: 8193, chunkSize: 512)
        guard state.conservativeStateAndBoundaryBytes == spec.namedStateBytes else {
            throw QwenDenseProfileError("Registered independently checked state term vector differs")
        }
        return .init(spec: spec, configuration: configuration, manifest: manifest, tensors: tensors,
                     geometry: geometry, vocabularySize: declaredGeometry.vocabularySize)
    }

    /// The Plan of one of the resident row's cuts; nothing else is planned.
    static func planningPlan(_ profile: QwenRegisteredDenseModelProfile, stageCut: Int?) throws -> QwenLayerStagePlan {
        let cut = stageCut ?? NemotronRegisteredLightning.planningCut
        guard try QwenResidentModelDefinition(model: profile.model).supportedCuts.contains(cut) else {
            throw QwenDenseProfileError("The Nemotron planning scope is its resident cuts")
        }
        return try QwenLayerStagePlan(configuration: profile.configuration, ranges: [0..<cut, cut..<profile.geometry.layers])
    }

    /// The state geometry of the layers a storage role selects: the kinds of
    /// those layers, counted from the Plan, and the registered widths.
    static func stateGeometry(_ profile: QwenRegisteredDenseModelProfile,
                              layers: [QwenLayerStagePlan.Layer]) throws -> QwenLongPrefillBudgetGeometry {
        let kinds = try layers.map { layer -> NemotronStageMetadata.BlockKind in
            guard let kind = NemotronStageMetadata.BlockKind(rawValue: layer.kind) else {
                throw QwenDenseProfileError("Nemotron Plan carries an unknown block kind")
            }
            return kind
        }
        return try NemotronRegisteredLightning.stateGeometry(NemotronRegisteredLightning.geometry, kinds: kinds)
    }
}
