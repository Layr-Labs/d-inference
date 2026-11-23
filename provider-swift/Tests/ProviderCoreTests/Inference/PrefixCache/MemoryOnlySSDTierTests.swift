import Foundation
import MLX
@testable import MLXLMCommon
import Testing

@testable import ProviderCore

/// Every test that reads `RequestCachePolicyCounters` (process-wide) runs in
/// this one serialized suite, so no other test moves the SSD counts it checks.
/// Coordinator requests of suites running alongside it still count, the
/// managed Super slot's `memory_only` ones included, so request counts are
/// checked as lower bounds. `SSDPrefixCacheTests.swift` adds the attention
/// tier's case.
@Suite("memory_only requests and the SSD tier", .serialized)
struct MemoryOnlySSDTierTests {
    /// Every file under `root` with its size and modification time.
    private static func files(under root: URL) throws -> [String: String] {
        let enumerator = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]))
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            result[String(url.path.dropFirst(root.path.count))] = "\(values.fileSize ?? -1)@\(modified)"
        }
        return result
    }

    @Test("a memory-only receipt never stages, donates, registers or publishes on the complete-checkpoint tier")
    func completeStoreRefusesMemoryOnlyReceipts() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        defer { store.close() }
        #expect(try await fixture.donate(store, receipt: 10, position: 256) == [256])
        let before = try Self.files(under: fixture.root)
        let counts = RequestCachePolicyCounters.shared.snapshot

        let marked = CBv2RequestID(11 | MemoryOnlyReceipt.bit)
        let tokens = fixture.tokens
        let positions = try await fixture.donate(store, fixture.source(position: 512), receipt: marked.raw)
        var request = fixture.request()
        request.prefixCacheReceiptID = marked
        let staged = await store.stage(requestID: marked, request: request,
                                       reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        let taken = store.takeStaged(requestID: marked, tokens: tokens, cacheSalt: "tenant-a",
                                     maximumSequenceLength: 1024)
        store.registerReadyReceipt(requestID: marked, promptTokens: tokens, cacheScope: "tenant-a") { _ in
            Issue.record("a memory-only receipt got a ready receipt")
        }
        store.registerDonationDemand(.init(repeatedPrefixTokens: 4096), requestID: marked)
        store.publishReady(requestID: marked, positions: [256])
        await store.waitForWritesForTesting()
        let after = RequestCachePolicyCounters.shared.snapshot

        #expect(positions.isEmpty && taken == nil)
        #expect(staged.disposition == .skippedPolicy && staged.stageMs == 0)
        #expect(try Self.files(under: fixture.root) == before, "no file was read into recency, written or touched")
        #expect(store.lock.withLock { store.readyReceipts[marked] == nil && store.stages[marked] == nil })
        #expect(after.ssdRefusals - counts.ssdRefusals == 2, "the engine's donation and stage take")
        #expect(after.ssdTierTouches - counts.ssdTierTouches == 4, "stage, ready receipt, demand hint, publication")
    }

    #if DEBUG
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
                provider: ProviderSettings(name: "memory-only-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
        return try ProviderLoop(config: config, attestationSigner: nil)
    }

    /// One coordinator request through `handleInferenceRequest` on a slot
    /// whose complete-checkpoint store writes for an unmarked request.
    private func serve(
        _ loop: ProviderLoop, requestID: String, cacheMember: [String: Any]?
    ) async throws -> [OutboundMessage] {
        let receiver = NodeKeyPair.generate()
        let recorder = CancelledPrefixRecorder(receiver: receiver)
        var body: [String: Any] = [
            "model": "fixture-model", "messages": [["role": "user", "content": "fixture"]],
            "temperature": 0, "max_tokens": 2, "stream": true, "reasoning_parser": "none",
        ]
        if let cacheMember { body["_darkbloom_cache"] = cacheMember }
        let encrypted = try receiver.encrypt(
            recipientPublicKey: await loop.keyPair.publicKeyBytes,
            plaintext: try JSONSerialization.data(withJSONObject: body))
        await loop.handleInferenceRequest(
            requestId: requestID, ciphertext: encrypted, senderPublicKey: receiver.publicKeyBytes,
            cacheReceiptNonce: "nonce-" + requestID, authenticatedCacheScope: "tenant-a",
            prefixCacheProtocol: 2, cacheReceiptBoundaryMode: "checkpoint",
            send: SendHandle(recorder.record))
        #expect(await recorder.terminal.wait(), "\(recorder.diagnosticSummary)")
        return recorder.snapshot
    }

    @Test("a memory_only request through the handler leaves the SSD directory unchanged; an unmarked one writes")
    func handlerLeavesTheSSDTierUnchanged() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true)
        defer { fixture.remove() }
        let store = try fixture.makeStore(useGlobalBudget: false)
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
        await runtime.register(modelId: "fixture-model", bridge: bridge)
        let loop = try makeLoop()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.installModelSlotForTesting(
            modelId: "fixture-model", container: cancelledPrefixContainer(tokenizer: tokenizer),
            tokenizer: TokenizerHandle(tokenizer), engineV2: bridge,
            sizing: .init(weightsBytes: 0, fp16KVBytesPerToken: 128,
                          maxContextLength: 8192, defaultMaxTokens: 4096))
        let before = try Self.files(under: fixture.root)
        let counts = RequestCachePolicyCounters.shared.snapshot

        // Marked with no nonce or scope, as the coordinator marks a request.
        let marked = try await serve(loop, requestID: "marked", cacheMember: ["cache_policy": "memory_only"])
        await store.waitForWritesForTesting()
        let afterMarked = try Self.files(under: fixture.root)
        let counted = RequestCachePolicyCounters.shared.snapshot

        #expect(marked.contains { if case .inferenceComplete = $0 { true } else { false } })
        #expect(afterMarked == before, "no new or modified file, the epoch record included")
        #expect(!marked.contains { if case .prefixCacheLookupV2 = $0 { true } else { false } },
                "no SSD-tier evidence, which would take a sequence from the epoch record")
        #expect(counted.memoryOnlyRequests > counts.memoryOnlyRequests)
        #expect(counted.ssdTierTouches == counts.ssdTierTouches && counted.ssdRefusals == counts.ssdRefusals)
        #expect(store.stats().filesWritten == 0 && store.stats().filesRead == 0)

        // The control: the same request, unmarked, writes its checkpoint.
        let unmarked = try await serve(loop, requestID: "unmarked", cacheMember: nil)
        await store.waitForWritesForTesting()
        #expect(unmarked.contains { if case .inferenceComplete = $0 { true } else { false } })
        #expect(store.stats().filesWritten > 0)
        #expect(try Self.files(under: fixture.root) != afterMarked)
        let afterUnmarked = RequestCachePolicyCounters.shared.snapshot
        #expect(afterUnmarked.defaultRequests > counted.defaultRequests)

        await bridge.shutdown()
        _ = await runtime.unregister(modelId: "fixture-model")
    }
    #endif
}
