import Foundation
import MLX
@testable import MLXLMCommon
import Testing

@testable import ProviderCore

#if DEBUG
/// Two sealed `memory_only` requests with the same prefix through
/// `handleInferenceRequest`, on a real engine with a complete-checkpoint store
/// and its RAM-only tier: the second restores the first's checkpoint from RAM,
/// and the SSD directory is left exactly as it was.
@Suite("memory_only requests reuse a prefix from RAM only", .serialized)
struct MemoryOnlyPrefixCacheHandlerTests {
    private func makeLoop() throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max",
                chipFamily: .m4, chipTier: .max, memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: "memory-only-handler-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
        return try ProviderLoop(config: config, attestationSigner: nil)
    }

    @Test("the second marked request reports cached tokens from RAM; the SSD directory is unchanged")
    func secondMarkedRequestRestoresFromRAM() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true)
        defer { fixture.remove() }
        let pool = MemoryOnlyCheckpointPool()
        pool.setBudget(1 << 30)
        let tier = MemoryOnlyCheckpointTier(
            config: .init(identity: fixture.identity, backendLayout: fixture.backendLayout, minEffectiveTokens: 256),
            kvBudget: nil, pool: pool)
        let store = try fixture.makeStore(useGlobalBudget: false, memoryOnlyTier: tier)
        let ssdBefore = MemoryOnlyCheckpointTierTests.listing(fixture.root)
        let model = CancelledPrefixModel()
        let tokenizer = CancelledPrefixTokenizer(prompt: fixture.tokens)
        let backend = try PagedKVBackend(layerKinds: model.kinds, config: .init(
            capacityBytes: 128 << 20, dtype: .float32, maxPrefillChunk: 256,
            segmentSizeBytes: 64 << 10, layerDTypes: [.float32]))
        let engine = EngineV2(
            model: model, layerKinds: model.kinds, backend: backend,
            cacheProvider: CBv2LayerCacheBank(layerKinds: model.kinds),
            detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: tokenizer),
            schedulerConfig: .init(
                maxConcurrentRequests: 1, maxBatchedTokensPerStep: 256,
                prefillChunkSize: 256, maxWaiting: 4, enablePrefixCache: true),
            completePrefixCache: store)
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "fixture-model", tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [], prefillDeadlineMode: .off,
            ssdHybridCheckpointStore: store, kvBackendKind: .paged)
        let runtime = EngineV2Runtime()
        let loop = try makeLoop()
        await runtime.register(modelId: "fixture-model", bridge: bridge)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.installModelSlotForTesting(
            modelId: "fixture-model", container: cancelledPrefixContainer(tokenizer: tokenizer),
            tokenizer: TokenizerHandle(tokenizer), engineV2: bridge,
            sizing: .init(weightsBytes: 0, fp16KVBytesPerToken: 128,
                          maxContextLength: 8192, defaultMaxTokens: 4096))
        let touchesBefore = RequestCachePolicyCounters.shared.snapshot.ssdTierTouches

        func send(_ id: String) async throws -> UsageInfo {
            let receiver = NodeKeyPair.generate()
            let recorder = CancelledPrefixRecorder(receiver: receiver)
            let body = try JSONSerialization.data(withJSONObject: [
                "model": "fixture-model", "messages": [["role": "user", "content": "fixture"]],
                "temperature": 0, "max_tokens": 2, "stream": true, "reasoning_parser": "none",
                "_darkbloom_cache": ["cache_policy": "memory_only"],
            ] as [String: Any])
            let encrypted = try receiver.encrypt(
                recipientPublicKey: await loop.keyPair.publicKeyBytes, plaintext: body)
            await loop.handleInferenceRequest(
                requestId: id, ciphertext: encrypted, senderPublicKey: receiver.publicKeyBytes,
                cacheReceiptNonce: "nonce-\(id)", authenticatedCacheScope: "tenant-a",
                prefixCacheProtocol: 2, cacheReceiptBoundaryMode: "checkpoint", send: SendHandle(recorder.record))
            #expect(await recorder.terminal.wait(), "terminal: \(recorder.diagnosticSummary)")
            let usages = recorder.snapshot.compactMap { message -> UsageInfo? in
                if case .inferenceComplete(_, let usage, _, _, _, _, _) = message { return usage }
                return nil
            }
            #expect(!recorder.snapshot.contains {
                if case .prefixCacheLookupV2 = $0 { return true }
                return false
            }, "a memory_only request sends no SSD-tier evidence")
            return try #require(usages.first, "usage: \(recorder.diagnosticSummary)")
        }

        let first = try await send("memory-only-first")
        #expect(first.cachedTokens == 0)
        // The donor publishes once its terminal is out; the deepest checkpoint is held then.
        let published = ContinuousClock.now + .seconds(10)
        while pool.snapshot.entries < 2, ContinuousClock.now < published {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(pool.snapshot.entries == 2, "both 256-token checkpoints are held in RAM")

        let second = try await send("memory-only-second")
        #expect(second.cachedTokens == 512 && second.prefillTokensSaved == 512)
        #expect(second.cacheTier == .memory && second.cacheOutcome == .hit)
        #expect(pool.snapshot.lookups[.hit] == 1 && pool.snapshot.unmarkedRefusals == 0)

        #expect(store.stats().filesWritten == 0 && store.stats().stages == 0)
        #expect(RequestCachePolicyCounters.shared.snapshot.ssdTierTouches == touchesBefore)
        await bridge.shutdown()
        _ = await runtime.unregister(modelId: "fixture-model")
        #expect(pool.snapshot.entries == 0, "unload releases the slot's RAM entries")
        #expect(MemoryOnlyCheckpointTierTests.listing(fixture.root) == ssdBefore)
    }
}
#endif
