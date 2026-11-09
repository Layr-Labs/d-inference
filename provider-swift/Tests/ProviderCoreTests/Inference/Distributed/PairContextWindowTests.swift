import DarkbloomClusterProtocol
import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

/// A pair answers a long prompt and a large `max_tokens` as one Mac does: an
/// output past what the pair serves is cut to fit, a prompt that fills the
/// context it serves is refused in one Mac's code and words, and a request
/// both Macs' memory can't hold now gets one Mac's memory 503, each before any
/// SSE header: a streamed request never gets a 200 that then fails at once
/// ("Response generation failed", Gemma 4 26B on pair-2, 2026-11-08). The API
/// is the leader's local endpoint beside Darkbloom, which has no pair HTTP
/// writer of its own, over a fabricated pair at Gemma 4 26B's native limits.
/// No process, model or GPU.
@Suite("A pair holds every request to what it serves, as one Mac does", .serialized)
struct PairContextWindowTests {
    /// Gemma 4 26B's native limits on a pair: its declared context, the catalog's output.
    static let context = 262_144, output = 32_768
    static let model = "pair/model"

    static func profile() throws -> DistributedResidentExecutionProfile {
        try .init(id: "fabricated-greedy", vocabularySize: 100, maxPromptTokens: context - 1, maxOutputTokens: output,
            maxContextTokens: context, requestTimeout: .seconds(315), supportsLogprobs: true)
    }

    /// A pair whose ranks commit tokens until the engine declines one, and
    /// whose memory admits `servingContextTokens` now (nil: states none).
    final class Owner: DistributedResidentExecutionOwner, @unchecked Sendable {
        let identity = ScriptedPairOwner().identity
        private let lock = NSLock()
        private var requests: [CBv2Request] = []
        var servingContextTokens: Int?
        var reservedRequests: [CBv2Request] { lock.withLock { requests } }
        func readiness() -> DistributedResidentReadiness? {
            .init(identity: identity, profileID: "fabricated-greedy", requestCapacityBytes: 1 << 30,
                  servingContextTokens: lock.withLock { servingContextTokens })
        }
        func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
        func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
            .unbounded(reason: nil)
        }
        func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity, profileID: String,
                     capacityLimit: Int) throws -> any DistributedResidentRequestLease {
            lock.withLock { requests.append(request) }
            return ScriptedPairLease(identity: identity, requestID: request.id, hold: nil, acceptsCleanStop: true)
        }
        func shutdown() async {}
    }

    static func bridge(_ owner: Owner) throws -> EngineV2Bridge {
        try DistributedEngineFactory.makeBridge(owner: owner, expectedIdentity: owner.identity, profile: profile(),
            tokenizer: TokenizerHandle(FixedLengthTokenizer()), eosTokenIDs: [99])
    }

    /// The leader's local API over the pair's bridge: the status, the content
    /// type, the error object (none in an SSE body) and the body of a chat
    /// request whose prompt renders to `prompt` tokens.
    static func answer(_ bridge: EngineV2Bridge, prompt: Int, maxTokens: Int? = nil, stream: Bool) async throws
        -> (status: Int, contentType: String?, error: [String: Any], body: String) {
        let handle = TokenizerHandle(FixedLengthTokenizer(count: prompt))
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-fixture-token"),
            defaultMaxTokens: StandaloneServer.slotDefaultMaxTokens,
            acquire: { id in
                .init(tokenizer: handle, releaseToken: OneShotRelease(release: { _ in }, modelId: id),
                      modelType: nil, container: nil, isVLM: false, engineV2Bridge: bridge,
                      visionGate: VisionMemoryGate(kvBudget: nil, fp16KVBytesPerToken: 0, contextLength: 0))
            },
            tokenizerProvider: { _ in .init(tokenizer: handle, modelType: nil) },
            availableModels: { [Self.model] }, mtpSlots: { [] })
        let limit = maxTokens.map { #","max_tokens":\#($0)"# } ?? ""
        let body = #"{"model":"\#(Self.model)","stream":\#(stream)\#(limit),"messages":[{"role":"user","content":"hi"}]}"#
        let (status, contentType, text) = try await app.test(.router) { client in
            let response = try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                body: ByteBuffer(string: body))
            return (response.status.code, response.headers[.contentType], String(buffer: response.body))
        }
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        return (status, contentType, json?["error"] as? [String: Any] ?? [:], text)
    }

    /// A prompt that leaves no room in the context the pair serves is refused
    /// with one Mac's 400, `context_length_exceeded` and the words that name
    /// the context, before any SSE header, and never reaches the ranks.
    @Test(arguments: [false, true])
    func aPromptThatFillsThePairsContextIsRefusedInOneMacsWords(stream: Bool) async throws {
        let owner = Owner()
        let bridge = try Self.bridge(owner)
        for prompt in [Self.context, Self.context + 1_000] {
            let answer = try await Self.answer(bridge, prompt: prompt, stream: stream)
            #expect(answer.status == 400, "a \(prompt)-token prompt: \(answer.body.prefix(300))")
            #expect(answer.contentType == "application/json")
            #expect(answer.error["code"] as? String == "context_length_exceeded")
            #expect(answer.error["message"] as? String == windowRefusalWords(Self.context), "\(answer.error)")
        }
        #expect(owner.reservedRequests.isEmpty)
        await bridge.shutdown()
    }

    /// A `max_tokens` past what the pair serves is cut to fit, as one Mac cuts
    /// it: to the pair's output limit, and to what the prompt leaves of its
    /// context. The request is served (it was a 400 `output_too_long`).
    @Test(arguments: [false, true])
    func anOversizedMaxTokensIsCutAndServed(stream: Bool) async throws {
        let owner = Owner()
        let bridge = try Self.bridge(owner)
        let answer = try await Self.answer(bridge, prompt: Self.context - 5, maxTokens: 300_000, stream: stream)
        #expect(answer.status == 200, "\(answer.body.prefix(300))")
        #expect(answer.body.contains(#""finish_reason":"length""#))
        #expect(owner.reservedRequests.map(\.maxTokens) == [5])
        // Without the window in play, the output limit cuts it; an output within both is kept.
        #expect(bridge.outputTokens(requested: 300_000, promptTokens: 100) == Self.output)
        #expect(bridge.outputTokens(requested: 1_000, promptTokens: 100) == 1_000)
        #expect(bridge.outputTokens(requested: nil, promptTokens: 250_000) == Self.context - 250_000)
        // A prompt that fills the context is left for the pair to refuse.
        #expect(bridge.outputTokens(requested: 64, promptTokens: Self.context) == 64)
        await bridge.shutdown()
    }

    /// Within the context, both Macs' memory decides: a request longer than
    /// the context the ranks admit now gets one Mac's memory 503, before any
    /// SSE header, streamed or not.
    @Test(arguments: [false, true])
    func aRequestBothMacsMemoryCantHoldNowGetsOneMacsMemory503(stream: Bool) async throws {
        let owner = Owner()
        owner.servingContextTokens = 4_096
        let bridge = try Self.bridge(owner)
        let answer = try await Self.answer(bridge, prompt: 8, maxTokens: 8_000, stream: stream)
        #expect(answer.status == 503, "\(answer.body.prefix(300))")
        #expect(answer.contentType == "application/json")
        #expect(answer.error["message"] as? String == memoryRefusalWords)
        #expect(owner.reservedRequests.isEmpty)
        await bridge.shutdown()
    }

    /// A nonthrowing caller still reads the pair's refusal typed, in one
    /// Mac's words for the context it fills.
    @Test func theNonthrowingStreamKeepsThePairsRefusalTyped() async throws {
        let owner = Owner()
        let bridge = try Self.bridge(owner)
        let stream = await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: Self.context),
            request: .init(model: Self.model, messages: [], max_tokens: 64))
        var errors: [String] = []
        for await event in stream {
            if case .error(let message) = event { errors.append(message) }
        }
        let typed = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(errors.first ?? "")
        #expect(errors.count == 1 && typed.errorDescription == windowRefusalWords(Self.context), "\(errors)")
        #expect(ProviderLoop.mapInferenceErrorToStatus(typed) == 400)
        #expect(owner.reservedRequests.isEmpty)
        await bridge.shutdown()
    }

    /// Gemma 4's pipeline serves its whole profile, as its tensor parallel
    /// does (its stages charge a longer request at its own context); every
    /// other family's pipeline keeps the memory plan's request.
    @Test func aGemmaPipelineServesItsWholeProfile() throws {
        func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }
        func capability(_ adapter: ClusterRuntimeAdapter, model: String, profile: String, prompt: Int, output: Int,
                        context: Int) throws -> ClusterRuntimeCapability {
            try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: adapter.rawValue,
                adapterVersion: adapter.version, runtimeModelID: model, artifactSHA256: hash("b"),
                configurationSHA256: hash("c"), manifestSHA256: hash("d"),
                profile: .init(id: profile, vocabularySize: 262_144, maximumPromptTokens: prompt, maximumOutputTokens: output,
                    maximumChunkTokens: 512, maximumContextTokens: context),
                profileFingerprint: hash("e"), partitions: [.init(planSHA256: hash("f"), stages: [
                    .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 1, stagePlanSHA256: hash("1"),
                          constructionConfigurationSHA256: hash("2")),
                    .init(rank: 1, sourceLayerStart: 1, sourceLayerEnd: 2, stagePlanSHA256: hash("3"),
                          constructionConfigurationSHA256: hash("4"))])],
                arithmeticPolicyID: adapter.arithmeticPolicyID, arithmeticPolicySHA256: hash("5"),
                supportedGenerationModes: [.pipeline, .tensorParallel])
        }
        let gemma = try capability(.gemma4LayerStage, model: "registered_gemma4_26b_qat_4bit",
            profile: "registered_gemma4_26b_qat_4bit_greedy_generation_v1", prompt: 262_143, output: 32_768,
            context: 262_144)
        for mode in [ClusterGenerationMode.pipeline, .tensorParallel] {
            let served = ClusterModelFeaturePolicy.servedProfile(gemma, mode: mode)
            #expect(served == gemma.profile, "\(mode)")
            let profile = try DistributedResidentExecutionProfile(capability: gemma, generationMode: mode,
                requestTimeout: .seconds(315))
            #expect(profile.served.contextTokens == 262_144 && profile.served.promptTokens == 262_143)
        }
        let glm = try capability(.glm5NextLayerStage, model: "registered_glm53_flash",
            profile: "registered_glm53_flash_greedy_generation_v1", prompt: 1_048_575, output: 65_536,
            context: 1_048_576)
        #expect(ClusterModelFeaturePolicy.servedProfile(glm, mode: .pipeline) == glm.profile.memoryScope)
        #expect(ClusterModelFeaturePolicy.servedProfile(glm, mode: .tensorParallel) == glm.profile)
        // The one rule the worker's stages read too: only Gemma 4's pipeline serves its whole profile.
        #expect(ClusterRuntimeAdapter.allCases.filter(\.pipelineServesWholeProfile) == [.gemma4LayerStage])
    }

    /// `darkbloom cluster local` lists the context and output its mode serves,
    /// as its slot reports them, never the profile's when the mode serves less.
    @Test func clusterLocalListsWhatItsModeServes() async throws {
        let session = LocalHostTestSession(served: (promptTokens: 4_096, outputTokens: 64, contextTokens: 4_160))
        let server = DistributedLocalServer(session: session,
            config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-fixture-token"),
            tokenizerLoader: { _ in TokenizerHandle(DistributedTestTokenizer()) })
        let limits = try #require(await server.localModelLimits(session.model.publicModelID))
        #expect(limits.contextLength == 4_160 && limits.maxOutputLength == 64)
        #expect(await server.defaultMaxTokens == 64)
    }
}
