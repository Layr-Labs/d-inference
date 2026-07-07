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
//   3. gpt-oss's NEXT admission respects the SHRUNK ceiling: a worst-case
//      request that fit the old grant is refused (token_budget_exhausted);
//   4. both models serve a real 1-token decode through the production
//      serving path (MultiModelBatchSchedulerEngine → bridge);
//   5. unload gemma → gpt-oss's grant grows back to the full budget.
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
    private func makeLiveLoop() throws -> (loop: ProviderLoop, runtime: EngineV2Runtime) {
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
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
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
            }
        }
        return (text, completion, error)
    }

    @Test("load B while A streams: shrink, serve both, admission ceiling, regrow")
    func coResidencyLifecycle() async throws {
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

        let (loop, runtime) = try makeLiveLoop()
        await loop.setEngineV2RuntimeForTesting(runtime)
        // Structured teardown: unload whatever loaded, on every exit path.
        defer {
            Task {
                await loop.unloadModel(Self.gemmaQatID)
                await loop.unloadModel(Self.gptossID)
                MLX.Memory.clearCache()
            }
        }

        // ---- 1. Load A (gpt-oss): the lone slot holds the FULL budget. ----
        try await loop.ensureModelLoaded(modelId: Self.gptossID)
        let bridgeA = try #require(await loop.slotBridgeForTesting(modelId: Self.gptossID))
        let sizingA = try #require(await loop.slotSizingForTesting(modelId: Self.gptossID))
        let reserveBytes: UInt64 = Self.reserveGiB * Self.gib  // memoryReserveGB above
        let grantA0 = await bridgeA.engineKVBytesCapacity()
        let budgetAlone = UnifiedMemoryCap.kvBudgetBytes(
            residentWeightBytes: UInt64(sizingA.weightsBytes),
            configReserveBytes: reserveBytes)
        #expect(grantA0 == Int(budgetAlone), "single model must hold the FULL fleet budget")
        // Engine-truth rate for the admission-probe arithmetic below.
        #expect(sizingA.fp16KVBytesPerToken == 24_576)

        // ---- Admission-ceiling probe P: a worst-case request that FITS the
        // full grant but NOT the post-shrink share, submitted DIRECTLY to
        // the engine so the verdict is the admission ledger's canEverFit —
        // pure grant arithmetic (drift-test-pinned against estimatedBytes),
        // immune to free-RAM contention from concurrent suites. Sized 15%
        // above the expected post-shrink share, well below the full grant.
        let gemmaSizingPreview = EngineV2KVSizing.ResliceSlot(
            modelId: Self.gemmaQatID, fp16KVBytesPerToken: 20_480, maxContextLength: 262_144)
        let previewBudget = UnifiedMemoryCap.kvBudgetBytes(
            residentWeightBytes: UInt64(sizingA.weightsBytes) + 15 * Self.gib,
            configReserveBytes: reserveBytes)
        let previewTargets = EngineV2KVSizing.resliceGrants(
            existing: [
                .init(
                    modelId: Self.gptossID,
                    fp16KVBytesPerToken: sizingA.fp16KVBytesPerToken,
                    maxContextLength: sizingA.maxContextLength)
            ],
            newcomer: gemmaSizingPreview,
            fleetKVBudgetBytes: previewBudget)
        let expectedShrunkA = try #require(previewTargets[Self.gptossID])
        let probeBytes = min(
            UInt64(Double(expectedShrunkA) * 1.15),
            UInt64(Double(grantA0) * 0.85))
        let probeTokens = Int(probeBytes) / sizingA.fp16KVBytesPerToken
        #expect(probeTokens * sizingA.fp16KVBytesPerToken > expectedShrunkA,
                "probe must exceed the post-shrink ceiling to be meaningful")
        print("[co-residency] probeTokens=\(probeTokens) (~\(probeBytes / Self.gib)GiB worst-case)")
        let probePrompt = try await tokenize("Write a very long story.", loop: loop)
        let engineA = await bridgeA.engine
        /// Submit the probe straight to the engine ledger. Returns the
        /// stream when admitted (caller cancels + drains), nil when the
        /// ledger refused it (capacityExhausted).
        @Sendable func submitLedgerProbe(_ id: UInt64) -> AsyncStream<CBv2Event>? {
            do {
                return try engineA.submit(
                    CBv2Request(
                        id: CBv2RequestID(id),
                        promptTokens: probePrompt,
                        maxTokens: probeTokens))
            } catch {
                return nil
            }
        }
        do {
            // Pre-shrink: the ledger ADMITS the worst case under the full
            // grant. Cancel immediately (submit-no-throw IS the verdict) and
            // drain so its reservations release.
            let probeId: UInt64 = 0x7000_0001
            let probe = submitLedgerProbe(probeId)
            #expect(probe != nil, "the worst-case probe must fit the FULL grant pre-shrink")
            if let probe {
                engineA.cancel(CBv2RequestID(probeId))
                for await _ in probe {}
            }
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

        // A's in-flight stream completes untouched across the shrink.
        let resultA = await collectorA.value
        #expect(resultA.error == nil, "A's stream must survive the shrink: \(resultA.error ?? "")")
        #expect(resultA.completion > 0)
        #expect(resultA.text.contains("10"), "greedy count should reach 10: \(resultA.text.prefix(200))")

        // ---- 3. Both grants re-sliced; Σ ≤ fleet budget; ceilings live. ----
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
        #expect(grantA1 == expected[Self.gptossID])
        #expect(grantB == expected[Self.gemmaQatID])
        #expect(grantA1 < grantA0)
        #expect(UInt64(grantA1) + UInt64(grantB) <= fleetBudget)
        print(
            "[co-residency] fleetBudget=\(fleetBudget / Self.gib)GiB "
                + "grantA0=\(UInt64(grantA0) / Self.gib)GiB "
                + "grantA1=\(UInt64(grantA1) / Self.gib)GiB "
                + "grantB=\(UInt64(grantB) / Self.gib)GiB")

        // ---- 4. A's NEXT admission respects the SHRUNK ceiling: the same
        // worst-case probe that was admitted pre-shrink is now REFUSED by
        // the ledger (canEverFit against the re-sliced capacity). ----
        let refusedProbe = submitLedgerProbe(0x7000_0002)
        #expect(refusedProbe == nil, "post-shrink probe must be refused by the admission ledger")
        if let refusedProbe {  // drain if the assertion failed, don't leak
            engineA.cancel(CBv2RequestID(0x7000_0002))
            for await _ in refusedProbe {}
        }

        // Both slots serve a REAL decode through the production path.
        _ = try await loop.runStartupSelfTestDecode(modelId: Self.gptossID)
        _ = try await loop.runStartupSelfTestDecode(modelId: Self.gemmaQatID)

        // ---- 5. Unload B: A grows back to the FULL budget. ----
        await loop.unloadModel(Self.gemmaQatID)
        let grantA2 = await bridgeA.engineKVBytesCapacity()
        let budgetAfterUnload = UnifiedMemoryCap.kvBudgetBytes(
            residentWeightBytes: UInt64(sizingA.weightsBytes),
            configReserveBytes: reserveBytes)
        #expect(grantA2 == Int(budgetAfterUnload))
        #expect(grantA2 > grantA1)
        print("[co-residency] after unload grantA2=\(UInt64(grantA2) / Self.gib)GiB")

        // A still serves after the round trip.
        _ = try await loop.runStartupSelfTestDecode(modelId: Self.gptossID)

        await loop.unloadModel(Self.gptossID)
    }

    // MARK: - Helpers

    /// Tokenize a user turn with the LOADED model's tokenizer (chat template
    /// applied) — the same shape the production submit path produces.
    private func tokenize(_ text: String, loop: ProviderLoop) async throws -> [Int] {
        let tokenizer = try await loop.resolveTokenizerForLocal(Self.gptossID)
        return try tokenizer.inner.applyChatTemplate(
            messages: [["role": "user", "content": text]],
            tools: nil, additionalContext: nil)
    }

}
