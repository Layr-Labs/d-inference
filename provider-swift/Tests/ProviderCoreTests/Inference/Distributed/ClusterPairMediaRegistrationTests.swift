import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// What a pair member registers for image and video input follows the placed mode's readiness, not the artifact's
/// configuration: only GLM-5.3-Flash's and Qwen3.8 27B's tensor-parallel runtimes serve media (2026-10-25: a GLM
/// pipeline registered `is_vision`, and the coordinator routes media by it). A slot that registered media is
/// published only while both ranks report the media contract.
@Suite("Cluster pair media registration")
struct ClusterPairMediaRegistrationTests {
    private static func hash(_ character: Character) -> String { String(repeating: String(character), count: 64) }

    private static func capability(_ adapter: ClusterRuntimeAdapter, model: String, profile: String) throws -> ClusterRuntimeCapability {
        try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: adapter.rawValue, adapterVersion: adapter.version,
            runtimeModelID: model, artifactSHA256: hash("b"), configurationSHA256: hash("c"), manifestSHA256: hash("d"),
            profile: .init(id: profile, vocabularySize: 248320, maximumPromptTokens: 32768, maximumOutputTokens: 32768,
                           maximumChunkTokens: 512, maximumContextTokens: 65536),
            profileFingerprint: hash("e"), partitions: [.init(planSHA256: hash("f"), stages: [
                .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 1, stagePlanSHA256: hash("1"), constructionConfigurationSHA256: hash("2")),
                .init(rank: 1, sourceLayerStart: 1, sourceLayerEnd: 2, stagePlanSHA256: hash("3"), constructionConfigurationSHA256: hash("4"))])],
            arithmeticPolicyID: adapter.arithmeticPolicyID, arithmeticPolicySHA256: hash("5"),
            supportedGenerationModes: [.pipeline, .tensorParallel])
    }

    private static func rows() throws -> (glm: ClusterRuntimeCapability, qwen27: ClusterRuntimeCapability, qwen9: ClusterRuntimeCapability) {
        (try capability(.glm5NextLayerStage, model: ClusterGLMImageCandidate.runtimeModelID, profile: ClusterGLMImageCandidate.textProfileID),
         try capability(.qwen35Dense, model: "registered_qwen38_27b", profile: "registered_qwen38_27b_greedy_generation_v1"),
         try capability(.qwen35Dense, model: "registered_qwen35_9b", profile: "registered_qwen35_9b_greedy_generation_v1"))
    }

    /// The configuration scan declares vision for both GLM and Qwen whatever the placement.
    private static let scanned = ModelInfo(id: "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp", modelType: "glm5_next",
        sizeBytes: 181_800_000_000, estimatedMemoryGb: 170, weightHash: hash("9"), isVision: true, templateRenderOK: true,
        nativeMediaTools: true)

    @Test func theMediaContractIsThePlacedModesNotTheArtifacts() throws {
        let rows = try Self.rows()
        #expect(ClusterModelFeaturePolicy.mediaContract(capability: rows.glm, mode: .tensorParallel) == ClusterGLMMedia.contract)
        #expect(ClusterModelFeaturePolicy.mediaContract(capability: rows.qwen27, mode: .tensorParallel) == ClusterQwenMedia.contract)
        for mode in ClusterGenerationMode.allCases where mode != .tensorParallel {
            #expect(ClusterModelFeaturePolicy.mediaContract(capability: rows.glm, mode: mode) == nil, "\(mode)")
            #expect(ClusterModelFeaturePolicy.mediaContract(capability: rows.qwen27, mode: mode) == nil, "\(mode)")
        }
        // A tensor-parallel row whose runtime serves no media.
        #expect(ClusterModelFeaturePolicy.mediaContract(capability: rows.qwen9, mode: .tensorParallel) == nil)
    }

    @Test func aMemberRegistersImagesAndVideoOnlyWhereItsRanksServeThem() throws {
        let rows = try Self.rows()
        #expect(ClusterMemberPreparation.registeredModel(Self.scanned, capability: rows.glm, mode: .tensorParallel) == Self.scanned)
        #expect(ClusterMemberPreparation.registeredModel(Self.scanned, capability: rows.qwen27, mode: .tensorParallel) == Self.scanned)
        for (capability, mode) in [(rows.glm, ClusterGenerationMode.pipeline), (rows.qwen27, .pipeline), (rows.qwen9, .tensorParallel)] {
            let registered = ClusterMemberPreparation.registeredModel(Self.scanned, capability: capability, mode: mode)
            #expect(registered.isVision == nil && registered.nativeMediaTools == nil, "\(capability.runtimeModelID) \(mode)")
            // Everything else the scan read is registered as it was.
            var restored = registered
            restored.isVision = Self.scanned.isVision
            restored.nativeMediaTools = Self.scanned.nativeMediaTools
            #expect(restored == Self.scanned)
        }
        // A model the scan found text-only stays so in every mode.
        var text = Self.scanned
        text.isVision = nil
        text.nativeMediaTools = nil
        #expect(ClusterMemberPreparation.registeredModel(text, capability: rows.glm, mode: .tensorParallel) == text)
    }

    @Test func aSlotThatRegisteredMediaNeedsBothRanksMediaContract() throws {
        let identity = DistributedResidentIdentity(membershipEpoch: UUID(), modelID: ClusterGLMImageCandidate.runtimeModelID,
            artifactSHA256: Self.hash("a"), configurationSHA256: Self.hash("c"),
            peers: [.init(id: "fixture-0", buildSHA256: Self.hash("b")), .init(id: "fixture-1", buildSHA256: Self.hash("b"))])
        let media = DistributedResidentReadiness(identity: identity, profileID: ClusterGLMImageCandidate.textProfileID,
            requestCapacityBytes: 1 << 30, media: ClusterGLMMedia.contract)
        let text = DistributedResidentReadiness(identity: identity, profileID: ClusterGLMImageCandidate.textProfileID,
            requestCapacityBytes: 1 << 30)
        try ClusterMemberPreparation.requireRegisteredMedia(Self.scanned, ready: media)
        #expect(throws: DistributedEngineError.self) {
            try ClusterMemberPreparation.requireRegisteredMedia(Self.scanned, ready: text)
        }
        var textOnly = Self.scanned
        textOnly.isVision = nil
        try ClusterMemberPreparation.requireRegisteredMedia(textOnly, ready: text)
        try ClusterMemberPreparation.requireRegisteredMedia(textOnly, ready: media)
        // No registration row (a member that registered nothing yet) claims nothing.
        try ClusterMemberPreparation.requireRegisteredMedia(nil, ready: text)
    }
}
