import DarkbloomClusterProtocol
import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// A GLM-5.3-Flash pipeline pair serves its owner's own requests (the leader's
/// local API, `darkbloom cluster local`) up to 262,144 tokens: its ranks charge
/// each longer request at its own context when they reserve it. Requests through
/// Darkbloom, and everything the pair reports, keep the memory plan's 32,768 +
/// 32,768 tokens. Tensor parallel and Gemma 4's pipeline serve their whole
/// profile to both, as before; every other pipeline the memory plan's request.
/// Fabricated capabilities and a fabricated pair: no process, model or GPU.
@Suite("A GLM pipeline pair serves its owner up to 262,144 tokens", .serialized)
struct PairOwnerContextTests {
    static let owner = (promptTokens: 262_143, outputTokens: 65_536, contextTokens: 262_144)
    static let standard = (promptTokens: 32_768, outputTokens: 32_768, contextTokens: 65_536)
    static let model = PairContextWindowTests.model

    static func capability(_ adapter: ClusterRuntimeAdapter, model: String, profile: String, prompt: Int, output: Int,
                           context: Int, vocabulary: Int = 262_144) throws -> ClusterRuntimeCapability {
        func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }
        return try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: adapter.rawValue,
            adapterVersion: adapter.version, runtimeModelID: model, artifactSHA256: hash("b"),
            configurationSHA256: hash("c"), manifestSHA256: hash("d"),
            profile: .init(id: profile, vocabularySize: vocabulary, maximumPromptTokens: prompt, maximumOutputTokens: output,
                maximumChunkTokens: 2048, maximumContextTokens: context),
            profileFingerprint: hash("e"), partitions: [.init(planSHA256: hash("f"), stages: [
                .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 1, stagePlanSHA256: hash("1"),
                      constructionConfigurationSHA256: hash("2")),
                .init(rank: 1, sourceLayerStart: 1, sourceLayerEnd: 2, stagePlanSHA256: hash("3"),
                      constructionConfigurationSHA256: hash("4"))])],
            arithmeticPolicyID: adapter.arithmeticPolicyID, arithmeticPolicySHA256: hash("5"),
            supportedGenerationModes: [.pipeline, .tensorParallel])
    }

    static func glm() throws -> ClusterRuntimeCapability {
        try capability(.glm5NextLayerStage, model: "registered_glm53_flash",
            profile: "registered_glm53_flash_greedy_generation_v1", prompt: 1_048_575, output: 65_536, context: 1_048_576)
    }

    static func request(prompt: Int, maxTokens: Int) -> CBv2Request {
        CBv2Request(id: .init(1), promptTokens: Array(repeating: 1, count: prompt), sampling: .init(temperature: 0),
            maxTokens: maxTokens)
    }

    static func limits(_ profile: ClusterWorkerProfile) -> [Int] {
        [profile.maximumPromptTokens, profile.maximumOutputTokens, profile.maximumContextTokens]
    }

    static func limits(_ value: (promptTokens: Int, outputTokens: Int, contextTokens: Int)) -> [Int] {
        [value.promptTokens, value.outputTokens, value.contextTokens]
    }

    /// The one rule both sides read: only GLM's pipeline names an owner context, 262,144 tokens.
    @Test func onlyAGLMPipelineNamesAnOwnerContext() {
        #expect(ClusterRuntimeAdapter.glm5NextLayerStage.pipelineOwnerContextTokens == 262_144)
        #expect(ClusterRuntimeAdapter.allCases.filter { $0.pipelineOwnerContextTokens != nil } == [.glm5NextLayerStage])
        let glm = ClusterWorkerProfile(id: "glm", vocabularySize: 1, maximumPromptTokens: 1_048_575,
            maximumOutputTokens: 65_536, maximumChunkTokens: 2048, maximumContextTokens: 1_048_576)
        #expect(Self.limits(glm.scope(contextTokens: 262_144)) == [262_143, 65_536, 262_144])
        #expect(glm.scope(contextTokens: 262_144).maximumChunkTokens == 2048)
        #expect(glm.scope(contextTokens: 2_000_000) == glm)
        let short = ClusterWorkerProfile(id: "short", vocabularySize: 1, maximumPromptTokens: 4095,
            maximumOutputTokens: 4095, maximumChunkTokens: 512, maximumContextTokens: 4096)
        #expect(short.scope(contextTokens: 262_144) == short)
    }

    /// A GLM pipeline serves its owner 262,143 prompt and 65,536 output tokens within 262,144, and Darkbloom's
    /// requests the memory plan's 32,768 + 32,768; tensor parallel and Gemma 4 serve both their whole profile.
    @Test func aGLMPipelineServesItsOwnerUpTo262144TokensAndDarkbloomTheStandardRequest() throws {
        let glm = try Self.glm()
        #expect(ClusterModelFeaturePolicy.servedProfile(glm, mode: .pipeline) == glm.profile.memoryScope)
        #expect(Self.limits(ClusterModelFeaturePolicy.ownerServedProfile(glm, mode: .pipeline)) == [262_143, 65_536, 262_144])
        #expect(ClusterModelFeaturePolicy.ownerServedProfile(glm, mode: .tensorParallel) == glm.profile)
        let pipeline = try DistributedResidentExecutionProfile(capability: glm, generationMode: .pipeline,
            requestTimeout: .seconds(315))
        #expect(Self.limits(pipeline.served) == Self.limits(Self.standard))
        #expect(Self.limits(pipeline.ownerServed) == Self.limits(Self.owner))
        let tensor = try DistributedResidentExecutionProfile(capability: glm, generationMode: .tensorParallel,
            requestTimeout: .seconds(315))
        #expect(Self.limits(tensor.ownerServed) == Self.limits(tensor.served))
        #expect(Self.limits(tensor.served) == [1_048_575, 65_536, 1_048_576])
        let gemma = try Self.capability(.gemma4LayerStage, model: "registered_gemma4_26b_qat_4bit",
            profile: "registered_gemma4_26b_qat_4bit_greedy_generation_v1", prompt: 262_143, output: 32_768,
            context: 262_144)
        let qwen = try Self.capability(.qwen35Dense, model: "registered_qwen38_27b",
            profile: "registered_qwen38_27b_greedy_generation_v1", prompt: 262_143, output: 65_536, context: 262_144,
            vocabulary: 248_320)
        for capability in [gemma, qwen] {
            for mode in [ClusterGenerationMode.pipeline, .tensorParallel] {
                #expect(ClusterModelFeaturePolicy.ownerServedProfile(capability, mode: mode)
                    == ClusterModelFeaturePolicy.servedProfile(capability, mode: mode), "\(capability.adapterID) \(mode)")
            }
        }
    }

    /// Before either rank is asked: the owner's request within 262,144 tokens is served, past it refused for what it
    /// breaks; the same request through Darkbloom is held to the memory plan's request, as before.
    @Test func theOwnersRequestIsHeldTo262144TokensAndDarkbloomsToTheStandardRequest() throws {
        let profile = try DistributedResidentExecutionProfile(capability: Self.glm(), generationMode: .pipeline,
            requestTimeout: .seconds(315))
        let long = Self.request(prompt: 200_000, maxTokens: 50_000)
        #expect(profile.refusal(for: long, ownerRequest: true) == nil)
        #expect(profile.refusal(for: long) == .contextLengthExceeded)
        #expect(profile.refusal(for: Self.request(prompt: 32_768, maxTokens: 32_768), ownerRequest: true) == nil)
        #expect(profile.refusal(for: Self.request(prompt: 32_768, maxTokens: 32_768)) == nil)
        #expect(profile.refusal(for: Self.request(prompt: 40_000, maxTokens: 1)) == .promptTooLong)
        #expect(profile.refusal(for: Self.request(prompt: 262_143, maxTokens: 1), ownerRequest: true) == nil)
        #expect(profile.refusal(for: Self.request(prompt: 262_144, maxTokens: 1), ownerRequest: true)
            == .contextLengthExceeded)
        #expect(profile.refusal(for: Self.request(prompt: 100_000, maxTokens: 65_537), ownerRequest: true)
            == .outputTooLong)
        #expect(profile.refusal(for: Self.request(prompt: 200_000, maxTokens: 62_145), ownerRequest: true)
            == .contextTooLong)
        #expect(DistributedRequestRefusal.contextLengthExceeded.message(profile) == windowRefusalWords(65_536))
        #expect(DistributedRequestRefusal.contextLengthExceeded.message(profile, ownerRequest: true)
            == windowRefusalWords(262_144))
        #expect(DistributedRequestRefusal.outputTooLong.message(profile, ownerRequest: true)
            == "max_tokens is above this model's output limit of 65536 tokens on this cluster.")
    }

    /// Whose request it is travels with its deadlines: a restriction shortens them and keeps the request's own.
    @Test func theOwnersRequestSurvivesEveryRestrictionOfItsDeadlines() {
        let now = ContinuousClock.now
        let owner = DistributedRequestDeadlineContext(generationDeadline: now.advanced(by: .seconds(3600)),
            ownerRequest: true)
        let shorter = DistributedRequestDeadlineContext(generationDeadline: now.advanced(by: .seconds(10)),
            firstTokenDeadline: now.advanced(by: .seconds(5)))
        let restricted = owner.restricted(to: shorter)
        #expect(restricted.ownerRequest && restricted.generationDeadline == shorter.generationDeadline)
        #expect(restricted.firstTokenDeadline == shorter.firstTokenDeadline)
        #expect(!shorter.restricted(to: owner).ownerRequest)
        #expect(!DistributedRequestDeadlineContext(generationDeadline: now).ownerRequest)
    }

    /// A pair at a GLM pipeline's limits, with no capability: the profile's, Darkbloom's and the owner's.
    static func profile() throws -> DistributedResidentExecutionProfile {
        try .init(id: "fabricated-greedy", vocabularySize: 100, maxPromptTokens: 1_048_575, maxOutputTokens: 65_536,
            maxContextTokens: 1_048_576, requestTimeout: .seconds(315), served: Self.standard, ownerServed: Self.owner)
    }

    static func bridge(_ owner: PairContextWindowTests.Owner) throws -> EngineV2Bridge {
        try DistributedEngineFactory.makeBridge(owner: owner, expectedIdentity: owner.identity, profile: profile(),
            tokenizer: TokenizerHandle(FixedLengthTokenizer()), eosTokenIDs: [99])
    }

    /// The leader's local API serves the owner's long request: a 262,140-token prompt with a `max_tokens` cut to
    /// what the 262,144 tokens leave, streamed or not, and a 100,000-token prompt with its own `max_tokens`.
    @Test(arguments: [false, true])
    func theLeadersLocalAPIServesTheOwnersLongRequest(stream: Bool) async throws {
        let owner = PairContextWindowTests.Owner()
        let bridge = try Self.bridge(owner)
        let cut = try await PairContextWindowTests.answer(bridge, prompt: 262_140, maxTokens: 300_000, stream: stream)
        #expect(cut.status == 200, "\(cut.body.prefix(300))")
        let own = try await PairContextWindowTests.answer(bridge, prompt: 100_000, maxTokens: 8, stream: stream)
        #expect(own.status == 200, "\(own.body.prefix(300))")
        #expect(owner.reservedRequests.map(\.maxTokens) == [4, 8])
        #expect(owner.reservedRequests.map(\.promptTokens.count) == [262_140, 100_000])
        // A prompt that fills the owner's context is refused, naming it.
        let full = try await PairContextWindowTests.answer(bridge, prompt: 262_144, stream: stream)
        #expect(full.status == 400 && full.error["message"] as? String == windowRefusalWords(262_144), "\(full.error)")
        #expect(owner.reservedRequests.count == 2)
        await bridge.shutdown()
    }

    /// A request through Darkbloom (no owner's wait bound) keeps the memory plan's request: its long prompt is refused
    /// naming 65,536 tokens, its `max_tokens` cut to 32,768, and the slot reports 32,768 + 32,768 tokens.
    @Test func darkbloomsRequestKeepsTheStandardRequest() async throws {
        let owner = PairContextWindowTests.Owner()
        let bridge = try Self.bridge(owner)
        let stream = await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 100_000),
            request: .init(model: Self.model, messages: [], max_tokens: 64))
        var errors: [String] = []
        for await event in stream {
            if case .error(let message) = event { errors.append(message) }
        }
        let typed = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(errors.first ?? "")
        #expect(errors.count == 1 && typed.errorDescription == windowRefusalWords(65_536), "\(errors)")
        #expect(owner.reservedRequests.isEmpty)
        #expect(bridge.outputTokens(requested: 300_000, promptTokens: 100) == 32_768)
        #expect(bridge.outputTokens(requested: 300_000, promptTokens: 100, ownerRequest: true) == 65_536)
        #expect(bridge.outputTokens(requested: 300_000, promptTokens: 250_000, ownerRequest: true) == 12_144)
        #expect(bridge.outputTokens(requested: nil, promptTokens: 250_000, ownerRequest: true) == 12_144)
        let owned = await bridge.ownedEngine
        let engine = try #require(owned as? DistributedCBv2Engine)
        let reported = engine.requestLimits()
        #expect(reported.maxPromptTokens == 32_768 && reported.maxOutputTokens == 32_768
            && reported.maxContextTokens == 65_536)
        await bridge.shutdown()
    }

    /// `darkbloom cluster local` lists what it serves its owner.
    @Test func clusterLocalListsWhatItServesItsOwner() async throws {
        let session = LocalHostTestSession(maxPromptTokens: 8192,
            served: (promptTokens: 4_096, outputTokens: 64, contextTokens: 4_160),
            ownerServed: (promptTokens: 8_191, outputTokens: 128, contextTokens: 8_192))
        let server = DistributedLocalServer(session: session,
            config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-fixture-token"),
            tokenizerLoader: { _ in TokenizerHandle(DistributedTestTokenizer()) })
        let limits = try #require(await server.localModelLimits(session.model.publicModelID))
        #expect(limits.contextLength == 8_192 && limits.maxOutputLength == 128)
    }
}
