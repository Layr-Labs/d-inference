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

    /// Generated tokens of a plain request, with any bridge errors.
    static func serve(bridge: EngineV2Bridge, request: ChatCompletionRequest,
                      requestID: String) async -> (tokens: Int, errors: [String]) {
        let stream = await bridge.submitTokenized(
            promptTokens: [3, 3], request: request, requestId: requestID, cacheEnabled: false)
        var tokens = 0
        var errors: [String] = []
        for await event in stream {
            if case .info(_, let count, _, _) = event { tokens = count }
            if case .error(let reason) = event { errors.append(reason) }
        }
        return (tokens, errors)
    }

    /// Runs `body` on a protected GLM bridge with embedded serial MTP, then
    /// retires it through the production retirement barrier.
    static func withProtectedBridge(
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
                defaultMaxTokens: 3, maxConcurrentRequests: 1, kvBytesPerToken: 1, kvBudget: budget
            ) {
                try EngineV2Factory.makeProductionBuild(
                    model: mtp.servingModel, modelID: catalogID, tokenizer: context.tokenizer,
                    kvBytesCapacity: 2 << 30, maxConcurrentRequests: 1, kvBudget: budget,
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
            let channel = EngineV2LogprobsChannel()
            let stream = try await bridge.submitTokenized(
                promptTokens: [3, 3],
                request: .init(model: catalogID, messages: [], temperature: 0, max_tokens: 3,
                               logprobs: true, top_logprobs: 2),
                requestId: "glm-logprobs", cacheEnabled: false, logprobsChannel: channel,
                firstContentDeadline: nil)
            var generated = 0
            var errors: [String] = []
            for await event in stream {
                if case .info(_, let count, _, _) = event { generated = count }
                if case .error(let reason) = event { errors.append(reason) }
            }
            let entries = channel.drain()
            #expect(errors.isEmpty && generated == 3, "logprobs request errors: \(errors)")
            #expect(entries.count == generated)
            for entry in entries {
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
            let plain = await Self.serve(
                bridge: bridge,
                request: .init(model: catalogID, messages: [], temperature: 0, max_tokens: 8),
                requestID: "glm-plain-after-logprobs")
            #expect(plain.tokens == 8 && plain.errors.isEmpty, "plain request errors: \(plain.errors)")
            #expect(try #require(engine.mtpMetricsSnapshot()).proposedTokens > 0)
            #expect(engine.nativeCompletionFault == nil)
            #expect(await bridge.canSubmitWithNativeOwner())
        }
    }
}
