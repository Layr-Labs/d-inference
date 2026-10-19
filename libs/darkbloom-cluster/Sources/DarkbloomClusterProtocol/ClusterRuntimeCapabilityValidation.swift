import Foundation

enum ClusterRuntimeCapabilityValidation {
    static func check(_ value: ClusterRuntimeCapability) throws {
        guard let adapter = ClusterRuntimeAdapter(rawValue: value.adapterID),
              value.adapterVersion == adapter.version,
              adapter.registeredProfiles.contains(where: {
                  $0.runtimeModelID == value.runtimeModelID && $0.profileID == value.profile.id
              }) else {
            throw ClusterWorkerProtocolError.invalid("Unknown runtime adapter, version, model or profile")
        }
        try workerRequire([value.runtimeBinarySHA256, value.artifactSHA256, value.configurationSHA256,
            value.manifestSHA256, value.profileFingerprint, value.arithmeticPolicySHA256]
            .allSatisfy(ClusterWorkerValidation.hash), "Malformed runtime capability identity")
        try workerRequire(!value.supportedPrefillSchedules.isEmpty
            && value.supportedPrefillSchedules.first == .serial
            && value.supportedPrefillSchedules == ClusterPrefillSchedule.allCases.filter(value.supportedPrefillSchedules.contains),
            "Missing, duplicate or unordered prefill schedules")
        try workerRequire(value.supportedGenerationModes.first == .pipeline
            && value.supportedGenerationModes == ClusterGenerationMode.allCases.filter(value.supportedGenerationModes.contains),
            "Missing, duplicate or unordered generation modes")
        let imageCandidate = adapter == .mimoV26ImageCandidate
        try workerRequire(imageCandidate == (value.media != nil),"Candidate adapter requires its closed media contract")
        if imageCandidate {
            try ClusterMiMoImageCandidate.validateSource(profileID:value.profile.id,modelID:value.runtimeModelID,
                artifact:value.artifactSHA256,configuration:value.configurationSHA256,manifest:value.manifestSHA256)
            try workerRequire(value.supportedGenerationModes.allSatisfy {
                [.pipeline,.pipelineCompactDecode,.pipelineMTP].contains($0)
            },"MiMo candidate runs only the two-rank pipeline")
        }
        let glmImage = adapter == .glm5NextLayerStage && value.profile.id == ClusterGLMImageCandidate.profileID
        try workerRequire(glmImage == (value.glmImages != nil) && !(value.media != nil && value.glmImages != nil),
            "GLM private profile requires its own explicit media contract")
        if glmImage {
            try ClusterGLMImageCandidate.validateSource(profileID: value.profile.id, modelID: value.runtimeModelID,
                artifact: value.artifactSHA256, configuration: value.configurationSHA256, manifest: value.manifestSHA256)
            try workerRequire(value.supportedGenerationModes == [.pipeline] && value.supportedPrefillSchedules == [.serial],
                "GLM image candidate requires the serial pipeline")
        }
        let p = value.profile
        try workerRequire((1...ClusterWorkerLimits.vocabularySize).contains(p.vocabularySize)
            && (1...ClusterWorkerLimits.promptTokens).contains(p.maximumPromptTokens)
            && (1...ClusterWorkerLimits.outputTokens).contains(p.maximumOutputTokens)
            && (1...p.maximumPromptTokens).contains(p.maximumChunkTokens)
            && (1...ClusterWorkerLimits.contextTokens).contains(p.maximumContextTokens)
            // Each maximum leaves room for at least one token of the other; a
            // request's own prompt plus output is held to the context by the
            // reservation checks, so a long prompt and a long output need not
            // both fit at once.
            && p.maximumPromptTokens < p.maximumContextTokens && p.maximumOutputTokens < p.maximumContextTokens
            ,
            "Runtime profile exceeds protocol geometry")
        try workerRequire(value.arithmeticPolicyID == adapter.arithmeticPolicyID,
                          "Unknown runtime arithmetic policy")
        // Up to 128: a family whose stage plan cuts at every layer boundary
        // lists every one (MiMo: 47), so the planner chooses among them all.
        try workerRequire((1...ClusterRuntimeCapabilityCodec.maximumPartitions).contains(value.partitions.count)
            && Set(value.partitions.map(\.planSHA256)).count == value.partitions.count,
            "Missing or duplicate runtime partitions")
        var layerCount: Int?
        var previousCut = 0
        for selection in value.partitions {
            try workerRequire(selection.kind == "contiguousWholeLayers" && ClusterWorkerValidation.hash(selection.planSHA256)
                && selection.stages.count == 2, "Unknown partition kind or stage count")
            let a = selection.stages[0], b = selection.stages[1]
            try workerRequire(a.rank == 0 && b.rank == 1 && a.sourceLayerStart == 0
                && a.sourceLayerEnd > 0 && a.sourceLayerEnd == b.sourceLayerStart
                && b.sourceLayerEnd > b.sourceLayerStart && b.sourceLayerEnd <= 128,
                "Partition is not a complete ordered two-stage interval")
            try workerRequire(a.sourceLayerEnd > previousCut, "Partitions must be unique and ordered by cut")
            previousCut = a.sourceLayerEnd
            if let layerCount { try workerRequire(layerCount == b.sourceLayerEnd, "Partitions disagree on layer coverage") }
            layerCount = b.sourceLayerEnd
            try workerRequire(selection.stages.allSatisfy {
                ClusterWorkerValidation.hash($0.stagePlanSHA256)
                    && ClusterWorkerValidation.hash($0.constructionConfigurationSHA256)
            } && a.stagePlanSHA256 != b.stagePlanSHA256, "Malformed or repeated stage identity")
        }
    }
}
