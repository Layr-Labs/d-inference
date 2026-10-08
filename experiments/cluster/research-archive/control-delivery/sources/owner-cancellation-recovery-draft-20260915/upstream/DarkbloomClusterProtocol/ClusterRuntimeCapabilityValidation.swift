import Foundation

enum ClusterRuntimeCapabilityValidation {
    static func check(_ value: ClusterRuntimeCapability) throws {
        guard let adapter = ClusterRuntimeAdapter(rawValue: value.adapterID),
              value.adapterVersion == adapter.version, value.runtimeModelID == adapter.runtimeModelID,
              value.profile.id == adapter.profileID else {
            throw ClusterWorkerProtocolError.invalid("Unknown runtime adapter, version, model or profile")
        }
        try workerRequire([value.runtimeBinarySHA256, value.artifactSHA256, value.configurationSHA256,
            value.manifestSHA256, value.profileFingerprint, value.arithmeticPolicySHA256]
            .allSatisfy(ClusterWorkerValidation.hash), "Malformed runtime capability identity")
        let p = value.profile
        try workerRequire((1...ClusterWorkerLimits.vocabularySize).contains(p.vocabularySize)
            && (1...ClusterWorkerLimits.promptTokens).contains(p.maximumPromptTokens)
            && (1...ClusterWorkerLimits.outputTokens).contains(p.maximumOutputTokens)
            && (1...p.maximumPromptTokens).contains(p.maximumChunkTokens)
            && (1...ClusterWorkerLimits.contextTokens).contains(p.maximumContextTokens)
            && p.maximumPromptTokens <= p.maximumContextTokens - p.maximumOutputTokens
            ,
            "Runtime profile exceeds protocol geometry")
        // These are implementation ceilings, not runtime admission or a hardware
        // promise. The producer obtains its exact values from the shared adapter.
        try workerRequire((1...300).contains(value.maxLifetimeSeconds) && (1...16).contains(value.maxRequests),
                          "Unsupported resident lifetime or request count")
        try workerRequire(value.arithmeticPolicyID == "qwen_cbv2_query128_bf16_tf32_default_v1",
                          "Unknown runtime arithmetic policy")
        try workerRequire((1...16).contains(value.partitions.count)
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
