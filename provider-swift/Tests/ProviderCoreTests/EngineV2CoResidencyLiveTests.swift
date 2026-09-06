// Copyright © 2026 Eigen Labs.
//
// LIVE two-model co-residency on the v2 engine (v0.7.5 §1.1 acceptance):
// the postmortem's failure shape — first engine claims the whole KV budget,
// every later model silently falls back to legacy — must be structurally
// impossible. On real weights (the two production families):
//
//   1. load gpt-oss → its engine holds the FULL fleet KV budget;
//   2. start a REAL generation on gpt-oss; WHILE it streams, load
//      gemma-4-qat → gpt-oss's grant SHRINKS to its fair share without
//      touching the in-flight stream (engine shrink semantics), and BOTH
//      slots hold live v2 bridges with Σ(grants) ≤ the fleet budget;
//   3. both backend ceilings read back the newly admitted grants;
//   4. both models serve a real 1-token decode through the production
//      serving path (MultiModelBatchSchedulerEngine → bridge);
//   5. unload gemma → gpt-oss's grant grows back to the full budget.
//
// Both contiguous and production segmented storage follow admitted grants.
// Existing physical pages can survive a shrink until their owners retire;
// grant updates do not allocate pages. Exact dtype/ring/MTP byte boundaries
// are tested by SegmentedProductionGrantTests without loading large models.
// These historical local-cache fixtures are a live lifecycle gate, not the
// exact five-artifact performance matrix or a production capacity measurement.
//
// Gated like the other multi-GB suites: DARKBLOOM_LIVE_MLX_TESTS +
// DARKBLOOM_LIVE_MLX_GEMMA, and each checkpoint skips cleanly when absent
// from the local HF cache (LiveInferenceFixtures pattern).

import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("EngineV2 two-model co-residency (live)", .serialized)
struct EngineV2CoResidencyLiveTests {

    static let gptossID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
    static let gemmaQatID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"

    private static let gib: UInt64 = 1024 * 1024 * 1024

    /// Test-scoped operator reserve (`memory_reserve_gb`). Kept modest so
    /// the model LOAD gate (free-memory based) breathes under
    /// concurrent-suite memory pressure; the admission-ceiling probe below
    /// is pure engine-ledger arithmetic and does not depend on free RAM.
    private static let reserveGiB: UInt64 = 8

    /// Real ProviderLoop over the two production checkpoints, with an
    /// isolated runtime. Estimated sizes mirror the on-disk footprints
    /// (gpt-oss ~12.1 GiB, gemma-qat ~14.9 GiB).
    ///
    /// `kvBackend` is the EXPLICIT `[backend] engine_v2_kv_backend` setting,
    /// never `auto`: an arm that silently degraded to the other backend
    /// would report a pass for a drill it never ran.
    private func makeLiveLoop(
        kvBackend: String
    ) throws -> (loop: ProviderLoop, runtime: EngineV2Runtime) {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: ProcessInfo.processInfo.physicalMemory / Self.gib,
                memoryAvailableGb: max(1, ProcessInfo.processInfo.physicalMemory / Self.gib - 4),
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: [
                ModelInfo(
                    id: Self.gptossID, modelType: "gpt_oss",
                    sizeBytes: 13 * Self.gib, estimatedMemoryGb: 14.0),
                ModelInfo(
                    id: Self.gemmaQatID, modelType: "gemma4",
                    sizeBytes: 15 * Self.gib, estimatedMemoryGb: 17.0),
            ],
            config: ProviderConfig(
                provider: ProviderSettings(name: "coresidency-live", memoryReserveGB: Self.reserveGiB),
                backend: BackendSettings(
                    idleTimeoutMins: 0, maxModelSlots: 3,
                    engineV2KVBackend: kvBackend),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            )
        )
        let loop = try ProviderLoop(
            config: config, purgeLegacyFiles: false, attestationSigner: nil)
        let runtime = EngineV2Runtime()
        return (loop, runtime)
    }

    /// Collect a bridge stream into (text, completionTokens, error).
    private func collectBridgeStream(
        _ stream: AsyncStream<GenerationEvent>
    ) async -> (text: String, completion: Int, error: String?) {
        var text = ""
        var completion = 0
        var error: String?
        for await event in stream {
            switch event {
            case .chunk(let chunk): text += chunk
            case .info(_, let completionTokens, _, _): completion = completionTokens
            case .error(let message): error = message
            case .terminal(_, let message, _, _): error = message
            }
        }
        return (text, completion, error)
    }

    @Test(
        "load B while A streams: shrink, serve both, admission ceiling, regrow",
        arguments: ["contiguous", "paged"])
    func coResidencyLifecycle(kvBackend: String) async throws {
        guard LiveInferenceFixtures.liveTestsEnabled, LiveInferenceFixtures.gemmaTestsEnabled else {
            return  // env-gated (multi-GB weights)
        }
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found = LiveInferenceFixtures.locate(Self.gptossID) else {
            throw LiveFixtureSkip.modelNotInCache(Self.gptossID)
        }
        guard case .found = LiveInferenceFixtures.locate(Self.gemmaQatID) else {
            throw LiveFixtureSkip.modelNotInCache(Self.gemmaQatID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 64 * 1024 * 1024 * 1024)

        let paged = kvBackend == "paged"
        let (loop, runtime) = try makeLiveLoop(kvBackend: kvBackend)
        await loop.setEngineV2RuntimeForTesting(runtime)
        // Structured teardown: unload whatever loaded, on every exit path.
        defer {
            Task {
                await loop.unloadModel(Self.gemmaQatID)
                await loop.unloadModel(Self.gptossID)
                MLX.Memory.clearCache()
            }
        }

        // ---- 1. Load A (gpt-oss). ----
        try await loop.ensureModelLoaded(modelId: Self.gptossID)
        let bridgeA = try #require(await loop.slotBridgeForTesting(modelId: Self.gptossID))
        let sizingA = try #require(await loop.slotSizingForTesting(modelId: Self.gptossID))
        let reserveBytes: UInt64 = Self.reserveGiB * Self.gib  // memoryReserveGB above
        let grantA0 = await bridgeA.engineKVBytesCapacity()
        let budgetAlone = UnifiedMemoryCap.kvBudgetBytes(
            residentWeightBytes: UInt64(sizingA.weightsBytes),
            configReserveBytes: reserveBytes)
        // The explicit backend selection must have been honoured — a
        // degraded arm measures the wrong thing.
        #expect(await bridgeA.kvBackendKind == (paged ? .paged : .contiguous))
        #expect(grantA0 == Int(budgetAlone), "single model must hold the FULL fleet budget")
        #expect(await bridgeA.pagedPoolResizeShortfall() == nil)
        if paged {
            let capacity = await bridgeA.engine.capacity()
            #expect(capacity.pagedStorage != nil, "explicit paged must construct segmented storage")
        }

        // ---- 2. Stream on A while B loads. ----
        let streamA = await bridgeA.submitTokenized(
            promptTokens: try await tokenize("Count from 1 to 30, separated by commas.", loop: loop),
            request: ChatCompletionRequest(
                model: Self.gptossID,
                messages: [
                    ChatMessage(role: "user", content: "Count from 1 to 30, separated by commas.")
                ],
                temperature: 0,
                max_tokens: 200),
            requestId: "stream-during-load")
        let collectorA = Task { await collectBridgeStream(streamA) }

        try await loop.ensureModelLoaded(modelId: Self.gemmaQatID)
        let bridgeB = try #require(await loop.slotBridgeForTesting(modelId: Self.gemmaQatID))
        let sizingB = try #require(await loop.slotSizingForTesting(modelId: Self.gemmaQatID))
        #expect(sizingB.fp16KVBytesPerToken == 20_480)
        #expect(await bridgeB.kvBackendKind == (paged ? .paged : .contiguous))

        // A's in-flight stream completes untouched across the re-slice.
        let resultA = await collectorA.value
        #expect(resultA.error == nil, "A's stream must survive the shrink: \(resultA.error ?? "")")
        #expect(resultA.completion > 0)
        #expect(resultA.text.contains("10"), "greedy count should reach 10: \(resultA.text.prefix(200))")

        // ---- 3. Grants after the re-slice. ----
        let grantA1 = await bridgeA.engineKVBytesCapacity()
        let grantB = await bridgeB.engineKVBytesCapacity()
        let fleetBudget = UnifiedMemoryCap.kvBudgetBytes(
            residentWeightBytes: UInt64(sizingA.weightsBytes + sizingB.weightsBytes),
            configReserveBytes: reserveBytes)
        let expected = EngineV2KVSizing.resliceGrants(
            existing: [
                .init(
                    modelId: Self.gptossID,
                    fp16KVBytesPerToken: sizingA.fp16KVBytesPerToken,
                    maxContextLength: sizingA.maxContextLength)
            ],
            newcomer: .init(
                modelId: Self.gemmaQatID,
                fp16KVBytesPerToken: sizingB.fp16KVBytesPerToken,
                maxContextLength: sizingB.maxContextLength),
            fleetKVBudgetBytes: fleetBudget)
        let targetA = try #require(expected[Self.gptossID])
        print(
            "[co-residency/\(kvBackend)] fleetBudget=\(fleetBudget / Self.gib)GiB "
                + "grantA0=\(UInt64(grantA0) / Self.gib)GiB "
                + "grantA1=\(UInt64(grantA1) / Self.gib)GiB "
                + "grantB=\(UInt64(grantB) / Self.gib)GiB")

        #expect(grantA1 == targetA)
        #expect(grantB == expected[Self.gemmaQatID])
        #expect(grantA1 < grantA0)
        #expect(UInt64(grantA1) + UInt64(grantB) <= fleetBudget)
        #expect(await bridgeA.pagedPoolResizeShortfall() == nil)

        // Both slots serve a REAL decode through the production path.
        _ = try await loop.runStartupSelfTestDecode(modelId: Self.gptossID)
        _ = try await loop.runStartupSelfTestDecode(modelId: Self.gemmaQatID)

        // ---- 5. Unload B. ----
        await loop.unloadModel(Self.gemmaQatID)
        let grantA2 = await bridgeA.engineKVBytesCapacity()
        let budgetAfterUnload = UnifiedMemoryCap.kvBudgetBytes(
            residentWeightBytes: UInt64(sizingA.weightsBytes),
            configReserveBytes: reserveBytes)
        #expect(grantA2 == Int(budgetAfterUnload))
        #expect(grantA2 > grantA1)
        #expect(await bridgeA.pagedPoolResizeShortfall() == nil)
        print("[co-residency/\(kvBackend)] after unload grantA2=\(UInt64(grantA2) / Self.gib)GiB")

        // A still serves after the round trip.
        _ = try await loop.runStartupSelfTestDecode(modelId: Self.gptossID)

        await loop.unloadModel(Self.gptossID)
    }

    // MARK: - Helpers

    /// Tokenize a user turn with the LOADED model's tokenizer (chat template
    /// applied) — the same shape the production submit path produces.
    private func tokenize(_ text: String, loop: ProviderLoop) async throws -> [Int] {
        let resolved = try await loop.resolveTokenizerForLocal(Self.gptossID)
        return try resolved.tokenizer.inner.applyChatTemplate(
            messages: [["role": "user", "content": text]],
            tools: nil, additionalContext: nil)
    }

}
