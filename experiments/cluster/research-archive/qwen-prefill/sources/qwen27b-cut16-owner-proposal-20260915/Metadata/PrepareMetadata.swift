import Foundation
import DarkbloomClusterProtocol

private struct RetainedModel: Decodable {
    let configuration: Data
    let manifest: Data
    let canonicalTensors: [QwenDenseCanonicalTensor]
}
private struct RetainedInputs: Decodable { let twentySeven: RetainedModel }

/// Model-free entry over the exact validated runtime metadata implementation.
/// The build SHA is a caller binding; package verification remains mandatory.
@main struct PrepareMetadata {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4, qwenStageWireIsSHA256(args[1]), args[2] != args[3] else {
            throw ProbeError("Expected RETAINED_INPUTS NATIVE_SHA256 PEER0_ID PEER1_ID")
        }
        let (bytes, inputSHA) = try readQualificationBytes(args[0], maximum: 4 * 1024 * 1024)
        let input = try JSONDecoder().decode(RetainedInputs.self, from: bytes).twentySeven
        let definition = try QwenResidentModelDefinition(model: .qwen38TwentySevenB)
        let spec = definition.specification
        let profile = try QwenRegisteredDenseModelProfile.admit(configuration: input.configuration,
            manifest: input.manifest, expectedArtifactAggregateSHA256: spec.artifactSHA256,
            canonicalTensors: input.canonicalTensors, residentDefinition: definition)
        let plan = try profile.makePlanningPlan(stageCut: Qwen27BQualificationScope.stageCut)
        let generation = try QwenResidentAdapterDefinition.profile(definition: definition)
        let storage = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .sequentialPair)
        let wire = ClusterWorkerProfile(id: generation.identifier, vocabularySize: generation.vocabularySize,
            maximumPromptTokens: generation.maximumPromptTokens, maximumOutputTokens: generation.maximumOutputTokens,
            maximumChunkTokens: generation.maximumChunkTokens, maximumContextTokens: generation.maximumContextTokens)
        let identity = ClusterWorkerIdentity(membershipEpoch: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            modelID: spec.model.rawValue, artifactSHA256: spec.artifactSHA256,
            configurationSHA256: spec.configurationSHA256,
            peers: args.suffix(2).map { ClusterWorkerPeer(id: $0, buildSHA256: args[1]) })
        let templates = try (0..<2).map { rank -> String in
            // A positive codec placeholder only. Controller capacity is the
            // actual two ready events' checked sum after native resource checks.
            let ready = ClusterWorkerReady(identity: identity, rank: rank, profile: wire,
                executionPlanSHA256: plan.fingerprint, requestCapacityBytes: 1)
            try Qwen27BQualificationScope.validate(ready)
            return try ClusterWorkerCodec.encode(ClusterWorkerEventFrame(membershipEpoch: identity.membershipEpoch,
                sequence: 0, requestID: nil, event: .ready(ready))).base64EncodedString()
        }
        try qualificationEmit([
            "schema": "qwen27b_owner_qualification_metadata_v1", "retainedInputsSHA256": inputSHA,
            "nativeBinarySHA256": args[1], "modelID": spec.model.rawValue,
            "artifactSHA256": spec.artifactSHA256, "configurationSHA256": spec.configurationSHA256,
            "manifestSHA256": spec.manifestSHA256, "planSHA256": plan.fingerprint,
            "stageCut": Qwen27BQualificationScope.stageCut, "stagePlanSHA256": plan.stages.map(\.fingerprint),
            "constructionConfigurationSHA256": storage.stages.map(\.constructionConfigurationSHA256),
            "canonicalCounts": storage.stages.map(\.canonicalCount), "activeBytes": storage.stages.map(\.activeBytes),
            "generationProfileSHA256": generation.fingerprint, "readyTemplatesBase64": templates,
            "actualReadinessObserved": false, "providerEligibilityEstablished": false,
            "modelPayloadRead": false, "nativeExecuted": false,
        ])
    }
}
