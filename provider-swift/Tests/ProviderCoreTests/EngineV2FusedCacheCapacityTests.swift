// Copyright © 2026 Eigen Labs.
//
// PR#508 finding 2 — the v2 engine's static KV admission ceiling (which
// becomes heartbeat `active_token_budget_max`, the coordinator's admission
// input) is derived from WEIGHTS before the VLM text extraction materializes
// the shared MoE fused gate+up cache (~8–15 GiB on Gemma 4). Post-fix the
// slot factory nets the MEASURED cache out of the ceiling
// (`EngineV2KVSizing.netOfEngineResidentOverhead`) and the residency sums
// (later engine sizings, heartbeat fleet clamp) count it like weights, so
// heartbeat max, engine admission, and the shared KV gate agree.
//
// These tests pin that consistency on the incident's simulated 64 GB
// profile (26 GiB weights + 15 GiB fused cache — the gemma-4-26b-8bit
// shape) at scripted-stub level: no model weights, no network. The live
// counterpart (real checkpoint, real extraction) is
// `GemmaVLMParityProbeMemoryLiveTests`.

import Foundation
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024

// MARK: - Stubs

/// Engine stub reporting a fixed construction grant — what the bridge's
/// heartbeat path reads back through `capacity().kvBytesCapacity`.
private final class FixedCapacityEngine: CBv2Engine, @unchecked Sendable {
    let kvBytesCapacity: Int
    init(kvBytesCapacity: Int) { self.kvBytesCapacity = kvBytesCapacity }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        continuation.finish()
        return stream
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: kvBytesCapacity, activeTokens: 0)
    }
    func shutdown() async {}
}

private struct NoopTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}

@Suite("EngineV2 fused-cache capacity accounting (PR#508 finding 2)")
struct EngineV2FusedCacheCapacityTests {

    // The incident profile: 64 GB box, gemma-4-26b-8bit (26 GiB weights,
    // 15 GiB measured fused cache), fp16 KV rate 20 480 B/token.
    private static let physical = 64 * gib
    private static let weights = Int(26 * gib)
    private static let fused = Int(15 * gib)
    private static let kvBytesPerToken = 20_480

    @Test("netOfEngineResidentOverhead: identity at 0, subtraction, clamps")
    func netOfOverheadArithmetic() {
        #expect(EngineV2KVSizing.netOfEngineResidentOverhead(100, overheadBytes: 0) == 100)
        #expect(EngineV2KVSizing.netOfEngineResidentOverhead(100, overheadBytes: 40) == 60)
        // The cache consumed the whole budget → 0 → makeProductionEngine
        // throws noKVHeadroom → legacy fallback (never a negative ceiling).
        #expect(EngineV2KVSizing.netOfEngineResidentOverhead(100, overheadBytes: 100) == 0)
        #expect(EngineV2KVSizing.netOfEngineResidentOverhead(100, overheadBytes: 250) == 0)
        // Defensive inputs.
        #expect(EngineV2KVSizing.netOfEngineResidentOverhead(-5, overheadBytes: 10) == 0)
        #expect(EngineV2KVSizing.netOfEngineResidentOverhead(100, overheadBytes: -10) == 100)
    }

    @Test("advertised token max reflects post-cache headroom on the 64 GB profile")
    func advertisedTokenMaxReflectsPostCacheHeadroom() async {
        let base = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: Self.weights, coResidentWeightBytes: 0,
            existingEngineKVCapacities: [], physicalBytes: Self.physical)
        let granted = EngineV2KVSizing.netOfEngineResidentOverhead(
            base, overheadBytes: Self.fused)

        // The grant is the weights-derived budget minus EXACTLY the cache —
        // the pre-fix over-advertise was the cache size, byte for byte.
        #expect(
            UInt64(granted)
                == UnifiedMemoryCap.kvBudgetBytes(
                    physicalBytes: Self.physical, residentWeightBytes: UInt64(Self.weights))
                    - UInt64(Self.fused))
        #expect(base - granted == Self.fused)

        // Heartbeat: the fleet clamp recomputed from OVERHEAD-INCLUSIVE
        // residency (weights + fused — what ProviderLoop+Capacity now sums)
        // equals the adjusted grant, so the reported budget is neither
        // inflated back to the stale weights-only figure nor double-shrunk.
        let clamp = EngineV2KVSizing.liveEngineKVBytesBudget(
            grantedKVBytesCapacity: granted,
            totalResidentWeightBytes: UInt64(Self.weights + Self.fused),
            otherEngineKVCapacities: [],
            physicalBytes: Self.physical)
        #expect(clamp == granted)

        // …and the wire figure a coordinator admission gate consumes.
        let bridge = EngineV2Bridge(
            engine: FixedCapacityEngine(kvBytesCapacity: granted),
            modelId: "gemma-4-26b-8bit",
            tokenizer: TokenizerHandle(NoopTokenizer()),
            eosTokenIds: [2],
            extraEOSTokens: [],
            defaultMaxTokens: 4096,
            maxConcurrentRequests: 4,
            kvBytesPerToken: Self.kvBytesPerToken,
            kvBudget: nil,
            emitTelemetry: { _ in })
        let slot = await bridge.backendSlotCapacity(kvBytesBudgetClamp: clamp)
        #expect(slot.activeTokenBudgetMax == Int64(granted / Self.kvBytesPerToken))
        // Regression: the pre-fix advertised max (weights-only ceiling).
        #expect(slot.activeTokenBudgetMax < Int64(base / Self.kvBytesPerToken))
    }

    @Test("a request stream sized to the advertised max is admitted by the shared gate")
    func sharedGateAdmitsStreamSizedToAdvertisedMax() async {
        let base = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: Self.weights, coResidentWeightBytes: 0,
            existingEngineKVCapacities: [], physicalBytes: Self.physical)
        let granted = EngineV2KVSizing.netOfEngineResidentOverhead(
            base, overheadBytes: Self.fused)
        let advertisedTokens = granted / Self.kvBytesPerToken

        // The shared gate views the REAL post-load memory state: weights +
        // ONE fused cache resident in MLX active. capFraction/activation
        // reserve stay nil so the gate resolves the SAME defaults the static
        // sizing above used — the consistency under test.
        let budget = GlobalKVCacheBudget(
            memorySnapshot: {
                GlobalKVCacheBudget.MemorySnapshot(
                    total: Self.physical,
                    active: UInt64(Self.weights + Self.fused),
                    cache: 0,
                    systemAvailable: .max)
            })

        // Four concurrent requests summing to the advertised max: every one
        // admitted, no rejects — the coordinator routing to the advertised
        // budget never trips the gate.
        for i in 0 ..< 4 {
            #expect(
                await budget.reserve(
                    requestID: "advertised-\(i)",
                    kvBytesPerToken: Self.kvBytesPerToken,
                    tokenCount: advertisedTokens / 4),
                "request \(i) of an advertised-max stream was rejected by the shared gate")
        }

        // Regression: the PRE-FIX advertised budget (weights-only) exceeds
        // the gate's headroom by the cache size — the excess the coordinator
        // used to over-route is exactly what the gate rejects.
        #expect(
            !(await budget.reserveBytes(
                requestID: "prefix-excess", bytes: UInt64(base - granted))))
    }

    @Test("a later engine's ceiling counts the first slot's fused cache like weights")
    func laterEngineSizingCountsFusedOverhead() {
        let physical = 64 * gib
        let wA = Int(8 * gib)
        let fA = Int(4 * gib)
        let wB = Int(8 * gib)
        // First engine granted under a tighter construction view (mirrors
        // `pureSizingSumsWithinBudget`), then netted of its fused cache.
        let grantA = EngineV2KVSizing.netOfEngineResidentOverhead(
            Int(10 * gib), overheadBytes: fA)  // 6 GiB
        // Second engine: co-resident residency now includes slot A's fused
        // cache (what the slot factory sums post-fix).
        let capB = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: wB,
            coResidentWeightBytes: UInt64(wA + fA),
            existingEngineKVCapacities: [grantA],
            physicalBytes: physical)
        #expect(capB > 0)
        // Σ(grants) lands exactly ON the fleet budget over the TRUE resident
        // set (weights + cache) — the process-wide invariant.
        #expect(
            UInt64(grantA + capB)
                == UnifiedMemoryCap.kvBudgetBytes(
                    physicalBytes: physical,
                    residentWeightBytes: UInt64(wA + fA + wB)))
        // Regression: ignoring the overhead (pre-fix residency sum) would
        // over-grant the second engine by exactly the cache size.
        let naiveB = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: wB,
            coResidentWeightBytes: UInt64(wA),
            existingEngineKVCapacities: [grantA],
            physicalBytes: physical)
        #expect(naiveB - capB == fA)
    }

    @Test("fusedMoECacheBytes counts a shared cache once and unbuilt caches as zero")
    func fusedCacheMeasurementDedupesSharedArrays() {
        // Two tiny REAL quantized SwitchGLUs over independent weights —
        // the same module type the Gemma 4 MoE layers use — then share one
        // fused cache exactly as the extraction does.
        let a = SwitchGLU(inputDims: 64, hiddenDims: 64, numExperts: 2)
        let b = SwitchGLU(inputDims: 64, hiddenDims: 64, numExperts: 2)
        quantize(model: a, groupSize: 32, bits: 4)
        quantize(model: b, groupSize: 32, bits: 4)

        // Nothing built yet → zero overhead (a non-VLM slot at load time).
        #expect(EngineV2VLMTextExtraction.fusedMoECacheBytes(of: [a, b]) == 0)

        #expect(a.shareFusedGateUpCache(with: b))
        let cacheBytes = a.fusedGateUpCacheBytes
        #expect(cacheBytes > 0)
        #expect(b.fusedGateUpCacheBytes == cacheBytes)

        // Each tree alone reports the cache; BOTH trees together still count
        // it ONCE — dedup by array identity, the sharing contract.
        #expect(EngineV2VLMTextExtraction.fusedMoECacheBytes(of: [a]) == cacheBytes)
        #expect(EngineV2VLMTextExtraction.fusedMoECacheBytes(of: [b]) == cacheBytes)
        #expect(EngineV2VLMTextExtraction.fusedMoECacheBytes(of: [a, b]) == cacheBytes)
    }
}
