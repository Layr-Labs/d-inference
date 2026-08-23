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
// RUNS ON BOTH KV BACKENDS. The drill is the same; the ARITHMETIC is not,
// and the difference is the whole of migration-plan §15:
//
//   * CONTIGUOUS — the admission ceiling IS the fleet grant. It shrinks
//     when gemma arrives and grows back when gemma leaves. Steps 1/3/5
//     assert exactly that.
//   * PAGED — the ceiling is the physically materialized pool, sized ONCE
//     at engine construction by `PagedKVPhysicalCapacityPolicy` (useful
//     concurrent context ∧ machine size ∧ live headroom — never the grant).
//     A co-resident load cannot shrink it (a ledger shrink frees no slabs)
//     and a co-resident unload cannot grow it (a ledger grow mints no
//     pages). So the paged arm asserts the ceiling is INVARIANT across the
//     whole lifecycle, and that the fair share the slot cannot take is
//     reported as `PagedPoolResizeShortfall.deferredGrowthBytes` instead of
//     vanishing silently.
//
// The earlier revision of this file pinned `contiguous` and explained the
// pin by claiming a lone paged slot would commit "~the full fleet budget"
// as slabs and fail the later load closed. That was true when it was
// written (#531) and stopped being true one PR later (#535), which bounded
// physical capacity by demand. Neither the giant pool nor the failed load
// happens; what happens is the frozen ceiling above.
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
        let poolA = Int(await bridgeA.kvBackendPoolBytes())
        if paged {
            // The lone slot's ceiling is POOL truth, not the fleet budget:
            // demand-bounded, and far below the budget on any real box.
            #expect(grantA0 == poolA)
            #expect(UInt64(grantA0) <= budgetAlone)
            #expect(UInt64(grantA0) >= UnifiedMemoryCap.minimumLoadKVBytes)
            // No re-slice has happened yet, so there is no residue.
            #expect(await bridgeA.pagedPoolResizeShortfall() == nil)
        } else {
            #expect(grantA0 == Int(budgetAlone), "single model must hold the FULL fleet budget")
        }
        // Engine-truth rate for the admission-probe arithmetic below.
        #expect(sizingA.fp16KVBytesPerToken == 24_576)

        // ---- Admission-ceiling probes, submitted DIRECTLY to the engine so
        // the verdict is the admission ledger's canEverFit — pure grant
        // arithmetic (drift-test-pinned against estimatedBytes), immune to
        // free-RAM contention from concurrent suites.
        //
        // CONTIGUOUS: one probe, sized 15% above the expected post-shrink
        // share and 15% below the current grant, so it flips from admitted
        // to refused across the co-resident load.
        // PAGED: two probes straddling the pool-bound ceiling. Both keep
        // their verdict across the whole lifecycle — that invariance IS the
        // finding.
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
        let probePrompt = try await tokenize("Write a very long story.", loop: loop)
        let engineA = await bridgeA.engine
        func tokens(forBytes bytes: UInt64) -> Int {
            Int(bytes) / sizingA.fp16KVBytesPerToken
        }
        /// Submit a worst-case probe straight to the engine ledger. Returns
        /// the stream when admitted (drained here), nil when the ledger
        /// refused it (capacityExhausted).
        @Sendable func ledgerAdmits(_ id: UInt64, maxTokens: Int) async -> Bool {
            let stream: AsyncStream<CBv2Event>?
            do {
                stream = try engineA.submit(
                    CBv2Request(
                        id: CBv2RequestID(id),
                        promptTokens: probePrompt,
                        maxTokens: maxTokens))
            } catch {
                return false
            }
            guard let stream else { return false }
            // Submit-no-throw IS the verdict: cancel immediately and drain
            // so the probe's reservations release.
            engineA.cancel(CBv2RequestID(id))
            for await _ in stream {}
            return true
        }

        // Sized against the CURRENT ceiling in both arms.
        let underCeilingTokens = tokens(forBytes: UInt64(Double(grantA0) * 0.85))
        let overCeilingTokens = tokens(forBytes: UInt64(Double(grantA0) * 1.15))
        let shrinkProbeTokens = tokens(
            forBytes: min(
                UInt64(Double(expectedShrunkA) * 1.15),
                UInt64(Double(grantA0) * 0.85)))
        print(
            "[co-residency/\(kvBackend)] grantA0=\(UInt64(grantA0) / Self.gib)GiB "
                + "poolA=\(UInt64(poolA) / Self.gib)GiB "
                + "expectedShrunkA=\(UInt64(expectedShrunkA) / Self.gib)GiB")

        if paged {
            // A pool-bound ceiling: below it admits, above it refuses.
            #expect(await ledgerAdmits(0x7000_0001, maxTokens: underCeilingTokens))
            #expect(!(await ledgerAdmits(0x7000_0002, maxTokens: overCeilingTokens)))
            // The fair share gemma's arrival will award is LARGER than the
            // pool — this box is in the deferred-growth regime, which is
            // what makes the invariance below meaningful rather than
            // coincidental.
            #expect(
                expectedShrunkA > grantA0,
                "paged arm needs a fair share above the pool to be meaningful")
        } else {
            #expect(
                shrinkProbeTokens * sizingA.fp16KVBytesPerToken > expectedShrunkA,
                "probe must exceed the post-shrink ceiling to be meaningful")
            #expect(
                await ledgerAdmits(0x7000_0001, maxTokens: shrinkProbeTokens),
                "the worst-case probe must fit the FULL grant pre-shrink")
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

        if paged {
            // A ledger grow mints no pages: A's ceiling did not move, and
            // the fair share it cannot take is reported, not lost.
            #expect(grantA1 == grantA0)
            #expect(grantA1 == poolA)
            #expect(await bridgeA.kvBackendPoolBytes() == UInt64(poolA))
            let shortfall = try #require(await bridgeA.pagedPoolResizeShortfall())
            #expect(shortfall.poolBytes == poolA)
            #expect(shortfall.requestedBytes == targetA)
            #expect(shortfall.deferredGrowthBytes == targetA - poolA)
            #expect(shortfall.strandedBytes == 0)
            // Σ(PHYSICAL pools) ≤ fleet budget still holds — the pools are
            // demand-bounded, so co-residency does not over-commit KV. It
            // under-commits it, badly: see the ratio printed below.
            let poolB = await bridgeB.kvBackendPoolBytes()
            #expect(UInt64(poolA) + poolB <= fleetBudget)
            print(
                "[co-residency/paged] Σpools=\((UInt64(poolA) + poolB) / Self.gib)GiB "
                    + "of fleetBudget=\(fleetBudget / Self.gib)GiB "
                    + "(deferred on A alone: \(UInt64(shortfall.deferredGrowthBytes) / Self.gib)GiB)")
        } else {
            #expect(grantA1 == targetA)
            #expect(grantB == expected[Self.gemmaQatID])
            #expect(grantA1 < grantA0)
            #expect(UInt64(grantA1) + UInt64(grantB) <= fleetBudget)
            #expect(await bridgeA.pagedPoolResizeShortfall() == nil)
        }

        // ---- 4. A's NEXT admission. Contiguous: the same worst-case probe
        // that was admitted pre-shrink is now REFUSED by the ledger. Paged:
        // both probes keep their pre-load verdict, because a co-resident
        // load cannot move a pool-bound ceiling in either direction. ----
        if paged {
            #expect(await ledgerAdmits(0x7000_0003, maxTokens: underCeilingTokens))
            #expect(!(await ledgerAdmits(0x7000_0004, maxTokens: overCeilingTokens)))
        } else {
            #expect(
                !(await ledgerAdmits(0x7000_0003, maxTokens: shrinkProbeTokens)),
                "post-shrink probe must be refused by the admission ledger")
        }

        // Both slots serve a REAL decode through the production path.
        _ = try await loop.runStartupSelfTestDecode(modelId: Self.gptossID)
        _ = try await loop.runStartupSelfTestDecode(modelId: Self.gemmaQatID)

        // ---- 5. Unload B. ----
        await loop.unloadModel(Self.gemmaQatID)
        let grantA2 = await bridgeA.engineKVBytesCapacity()
        let budgetAfterUnload = UnifiedMemoryCap.kvBudgetBytes(
            residentWeightBytes: UInt64(sizingA.weightsBytes),
            configReserveBytes: reserveBytes)
        if paged {
            // The regrow is deferred, not taken: the survivor is left
            // holding a pool sized for a box that no longer exists.
            #expect(grantA2 == poolA)
            #expect(grantA2 == grantA1)
            let shortfall = try #require(await bridgeA.pagedPoolResizeShortfall())
            #expect(shortfall.requestedBytes == Int(budgetAfterUnload))
            #expect(shortfall.deferredGrowthBytes == Int(budgetAfterUnload) - poolA)
            print(
                "[co-residency/paged] after unload grantA2=\(UInt64(grantA2) / Self.gib)GiB "
                    + "deferred=\(UInt64(shortfall.deferredGrowthBytes) / Self.gib)GiB "
                    + "of budget=\(budgetAfterUnload / Self.gib)GiB")
        } else {
            #expect(grantA2 == Int(budgetAfterUnload))
            #expect(grantA2 > grantA1)
            print("[co-residency/contiguous] after unload grantA2=\(UInt64(grantA2) / Self.gib)GiB")
        }

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
