import Foundation

/// Exactly one canonical, sorted-key JSON object and LF, bounded to 16 KiB.
/// Reuses the protocol scanner and strict typed object reader; never hashes Plans.
public enum ClusterRuntimeCapabilityCodec {
    public static let maximumBytes = 16 * 1024

    public static func encode(_ value: ClusterRuntimeCapability) throws -> Data {
        try ClusterRuntimeCapabilityValidation.check(value)
        let p = value.profile
        var object: [String: Any] = [
            "schema": ClusterRuntimeCapability.schema,
            "workerProtocolVersion": value.workerProtocolVersion, "ownerProtocolVersion": value.ownerProtocolVersion,
            "bootstrapABIVersion": value.bootstrapABIVersion, "runtimeBinarySHA256": value.runtimeBinarySHA256,
            "adapterID": value.adapterID, "adapterVersion": value.adapterVersion, "runtimeModelID": value.runtimeModelID,
            "artifactSHA256": value.artifactSHA256, "configurationSHA256": value.configurationSHA256,
            "manifestSHA256": value.manifestSHA256, "profileFingerprint": value.profileFingerprint,
            "profile": ["id": p.id, "vocabularySize": p.vocabularySize, "maximumPromptTokens": p.maximumPromptTokens,
                "maximumOutputTokens": p.maximumOutputTokens, "maximumChunkTokens": p.maximumChunkTokens,
                "maximumContextTokens": p.maximumContextTokens],
            "partitions": value.partitions.map { partition in
                ["kind": partition.kind, "planSHA256": partition.planSHA256,
                 "stages": partition.stages.map { stage in
                    ["rank": stage.rank, "sourceLayerStart": stage.sourceLayerStart, "sourceLayerEnd": stage.sourceLayerEnd,
                     "stagePlanSHA256": stage.stagePlanSHA256,
                     "constructionConfigurationSHA256": stage.constructionConfigurationSHA256] as [String: Any]
                 }] as [String: Any]
            },
            "arithmeticPolicyID": value.arithmeticPolicyID, "arithmeticPolicySHA256": value.arithmeticPolicySHA256,
            "stateSemantics": value.stateSemantics, "rankCount": value.rankCount, "batchSize": value.batchSize,
            "maxActiveRequests": value.maxActiveRequests, "maxLifetimeSeconds": value.maxLifetimeSeconds,
            "maxRequests": value.maxRequests, "schedulingPolicy": value.schedulingPolicy,
            "selectionPolicy": value.selectionPolicy, "modality": value.modality, "stopPolicy": value.stopPolicy,
            "speculation": value.speculation, "prefixReuse": value.prefixReuse,
        ]
        // Preserve canonical v1 serial-only descriptors byte-for-byte. New
        // adapters advertise the additional supported schedules explicitly.
        if value.supportedPrefillSchedules != [.serial] {
            object["supportedPrefillSchedules"] = value.supportedPrefillSchedules.map(\.rawValue)
        }
        if let preparation = value.startupPreparation {
            object["startupPreparation"] = ["kind": preparation.kind, "requestCount": preparation.requestCount,
                "tokenPattern": preparation.tokenPattern, "outputCount": preparation.outputCount]
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        try workerRequire(data.count < maximumBytes, "Runtime capability exceeds its byte bound")
        data.append(10); return data
    }

    public static func decode(_ data: Data) throws -> ClusterRuntimeCapability {
        try workerRequire(!data.isEmpty && data.count <= maximumBytes && data.last == 10
            && !data.dropLast().contains(10), "Expected one complete bounded capability record")
        try validateClusterWorkerJSON(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClusterWorkerProtocolError.invalid("Capability must be an object")
        }
        var r = WorkerObject(object)
        try workerRequire(try r.string("schema") == ClusterRuntimeCapability.schema
            && r.int("workerProtocolVersion") == ClusterWorkerLimits.version
            && r.int("ownerProtocolVersion") == 1 && r.int("bootstrapABIVersion") == 1,
            "Unsupported runtime protocol or bootstrap ABI")
        var p = WorkerObject(try r.object("profile"))
        let profile = try ClusterWorkerProfile(id: p.string("id"), vocabularySize: p.int("vocabularySize"),
            maximumPromptTokens: p.int("maximumPromptTokens"), maximumOutputTokens: p.int("maximumOutputTokens"),
            maximumChunkTokens: p.int("maximumChunkTokens"), maximumContextTokens: p.int("maximumContextTokens"))
        try p.finish()
        let partitions = try r.objects("partitions").map { object -> ClusterRuntimePartition in
            var partition = WorkerObject(object)
            let stages = try partition.objects("stages").map { object -> ClusterRuntimeStage in
                var stage = WorkerObject(object)
                let value = try ClusterRuntimeStage(rank: stage.int("rank"), sourceLayerStart: stage.int("sourceLayerStart"),
                    sourceLayerEnd: stage.int("sourceLayerEnd"), stagePlanSHA256: stage.string("stagePlanSHA256"),
                    constructionConfigurationSHA256: stage.string("constructionConfigurationSHA256"))
                try stage.finish(); return value
            }
            let value = try ClusterRuntimePartition(kind: partition.string("kind"), planSHA256: partition.string("planSHA256"), stages: stages)
            try partition.finish(); return value
        }
        let schedules: [ClusterPrefillSchedule]
        if r.values["supportedPrefillSchedules"] != nil {
            guard let names = try r.take("supportedPrefillSchedules") as? [String] else {
                throw ClusterWorkerProtocolError.invalid("Expected prefill schedule names")
            }
            schedules = try names.map {
                guard let value = ClusterPrefillSchedule(rawValue: $0) else {
                    throw ClusterWorkerProtocolError.invalid("Unknown prefill schedule")
                }
                return value
            }
        } else { schedules = [.serial] }
        let preparation: ClusterRuntimeStartupPreparation?
        if r.values["startupPreparation"] != nil {
            var startup = WorkerObject(try r.object("startupPreparation"))
            let parsed = try ClusterRuntimeStartupPreparation(tokenPattern: startup.ints("tokenPattern"),
                                                               outputCount: startup.int("outputCount"))
            try workerRequire(try startup.string("kind") == parsed.kind
                && startup.int("requestCount") == parsed.requestCount, "Unknown startup preparation recipe")
            try startup.finish(); preparation = parsed
        } else { preparation = nil }
        let value = try ClusterRuntimeCapability(runtimeBinarySHA256: r.string("runtimeBinarySHA256"),
            adapterID: r.string("adapterID"), adapterVersion: r.int("adapterVersion"), runtimeModelID: r.string("runtimeModelID"),
            artifactSHA256: r.string("artifactSHA256"), configurationSHA256: r.string("configurationSHA256"),
            manifestSHA256: r.string("manifestSHA256"), profile: profile, profileFingerprint: r.string("profileFingerprint"),
            partitions: partitions, arithmeticPolicyID: r.string("arithmeticPolicyID"),
            arithmeticPolicySHA256: r.string("arithmeticPolicySHA256"), maxLifetimeSeconds: r.int("maxLifetimeSeconds"),
            maxRequests: r.int("maxRequests"), supportedPrefillSchedules: schedules, startupPreparation: preparation)
        try workerRequire(try r.string("stateSemantics") == value.stateSemantics
            && r.int("rankCount") == value.rankCount && r.int("batchSize") == value.batchSize
            && r.int("maxActiveRequests") == value.maxActiveRequests
            && r.string("schedulingPolicy") == value.schedulingPolicy
            && r.string("selectionPolicy") == value.selectionPolicy && r.string("modality") == value.modality
            && r.string("stopPolicy") == value.stopPolicy && r.string("speculation") == value.speculation
            && r.bool("prefixReuse") == value.prefixReuse, "Unsupported runtime execution policy")
        try r.finish()
        try workerRequire(try encode(value) == data, "Capability record is not canonical")
        return value
    }
}
