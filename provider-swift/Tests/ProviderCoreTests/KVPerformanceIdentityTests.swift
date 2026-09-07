import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("KV execution performance identity")
struct KVPerformanceIdentityTests {
    private let k4 = "kvq-v1:affine-v1-k4v4-g64-f32-h128-s1:prefill=direct"
    private let k8v4 = "kvq-v1:affine-v1-k8v4-g64-f32-h128-s1:prefill=direct"

    private func model(_ identity: String? = nil) -> ModelInfo {
        ModelInfo(id: "m", quantization: "4bit", sizeBytes: 100, estimatedMemoryGb: 1,
                  executionIdentity: identity)
    }
    private func slot(state: String = "idle", identity: String? = nil) -> BackendSlotCapacity {
        BackendSlotCapacity(model: "m", state: state, numRunning: 0, numWaiting: 0,
                            activeTokens: 0, maxTokensPotential: 0, executionIdentity: identity)
    }

    @Test func nativeOmissionAndBoundedMalformedValues() throws {
        #expect(KVPerformanceIdentity.normalized(nil) == nil)
        #expect(KVPerformanceIdentity.normalized("") == nil)
        for identity in [k4, k8v4] { #expect(KVPerformanceIdentity.normalized(identity) == identity) }
        for identity in ["native", k4 + "\n", "kvq-v2:any", String(repeating: "a", count: 1000)] {
            #expect(KVPerformanceIdentity.normalized(identity) == KVPerformanceIdentity.quarantine)
        }
        let encoder = JSONEncoder()
        for bytes in [try encoder.encode(model()), try encoder.encode(slot())] {
            let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(json["execution_identity"] == nil)
        }
        let declared = try JSONDecoder().decode(ModelInfo.self, from: encoder.encode(model(k4)))
        #expect(declared.executionIdentity == k4)
        let actual = try JSONDecoder().decode(BackendSlotCapacity.self, from: encoder.encode(slot(identity: k8v4)))
        #expect(actual.executionIdentity == k8v4)
        let malformed = Data(#"{"id":"m","size_bytes":100,"estimated_memory_gb":1,"execution_identity":"unexpected"}"#.utf8)
        #expect(try JSONDecoder().decode(ModelInfo.self, from: malformed).executionIdentity == KVPerformanceIdentity.quarantine)
    }

    @Test func declarationUsesExactKVPolicyAndActualMode() throws {
        var settings = BackendSettings()
        #expect(KVPerformanceIdentity.declared(model: model(), settings: settings).executionIdentity == nil)
        settings.engineV2KVQuantization = "int4"
        settings.engineV2KVQuantizationByModel = ["m": "k8v4"]
        #expect(KVPerformanceIdentity.declared(model: model(), settings: settings).executionIdentity == k8v4)
        settings.engineV2KVQuantizationByModel = ["m-other": "k8v4"]
        #expect(KVPerformanceIdentity.declared(model: model(), settings: settings).executionIdentity == k4)
        #expect(KVPerformanceIdentity.actual(format: PagedKVQuantizationConfig().identity, prefillMode: .direct) == k4)
        #expect(KVPerformanceIdentity.actual(format: PagedKVQuantizationConfig().identity,
            prefillMode: .opportunisticSDPA) == k4.replacingOccurrences(of: "direct", with: "opportunisticSDPA"))
        #expect(KVPerformanceIdentity.actual(format: nil, prefillMode: .direct) == nil)
        settings.engineV2KVQuantization = "typo"
        #expect(KVPerformanceIdentity.declared(model: model(), settings: settings).executionIdentity == KVPerformanceIdentity.quarantine)
    }

    @Test func loadedNativeWinsButPlaceholdersKeepDeclaration() {
        for state in ["running", "idle", "loading", "reloading", "idle_shutdown", "crashed", "unknown", ""] {
            let loaded = state == "running" || state == "idle"
            #expect(KVPerformanceIdentity.resolved(slot: slot(state: state), declared: model(k4)) == (loaded ? nil : k4))
            #expect(KVPerformanceIdentity.resolved(slot: slot(state: state, identity: k8v4), declared: model(k4)) == (loaded ? k8v4 : k4))
            #expect(KVPerformanceIdentity.observedRatesCompatible(slot: slot(state: state), declared: model(k4)) == loaded)
        }
        #expect(KVPerformanceIdentity.resolved(slot: nil, declared: model()) == nil)
        #expect(!KVPerformanceIdentity.observedRatesCompatible(slot: slot(identity: "bad"), declared: model()))
    }

    @Test func quantileExactAndBothFallbackTiersArePartitioned() {
        let tracker = TTFTQuantileTracker()
        let identities: [String?] = [nil, k4, k8v4]
        for (i, identity) in identities.enumerated() {
            for _ in 0..<8 {
                tracker.record(model: "m", warm: true, promptTokens: 100, activeRequestsAtDispatch: 0,
                    ttftMs: Double((i + 1) * 1000), executionIdentity: identity)
            }
        }
        for (i, identity) in identities.enumerated() {
            for (warm, prompt, batch) in [(true, 512, 0), (true, 4096, 2), (false, 4096, 4)] {
                #expect(tracker.estimate(model: "m", warm: warm, promptBucket: prompt, batchBucket: batch,
                    executionIdentity: identity)?.p50Ms == Double((i + 1) * 1000))
            }
            #expect(tracker.aggregateSampleCounts(model: "m", warm: true, executionIdentity: identity).model == 8)
        }
        #expect(tracker.estimate(model: "m", warm: true, promptBucket: 512, batchBucket: 0,
            executionIdentity: k4.replacingOccurrences(of: "direct", with: "opportunisticSDPA")) == nil)
        for i in 0..<1000 {
            tracker.record(model: "m", warm: true, promptTokens: 100, activeRequestsAtDispatch: 0,
                ttftMs: 1, executionIdentity: "bad-\(i)")
        }
        #expect(tracker.aggregateSampleCounts(model: "m", warm: true, executionIdentity: "bad").model == 0)
    }

    @Test func formatReplacementTriggersCapacityPublication() {
        let before = BackendCapacity(slots: [slot(identity: k4)], gpuMemoryActiveGb: 0,
            gpuMemoryPeakGb: 0, gpuMemoryCacheGb: 0, totalMemoryGb: 64)
        var after = before
        after.slots[0].executionIdentity = k8v4
        #expect(CapacityHeartbeatMateriality.isMaterial(previous: before, current: after))
        after.slots[0].executionIdentity = nil
        #expect(CapacityHeartbeatMateriality.isMaterial(previous: before, current: after))
        #expect(!CapacityHeartbeatMateriality.isMaterial(previous: before, current: before))
    }

    @Test func completionKeepsTheExecutionCapturedAtDispatch() {
        let tracker = TTFTQuantileTracker()
        var current = slot(identity: k4)
        let captured = KVPerformanceIdentity.resolved(slot: current, declared: model(k4))
        current = slot(identity: k8v4)
        tracker.record(model: "m", warm: true, promptTokens: 100, activeRequestsAtDispatch: 0,
            ttftMs: 1234, executionIdentity: captured)
        #expect(tracker.estimate(model: "m", warm: true, promptBucket: 512, batchBucket: 0,
            executionIdentity: KVPerformanceIdentity.resolved(slot: current, declared: model(k4))) == nil)
        #expect(tracker.estimate(model: "m", warm: true, promptBucket: 512, batchBucket: 0,
            executionIdentity: k4)?.p50Ms == 1234)
    }
}
