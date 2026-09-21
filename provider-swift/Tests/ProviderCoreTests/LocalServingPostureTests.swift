import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Local serving posture is observed, not inferred")
struct LocalServingPostureTests {
    private func sample(persistent: Bool? = nil, pageSize: Int? = nil) -> MTPSlotMetricsSample {
        .init(model: "owned", snapshot: .init(
            status: .disabled(.configDisabled, configured: false), metrics: nil),
            posture: .init(backend: .paged,
                capacity: .init(activeRequests: 2, waitingRequests: 3,
                    kvBytesInUse: 400, kvBytesCapacity: 800,
                    kvBytesBackendCapacity: 700, kvBytesReserved: 500, activeTokens: 4),
                pageSize: pageSize,
                prefix: .init(modelId: "owned", backend: .paged,
                    replayStrategy: .direct, state: .ready, reason: .ready),
                completeKeyPersistent: persistent))
    }

    @Test func missingPageAndKeyFactsAreOmitted() {
        let text = LocalServingPostureRenderer.render([sample()])
        #expect(text.contains("kv_backend_info{model=\"owned\",backend=\"paged\"} 1"))
        #expect(text.contains("kv_active_requests{model=\"owned\"} 2"))
        #expect(text.contains("kv_waiting_requests{model=\"owned\"} 3"))
        #expect(!text.contains("paged_kv_page_size"))
        #expect(!text.contains("paged_kv_live_bytes"))
        #expect(!text.contains("complete_prefix_key_persistent"))
        // Generic admission bytes above are not physical page ownership.
        #expect(!text.contains(" 400"))
    }

    @Test func keyDurabilityRemainsSeparateFromReadyState() {
        for persistent in [false, true] {
            let text = LocalServingPostureRenderer.render([sample(persistent: persistent, pageSize: 32)])
            #expect(text.contains("paged_kv_page_size{model=\"owned\"} 32"))
            #expect(text.contains("state=\"ready\",reason=\"ready\""))
            #expect(text.contains("complete_prefix_key_persistent{model=\"owned\"} \(persistent ? 1 : 0)"))
            #expect(!text.contains("cached_tokens"))
        }
    }

    @Test func drainedBridgeDoesNotPublishLivePosture() async {
        let bridge = EngineV2Bridge(engine: InertStubEngine(), modelId: "owned",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [],
            kvBackendKind: .paged, pagedPageSize: 32)
        let observedPageSize = await bridge.pagedPageSize
        #expect(observedPageSize == 32)
        #expect(await bridge.localMetricsSample(model: "owned") != nil)
        await bridge.shutdown()
        #expect(await bridge.localMetricsSample(model: "owned") == nil)
    }
}
