import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Bonsai 9B request policy")
struct Bonsai9BRequestPolicyTests {
    private let modelType = "prism_hadamard_qwen35"

    @Test(arguments: [Bonsai9BModelPolicy.modelID, Bonsai9BModelPolicy.eigenModelID])
    func exactArtifactDefaultsToPagedAndSSDWithOperatorOptOut(modelID: String) {
        #expect(EngineV2KVBackendPolicy.preferredBackend(selection: .auto, modelID: modelID) == .paged)
        #expect(EngineV2KVBackendPolicy.preferredBackend(selection: .contiguous, modelID: modelID) == .contiguous)
        #expect(PrefixCachePolicy.isEnabled(modelId: modelID, environment: [:]))
        #expect(!PrefixCachePolicy.isEnabled(modelId: modelID, environment: ["DARKBLOOM_PREFIX_CACHE": "0"]))
        #expect(!PrefixCachePolicy.isMemoryEnabled(environment: [:]))
        for other in [modelID + "-other", modelID.lowercased(), "prism-ml/Ternary-Bonsai-2-4B-mlx-2bit"] {
            #expect(EngineV2KVBackendPolicy.preferredBackend(selection: .auto, modelID: other) == .contiguous)
            #expect(!PrefixCachePolicy.isEnabled(modelId: other, environment: [:]))
        }
        // This exact opt-in does not transfer the 27B admission or MTP cohort.
        #expect(!EngineV2SupportedModels.isBonsai2ListingModelID(modelID))
    }

    @Test(arguments: [Bonsai9BModelPolicy.modelID, Bonsai9BModelPolicy.eigenModelID])
    func artifactSamplingFillsOmissionsAndPreservesExplicitOverrides(modelID: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bonsai-request-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generation = #"{"do_sample":true,"temperature":1.0,"top_p":0.95,"top_k":20}"#
        try Data(generation.utf8).write(to: directory.appendingPathComponent("generation_config.json"))
        let defaults = EngineV2SamplingDefaults.resolve(
            modelId: modelID, modelType: modelType, modelDirectory: directory)
        let thinking = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(
            #"{"model":"m","messages":[{"role":"user","content":"test"}],"presence_penalty":1.5}"#.utf8))
        let sampling = EngineV2Translation.samplingParams(from: thinking, defaults: defaults)
        #expect(sampling.temperature == 1)
        #expect(sampling.topP == 0.95)
        #expect(sampling.topK == 20)
        // Presence penalty is supplied by the qualification profile, not invented
        // as an artifact field: the pinned generation_config does not declare it.
        #expect(sampling.presencePenalty == 1.5)
        let explicit = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(
            #"{"model":"m","messages":[],"temperature":0,"top_p":1,"top_k":0,"presence_penalty":0}"#.utf8))
        let overridden = EngineV2Translation.samplingParams(from: explicit, defaults: defaults)
        #expect(overridden.temperature == 0)
        #expect(overridden.topP == 1)
        #expect(overridden.topK == 0)
        #expect(overridden.presencePenalty == 0)
    }

    @Test(arguments: [Bonsai9BModelPolicy.modelID, Bonsai9BModelPolicy.eigenModelID])
    func nativeChannelsRequireExactIdentityAndArchitecture(modelID: String) {
        let context = ChatTemplateFixContext(modelId: modelID, modelType: modelType)
        #expect(ToolChoiceEnforcementPolicy.usesNativeTextChannels(context))
        #expect(ToolChoiceEnforcementPolicy.preservesInnerReasoningSpans(context))
        #expect(ToolChoiceEnforcementPolicy.supportsForcedMedia(
            context: context, nativeWrapperLoaded: true))
        #expect(!ToolChoiceEnforcementPolicy.supportsForcedMedia(
            context: context, nativeWrapperLoaded: false))
        for (id, type) in [(modelID, "qwen3_5"), ("unqualified-prism", modelType)] {
            let other = ChatTemplateFixContext(modelId: id, modelType: type)
            #expect(!Bonsai9BModelPolicy.matches(modelId: id, modelType: type))
            #expect(!ToolChoiceEnforcementPolicy.usesNativeTextChannels(other))
            #expect(!EngineV2SamplingDefaults.honorsArtifactDefaults(modelId: id, modelType: type))
        }
        // Request framing must not inherit the existing 27B paging/cache cohort.
        #expect(!EngineV2SupportedModels.isBonsai2ListingModelID(modelID))
    }
}
