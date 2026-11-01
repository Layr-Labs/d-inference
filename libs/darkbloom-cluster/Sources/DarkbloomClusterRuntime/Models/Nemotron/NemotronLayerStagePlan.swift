import Foundation

/// The two-stage Plan of a Nemotron configuration, in the Plan type every
/// stage loader, session and agreement already reads. CPU metadata only.
///
/// A stage is the pinned `NemotronH35Model` constructed over a slice of
/// `layers_block_type`: the pinned constructor takes each block's kind from
/// that list, so any slice is a valid model and no cut has to preserve a
/// phase. Stage 0 keeps the embedding; stage 1 keeps `norm_f` and the head.
/// The artifact's `mtp.` head belongs to neither.
enum NemotronLayerStagePlan {
    /// What `QwenLayerStagePlan.parameter(canonicalSourceName:)` needs to
    /// place a Nemotron tensor: the names a complete artifact carries.
    struct Names {
        let quantizablePaths: Set<String>
        let requiredParameterNames: Set<String>

        /// Nil for the artifact's speculative head; every other unknown name is an error.
        func parameter(_ name: String, stages: [QwenLayerStagePlan.Stage]) throws -> QwenLayerStagePlan.Parameter? {
            if NemotronStageMetadata.excluded(name) { return nil }
            let pieces = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard let suffix = pieces.last, !pieces.contains(""),
                  requiredParameterNames.contains(name)
                    || (["scales", "biases"].contains(suffix)
                        && quantizablePaths.contains(pieces.dropLast().joined(separator: "."))) else {
                throw ProbeError("Unknown canonical Nemotron parameter: \(name)")
            }
            for stage in stages {
                if let local = NemotronStageMetadata.localPath(name, range: stage.sourceRange, index: stage.index) {
                    return .init(sourceName: name, stage: stage.index, localName: local)
                }
            }
            throw ProbeError("Canonical parameter has no owning stage: \(name)")
        }
    }

    /// What a Plan is assembled from; `QwenLayerStagePlan`'s initializer stores it.
    struct Parts {
        let names: Names
        let fingerprint: String
        let layers: Int
        let stages: [QwenLayerStagePlan.Stage]
    }

    static func make(configuration: Data, root: [String: Any], ranges: [Range<Int>]) throws -> Parts {
        let geometry = try NemotronStageMetadata.geometry(root: root)
        let layers = geometry.layers
        guard ranges.count == 2, ranges[0].lowerBound == 0, ranges[0].upperBound == ranges[1].lowerBound,
              ranges[1].upperBound == layers,
              NemotronStageMetadata.structuralCuts(geometry.kinds).contains(ranges[0].upperBound) else {
            throw ProbeError("Two contiguous Nemotron stages must cover all layers, each with an attention block, cut beside an expert block")
        }
        let inventory = NemotronStageMetadata.moduleInventory(geometry)
        let policy = try QwenStageMetadata.policy(root: root, modules: inventory.modules,
            inputWidths: inventory.inputWidths, namespace: "")
        let embedding = NemotronStageMetadata.embeddingPath
        let norm = NemotronStageMetadata.finalNormPath, head = NemotronStageMetadata.headPath
        var base = root
        // The stage constructor must neither advertise nor attach the
        // artifact's speculative head, whatever a caller's process enables.
        base["num_nextn_predict_layers"] = 0
        base["mtp_layers_block_type"] = [String]()
        base["darkbloom_embedded_mtp"] = nil
        var stages: [QwenLayerStagePlan.Stage] = []
        for (index, range) in ranges.enumerated() {
            let layerMap = range.map {
                QwenLayerStagePlan.Layer(globalIndex: $0, localIndex: $0 - range.lowerBound,
                                         kind: geometry.kinds[$0].rawValue)
            }
            let inert = index == 0 ? [
                QwenLayerStagePlan.InertModule(path: norm,
                    responsibility: "Replace before parameter evaluation; stage 0 exports the residual before norm_f"),
                QwenLayerStagePlan.InertModule(path: head,
                    responsibility: "Replace before parameter evaluation; stage 0 never computes logits"),
            ] : [QwenLayerStagePlan.InertModule(path: embedding,
                    responsibility: "Replace before parameter evaluation; the incoming residual replaces the token lookup; preserve checkpoint activation dtype")]
            let active = (index == 0 ? [embedding] : [norm, head])
                + range.map { NemotronStageMetadata.layerPrefix + "\($0 - range.lowerBound)" }
            var mappedPolicy = policy.defaults
            var mappings: [QwenLayerStagePlan.PolicyMapping] = [], excluded: [String] = []
            for path in policy.overrides.keys.sorted() {
                let value = policy.overrides[path]!
                if let local = NemotronStageMetadata.localPath(path, range: range, index: index) {
                    guard mappedPolicy[local] == nil else { throw ProbeError("Stage quantization mapping collision") }
                    mappedPolicy[local] = value
                    mappings.append(.init(sourcePath: path, localPath: local,
                        policyJSON: String(decoding: try QwenStageMetadata.json(value), as: UTF8.self)))
                } else { excluded.append(path) }
            }
            // Inactive placeholders must not inherit the checkpoint default policy.
            if policy.present { for entry in inert { mappedPolicy[entry.path] = false } }
            var stageRoot = base
            stageRoot["num_hidden_layers"] = range.count
            stageRoot["layers_block_type"] = layerMap.map(\.kind)
            for key in policy.containerKeys { stageRoot[key] = mappedPolicy }
            let data = try QwenStageMetadata.json(stageRoot)
            let identity: [String: Any] = ["adapter": NemotronStageMetadata.stageAdapter,
                "sourceConfigurationSHA256": sha256(configuration), "stage": index,
                "sourceLayerStart": range.lowerBound, "sourceLayerEnd": range.upperBound,
                "constructionConfigurationSHA256": sha256(data), "activeModuleRoots": active.sorted(),
                "inertModules": try JSONSerialization.jsonObject(with: JSONEncoder().encode(inert)),
                "layerKinds": layerMap.map(\.kind),
                "excludedSourceComponents": ["mtp"], "activeMTP": false]
            stages.append(.init(index: index, sourceRange: range, layers: layerMap,
                constructionConfiguration: data, fingerprint: sha256(try QwenStageMetadata.json(identity)),
                activeModuleRoots: active.sorted(), inertModules: inert,
                quantizationMappings: mappings, excludedQuantizationPaths: excluded))
        }
        let fingerprint = sha256(try QwenStageMetadata.json([
            "adapter": NemotronStageMetadata.planAdapter, "sourceConfigurationSHA256": sha256(configuration),
            "stages": stages.map(\.fingerprint)]))
        return Parts(names: .init(quantizablePaths: Set(inventory.inputWidths.keys),
                requiredParameterNames: inventory.required),
            fingerprint: fingerprint, layers: layers, stages: stages)
    }
}
