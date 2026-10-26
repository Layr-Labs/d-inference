import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Logprobs on the protected native GLM5-Next engine, built from the synthetic
/// managed fixture through the production factory and bridge. Run in an
/// isolated filtered process with `DARKBLOOM_TEST_GLM5_MANAGED_SYNTHETIC=1`.
@Suite(.serialized) struct GLM5NextLogprobsTests {
    static let enabled =
        ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_MANAGED_SYNTHETIC"] == "1"

    /// One request's text, generated-token count and bridge errors, and the
    /// entries its relay channel received when it asked for logprobs.
    struct Served: Sendable {
        var text = ""
        var generated = 0
        var errors: [String] = []
        var entries: [SSETokenLogprob] = []
    }

    /// One request through the bridge relay path; a `logprobs` request gets
    /// a relay channel.
    static func serve(bridge: EngineV2Bridge, request: ChatCompletionRequest, requestID: String,
                      prompt: [Int] = [3, 3]) async throws -> Served {
        let channel = request.logprobs == true ? EngineV2LogprobsChannel() : nil
        let stream = try await bridge.submitTokenized(
            promptTokens: prompt, request: request, requestId: requestID, cacheEnabled: false,
            logprobsChannel: channel, firstContentDeadline: nil)
        var served = Served()
        for await event in stream {
            switch event {
            case .chunk(let text): served.text += text
            case .info(_, let count, _, _): served.generated = count
            case .error(let reason): served.errors.append(reason)
            default: break
            }
        }
        served.entries = channel?.drain() ?? []
        return served
    }

    /// Runs `body` on a protected GLM bridge with embedded serial MTP, then
    /// retires it through the production retirement barrier.
    static func withProtectedBridge(
        maxConcurrentRequests: Int = 1,
        _ body: (EngineV2Bridge, EngineV2, String) async throws -> Void
    ) async throws {
        let fixture = try GLM5NextManagedFixture()
        let oldCache = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(
            fixture.directory.appendingPathComponent("isolated-cache").path)
        defer { ModelScanner.configureCacheDirectory(oldCache) }
        let budget = GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes)
        let load = try await GLM5NextManagedLoad.claim(plan: fixture.plan(), budget: budget)
        let serving = try await ModelContainerLoading.loadServingContainer(
            from: fixture.directory, modelID: fixture.catalog.id, nativeGLM5Load: load)
        let container = try #require(serving.autoregressive)
        let catalogID = fixture.catalog.id
        try #require(
            CBv2MTPConfig.envEnabled, "the protected engine requires DARKBLOOM_CBV2_MTP enabled")
        let preparation = try await EngineV2SlotFactory.glm5NextInlinePreparation(
            container: container, enabled: true)
        let mtp = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: catalogID, isVLM: false, container: container,
            specDecPreparation: preparation, maximumContextLength: 32)
        let bridge = try await container.perform { context -> EngineV2Bridge in
            try EngineV2Factory.makeBridge(
                modelId: catalogID, tokenizer: TokenizerHandle(context.tokenizer), eosTokenIds: [],
                defaultMaxTokens: 3, maxConcurrentRequests: maxConcurrentRequests, kvBytesPerToken: 1,
                kvBudget: budget
            ) {
                try EngineV2Factory.makeProductionBuild(
                    model: mtp.servingModel, modelID: catalogID, tokenizer: context.tokenizer,
                    kvBytesCapacity: 2 << 30, maxConcurrentRequests: maxConcurrentRequests, kvBudget: budget,
                    mtpDrafter: mtp.assistant?.drafter,
                    mtpConfig: .init(
                        enabled: true, maxDraftTokens: 1, maxSpeculativeBatch: 1,
                        fixedDraftTokens: 1, verificationMode: .serialTarget),
                    kvBackend: .paged, maxContextLength: 32)
            }
        }
        let engine = try #require(await bridge.ownedEngine as? EngineV2)
        #expect(engine.nativeShutdownExecutionContractID != nil)
        do {
            try await body(bridge, engine, catalogID)
        } catch {
            try? await GLM5NextRetirement.beforeRelease(bridge)
            await ModelContainerLoading.releaseExternalResources(in: container)
            throw error
        }
        try await GLM5NextRetirement.beforeRelease(bridge)
        await ModelContainerLoading.releaseExternalResources(in: container)
    }

    /// The protected native engine captures a logprob row on the relay path:
    /// one OpenAI-shaped entry per generated token with the requested
    /// alternatives, the row never drafts, the next plain request still
    /// speculates, and native work stays unfaulted.
    @Test(.enabled(if: GLM5NextLogprobsTests.enabled))
    func protectedNativeEngineServesRelayLogprobs() async throws {
        try await Self.withProtectedBridge { bridge, engine, catalogID in
            #expect(engine.acceptsLogprobRows)
            let served = try await Self.serve(
                bridge: bridge,
                request: .init(model: catalogID, messages: [], temperature: 0, max_tokens: 3,
                               logprobs: true, top_logprobs: 2),
                requestID: "glm-logprobs")
            #expect(served.errors.isEmpty && served.generated == 3, "logprobs request errors: \(served.errors)")
            #expect(served.entries.count == served.generated)
            for entry in served.entries {
                #expect(entry.logprob.isFinite && entry.logprob <= 0)
                #expect(entry.bytes == entry.token.utf8.map(Int.init))
                #expect(entry.topLogprobs.count == 2)
                // Greedy decoding samples the most likely token.
                #expect(entry.topLogprobs.first?.token == entry.token)
                #expect(entry.topLogprobs.first?.logprob == entry.logprob)
                #expect(zip(entry.topLogprobs, entry.topLogprobs.dropFirst()).allSatisfy {
                    $0.logprob >= $1.logprob
                })
            }
            #expect(try #require(engine.mtpMetricsSnapshot()).proposedTokens == 0)
            let plain = try await Self.serve(
                bridge: bridge,
                request: .init(model: catalogID, messages: [], temperature: 0, max_tokens: 8),
                requestID: "glm-plain-after-logprobs")
            #expect(plain.generated == 8 && plain.errors.isEmpty, "plain request errors: \(plain.errors)")
            #expect(try #require(engine.mtpMetricsSnapshot()).proposedTokens > 0)
            #expect(engine.nativeCompletionFault == nil)
            #expect(await bridge.canSubmitWithNativeOwner())
        }
    }

    /// A ten-step logprob row beside a concurrent plain row on another prompt
    /// carries exactly the entries it carries alone: one per generated token,
    /// the same tokens, text and values. The logprob row never drafts. GLM's
    /// MTP has no request-scoped fallback, so the plain row decodes
    /// target-only while the logprob row is live; it emits its solo text and
    /// drafts again once the logprob row finishes.
    @Test(.enabled(if: GLM5NextLogprobsTests.enabled))
    func logprobRowKeepsItsEntriesBesideAConcurrentPlainRow() async throws {
        try await Self.withProtectedBridge(maxConcurrentRequests: 2) { bridge, engine, catalogID in
            let steps = 10, plainSteps = 20, top = 3
            let prompt = [3, 3], neighbor = [5, 7, 2]
            let logprobRequest = ChatCompletionRequest(model: catalogID, messages: [], temperature: 0,
                max_tokens: steps, logprobs: true, top_logprobs: top)
            let plainRequest = ChatCompletionRequest(model: catalogID, messages: [], temperature: 0,
                max_tokens: plainSteps)
            let solo = try await Self.serve(bridge: bridge, request: logprobRequest,
                requestID: "glm-logprobs-solo", prompt: prompt)
            #expect(solo.errors.isEmpty && solo.generated == steps, "solo errors: \(solo.errors)")
            #expect(solo.entries.count == steps && solo.entries.map(\.token).joined() == solo.text)
            #expect(try #require(engine.mtpMetricsSnapshot()).proposedTokens == 0,
                "a logprob row must never draft")
            let plainSolo = try await Self.serve(bridge: bridge, request: plainRequest,
                requestID: "glm-plain-solo", prompt: neighbor)
            #expect(plainSolo.generated == plainSteps && plainSolo.errors.isEmpty)
            let before = try #require(engine.mtpMetricsSnapshot()).proposedTokens

            async let plain = Self.serve(bridge: bridge, request: plainRequest,
                requestID: "glm-plain-beside-logprobs", prompt: neighbor)
            async let batched = Self.serve(bridge: bridge, request: logprobRequest,
                requestID: "glm-logprobs-beside-plain", prompt: prompt)
            let (plainRun, logprobRun) = try await (plain, batched)
            #expect(plainRun.generated == plainSteps && plainRun.errors.isEmpty, "plain errors: \(plainRun.errors)")
            #expect(plainRun.text == plainSolo.text, "the logprob row changed the plain row's text")
            #expect(logprobRun.errors.isEmpty && logprobRun.generated == steps,
                "batched errors: \(logprobRun.errors)")
            #expect(logprobRun.entries.count == steps)
            #expect(logprobRun.text == solo.text)
            #expect(logprobRun.entries.map(\.token) == solo.entries.map(\.token))
            for (index, (entry, reference)) in zip(logprobRun.entries, solo.entries).enumerated() {
                #expect(abs(entry.logprob - reference.logprob) < 1e-4, "step \(index) logprob drifted")
                #expect(entry.topLogprobs.map(\.token) == reference.topLogprobs.map(\.token),
                    "step \(index) alternatives changed")
                #expect(entry.topLogprobs.first?.logprob == entry.logprob)
            }
            #expect(try #require(engine.mtpMetricsSnapshot()).proposedTokens > before,
                "the plain row must draft again after the logprob row finishes")
            #expect(engine.nativeCompletionFault == nil)
            #expect(await bridge.canSubmitWithNativeOwner())
        }
    }
}
