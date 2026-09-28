import Foundation

struct QwenDenseStageStorageMetadata: Encodable, Equatable {
    let stageIndex: Int, lowerLayer: Int, upperLayer: Int
    let stagePlanFingerprint: String, constructionConfigurationSHA256: String
    let canonicalCount: Int, activeBytes: Int, inertBytes: Int, largestHostTensorBytes: Int
    let fusionReplacementBytes: Int
}

/// An exact model/plan/role-bound metadata requirement, deliberately NOT a
/// loader capability. Future overloads must additionally verify actual payload
/// and descriptors plus independent OS/runtime resource admission. No function
/// in this package converts this value to an execution permit.
struct QwenDenseStorageRequirement: Encodable {
    let model: QwenRegisteredDenseModel, role: QwenDenseStorageRole
    let modelProfileFingerprint: String, configurationSHA256: String, manifestSHA256: String
    let artifactAggregateSHA256: String, canonicalInventorySHA256: String, planFingerprint: String
    let stages: [QwenDenseStageStorageMetadata]
    let manifestPayloadBytes: Int, sourceTensorBytes: Int, canonicalSourceCount: Int
    let selectedActiveBytes: Int, selectedInertBytes: Int, largestHostTensorBytes: Int
    let fusionReplacementBytes: Int
    let namedStateBudget: QwenLongPrefillTensorBudget
    let finalState: QwenDenseFinalStateGeometry
    let partialNamedBufferLedgerBytes: Int
    let fingerprint: String
    let tokenProfile = "long_prefill_8k_v1", promptCount = 8192, chunkSize = 512, outputCount = 1
    let actualPayloadVerificationEstablished = false, actualLoadedInventoryEstablished = false
    let independentResourcePolicyRequired = true, runtimeExecutionAuthorized = false
    let isWholeProcessMemoryBound = false

    private init(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
                 role: QwenDenseStorageRole, stages: [QwenDenseStageStorageMetadata], active: Int,
                 inert: Int, host: Int, fusion: Int, budget: QwenLongPrefillTensorBudget,
                 state: QwenDenseFinalStateGeometry, partial: Int) throws {
        self.model = profile.model; self.role = role; self.modelProfileFingerprint = profile.fingerprint
        self.configurationSHA256 = profile.configurationSHA256; self.manifestSHA256 = profile.manifestSHA256
        self.artifactAggregateSHA256 = profile.artifactAggregateSHA256
        self.canonicalInventorySHA256 = profile.canonicalInventorySHA256; self.planFingerprint = plan.fingerprint
        self.stages = stages; self.manifestPayloadBytes = profile.manifestPayloadBytes
        self.sourceTensorBytes = profile.sourceTensorBytes; self.canonicalSourceCount = profile.canonicalTensors.count
        self.selectedActiveBytes = active; self.selectedInertBytes = inert; self.largestHostTensorBytes = host
        self.fusionReplacementBytes = fusion; self.namedStateBudget = budget; self.finalState = state
        self.partialNamedBufferLedgerBytes = partial
        self.fingerprint = QwenDenseProfileIdentity.fingerprint([
            "qwen-dense-storage-requirement-v1", profile.fingerprint, plan.fingerprint, role.rawValue,
            try QwenDenseProfileIdentity.encodedFingerprint(stages), "active=\(active)", "inert=\(inert)",
            "host=\(host)", "fusionReplacement=\(fusion)", try QwenDenseProfileIdentity.encodedFingerprint(budget),
            try QwenDenseProfileIdentity.encodedFingerprint(state), "partialNamedBytes=\(partial)",
            "tokens=8192/512/1", "executionAuthorized=false", "payloadVerified=false",
        ])
    }

    static func derive(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
                       role: QwenDenseStorageRole) throws -> Self {
        guard plan.originalConfiguration == profile.configuration, plan.stages.count == 2,
              plan.layers == profile.geometry.layers, plan.interval == profile.geometry.fullAttentionInterval else {
            throw QwenDenseProfileError("Storage requirement uses a different model or Plan geometry")
        }
        let rebuilt = try profile.makePlanningPlan(stageCut: plan.stages[0].sourceRange.upperBound)
        guard rebuilt.fingerprint == plan.fingerprint,
              zip(rebuilt.stages, plan.stages).allSatisfy({ pair in
                  pair.0.fingerprint == pair.1.fingerprint && pair.0.constructionConfiguration == pair.1.constructionConfiguration
              }) else { throw QwenDenseProfileError("Storage requirement Plan is not the admitted planning scope") }
        let tensors = Dictionary(uniqueKeysWithValues: profile.canonicalTensors.map { ($0.name, $0) })
        let mappings = try plan.parameters(canonicalSourceNames: profile.canonicalTensors.map(\.name))
        guard mappings.count == tensors.count, Set(mappings.map(\.sourceName)) == Set(tensors.keys) else {
            throw QwenDenseProfileError("Storage mapping does not exactly conserve admitted canonical metadata")
        }
        let sum = QwenLongPrefillCheckedBytes.sum
        var stages: [QwenDenseStageStorageMetadata] = []
        for stage in plan.stages {
            let entries = try mappings.filter { $0.stage == stage.index }.map { mapping -> QwenDenseCanonicalTensor in
                guard let tensor = tensors[mapping.sourceName] else { throw QwenDenseProfileError("Missing canonical owner") }
                return tensor
            }
            guard !entries.isEmpty else { throw QwenDenseProfileError("Empty admitted stage inventory") }
            let fusion = entries.filter { entry in
                let parts = entry.name.split(separator: ".")
                return parts.contains("linear_attn") && parts.count >= 2 &&
                    ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a"].contains(String(parts[parts.count - 2]))
            }
            let recurrentCount = stage.layers.filter { $0.kind == "linear_attention" }.count
            guard fusion.count == (try QwenLongPrefillCheckedBytes.product([recurrentCount, 12])) else {
                throw QwenDenseProfileError("Registered affine GDN fusion triplets differ")
            }
            stages.append(.init(stageIndex: stage.index, lowerLayer: stage.sourceRange.lowerBound,
                upperLayer: stage.sourceRange.upperBound, stagePlanFingerprint: stage.fingerprint,
                constructionConfigurationSHA256: QwenDenseProfileIdentity.sha256(stage.constructionConfiguration),
                canonicalCount: entries.count, activeBytes: try sum(entries.map(\.byteCount)),
                inertBytes: try QwenLongPrefillCheckedBytes.product([stage.index == 0 ? 2 : 1, profile.geometry.hiddenSize, 2]),
                largestHostTensorBytes: entries.map(\.byteCount).max()!, fusionReplacementBytes: try sum(fusion.map(\.byteCount))))
        }
        guard stages.map(\.stageIndex) == [0, 1], try sum(stages.map(\.activeBytes)) == profile.sourceTensorBytes,
              try sum(stages.map(\.canonicalCount)) == profile.canonicalTensors.count else {
            throw QwenDenseProfileError("Selected stages do not conserve exact registered source bytes and names")
        }
        let selected = role.stageIndex.map { [stages[$0]] } ?? stages
        let active = try sum(selected.map(\.activeBytes))
        let inert = (role == .fullReference || role == .fullSolo) ? 0 : try sum(selected.map(\.inertBytes))
        let host = selected.map(\.largestHostTensorBytes).max()!
        let fusion = try sum(selected.map(\.fusionReplacementBytes))
        let layerCount = role.stageIndex.map { plan.stages[$0].layers.count } ?? profile.geometry.layers
        let geometry = try QwenDenseStateBudget.geometry(profile.geometry, layers: layerCount)
        let budget = try QwenLongPrefillTensorBudget.estimate(geometry: geometry, maximumTokens: 8193, chunkSize: 512)
        let state = try QwenDenseStateBudget.finalState(geometry)
        let partial = try sum([active, inert, host, fusion, budget.conservativeStateAndBoundaryBytes])
        return try Self(profile: profile, plan: plan, role: role, stages: stages, active: active, inert: inert,
            host: host, fusion: fusion, budget: budget, state: state, partial: partial)
    }
}
