import Foundation
import MLX
@testable import MLXLMCommon
import Testing

@testable import ProviderCore

#if DEBUG
@Suite("Provider cancellation after actual SSD lookup", .serialized)
struct ProviderCancelledPrefixCacheTests {
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
                provider: ProviderSettings(name: "cancel-prefix-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
        return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
    }

    @Test("partial cancellation waits for native paged usage before lookup and provider terminal",
          arguments: [true, false])
    func actualRestoredCancellationSettlesBeforeTerminal(donate: Bool) async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true)
        defer { fixture.remove() }
        let store = try fixture.makeStore(useGlobalBudget: false)
        let model = CancelledPrefixModel()
        let tokenizer = CancelledPrefixTokenizer(prompt: fixture.tokens)
        let backend = try PagedKVBackend(layerKinds: model.kinds, config: .init(
            capacityBytes: 128 << 20, dtype: .float32, maxPrefillChunk: 256,
            segmentSizeBytes: 64 << 10, layerDTypes: [.float32]))
        let owned = EngineV2(
            model: model, layerKinds: model.kinds,
            backend: backend,
            cacheProvider: CBv2LayerCacheBank(layerKinds: model.kinds),
            detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: tokenizer),
            schedulerConfig: .init(
                maxConcurrentRequests: 1, maxBatchedTokensPerStep: 256,
                prefillChunkSize: 256, maxWaiting: 4, enablePrefixCache: true),
            completePrefixCache: store)
        let bridge = EngineV2Bridge(
            engine: owned, modelId: "fixture-model", tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [], prefillDeadlineMode: .off,
            ssdHybridCheckpointStore: store, kvBackendKind: .paged)
        let runtime = EngineV2Runtime()
        let receiver = NodeKeyPair.generate()
        let recorder = CancelledPrefixRecorder(receiver: receiver)
        func retire() async {
            recorder.releaseNative.signal()
            await bridge.shutdown()
            _ = await runtime.unregister(modelId: "fixture-model")
        }
        do {
            #expect(bridge.ssdHybridCheckpointStore === store)

            if donate {
                // A real native donor creates the encrypted checkpoint used below.
                let ready = CancelledPrefixBarrier()
                let donor = await bridge.submitTokenized(
                    promptTokens: fixture.tokens,
                    request: ChatCompletionRequest(
                        model: "fixture-model", messages: [], temperature: 0, max_tokens: 1),
                    requestId: "native-donor", cacheScope: "tenant-a",
                    usageSignal: EngineV2RequestUsageSignal(onCacheReady: { _ in ready.signal() }))
                var donorContentTokens = 0
                var donorCompletionTokens: Int?
                var donorFailed = false
                for await event in donor {
                    switch event {
                    case .chunk(let text): donorContentTokens += text.count
                    case .info(_, let completion, _, _): donorCompletionTokens = completion
                    case .error, .terminal: donorFailed = true
                    }
                }
                try #require(!donorFailed && donorCompletionTokens == 1 && donorContentTokens == 1,
                             "donor must complete normally with one delivered fixture token")
                #expect(await ready.wait())
                #expect(store.stats().filesWritten > 0)
                #expect(FileManager.default.fileExists(atPath: fixture.file(store, position: 512).path))
            }

            let loop = try makeLoop()
            await runtime.register(modelId: "fixture-model", bridge: bridge)
            await loop.setEngineV2RuntimeForTesting(runtime)
            await loop.installModelSlotForTesting(
                modelId: "fixture-model", container: cancelledPrefixContainer(tokenizer: tokenizer),
                tokenizer: TokenizerHandle(tokenizer), engineV2: bridge,
                sizing: .init(weightsBytes: 0, fp16KVBytesPerToken: 128,
                              maxContextLength: 8192, defaultMaxTokens: 4096))
            await bridge._testInstallCancelledSettlementHooks(
                beforeNativeTerminal: { await recorder.holdNative($0) },
                onSettlementWait: { recorder.recordDecision("settlement_wait") })
            let request = try JSONSerialization.data(withJSONObject: [
                "model": "fixture-model", "messages": [["role": "user", "content": "fixture"]],
                "temperature": 0, "max_tokens": 4096, "stream": true,
                // This synthetic model emits plain text without reasoning tags.
                "reasoning_parser": "none",
            ])
            let providerKey = await loop.keyPair.publicKeyBytes
            let encrypted = try receiver.encrypt(recipientPublicKey: providerKey, plaintext: request)
            await loop.handleInferenceRequest(
                requestId: "coordinator-cancel", ciphertext: encrypted,
                senderPublicKey: receiver.publicKeyBytes, cacheReceiptNonce: "cancel-nonce",
                authenticatedCacheScope: "tenant-a", prefixCacheProtocol: 2,
                cacheReceiptBoundaryMode: "checkpoint", send: SendHandle(recorder.record))
            let receivedContent = await recorder.firstContent.wait()
            // Capture after the await explicitly; macro argument evaluation
            // must not decide which instant a failed-precondition report sees.
            let capacity = owned.capacity()
            let diagnostic = recorder.diagnosticSummary
                + ", active=\(capacity.activeRequests), waiting=\(capacity.waitingRequests)"
                + ", kv_in_use=\(capacity.kvBytesInUse), kv_capacity=\(capacity.kvBytesCapacity)"
                + ", backend_capacity=\(capacity.kvBytesBackendCapacity)"
                + ", kv_reserved=\(capacity.kvBytesReserved), active_tokens=\(capacity.activeTokens)"
                + ", steps=\(capacity.stepsExecuted), decode_rows=\(capacity.decodeRowsTotal)"
            try #require(receivedContent, "partial-output precondition: \(diagnostic)")
            await loop.handleCancellation(requestId: "coordinator-cancel")
            #expect(await recorder.nativeFinished.wait())
            #expect(await recorder.decision.wait())
            let actual = try #require(recorder.observedNativeUsage)
            #expect(actual.prefixCacheOutcome == (donate ? .hit : .miss))
            if donate { #expect(actual.prefixCacheTier == .snapshot) }
            let cachedTokens = donate ? 512 : 0
            #expect(actual.prefixCacheMatchedTokens == cachedTokens)
            #expect(actual.prefixCachePrefillTokensSaved == cachedTokens)
            #expect(recorder.decisionValue == "settlement_wait",
                    "the old handler sent its terminal before the held native usage")
            #expect(recorder.snapshot.allSatisfy {
                if case .inferenceComplete = $0 { return false }
                if case .inferenceError = $0 { return false }
                return true
            })

            recorder.releaseNative.signal()
            #expect(await recorder.terminal.wait())
            let messages = recorder.snapshot
            var order: [String] = []
            var usages: [UsageInfo] = []
            var lookupCount = 0
            for message in messages {
                switch message {
                case .prefixCacheLookupV2(let lookup):
                    lookupCount += 1
                    order.append("lookup")
                    #expect(lookup.outcome == (donate ? .hit : .missAbsent) && lookup.tier == .ssd)
                    #expect(lookup.matchedAnchor?.tokenCount == (donate ? 512 : nil))
                    #expect(lookup.expectedPrefillTokensSaved == UInt64(cachedTokens))
                case .inferenceComplete(_, let usage, _, _, _, _):
                    order.append("complete")
                    usages.append(usage)
                case .inferenceError:
                    order.append("error")
                default: break
                }
            }
            #expect(order == ["lookup", "complete"])
            #expect(lookupCount == 1 && usages.count == 1)
            let usage = try #require(usages.first)
            #expect(usage.cacheOutcome == (donate ? .hit : .missAbsent) && usage.cacheTier == .ssd)
            #expect(usage.cachedTokens == UInt64(cachedTokens)
                    && usage.prefillTokensSaved == UInt64(cachedTokens))
            #expect(usage.completionTokens > 0)
            #expect(usage.completionTokens == UInt64(recorder.deliveredTokenCount),
                    "settlement bills exactly the fixture tokens actually delivered")
            #expect(usage.completionTokens <= UInt64(actual.completionTokens),
                    "only delivered output is settled; native tail work is not added to billing")
            #expect(store.stats().stagedBytesInUse == 0)
            #expect(store.lock.withLock { store.readyReceipts.isEmpty })
        } catch {
            await retire()
            throw error
        }
        await retire()
        #expect(await bridge._testLivePumpCount() == 0)
    }
}
#endif
