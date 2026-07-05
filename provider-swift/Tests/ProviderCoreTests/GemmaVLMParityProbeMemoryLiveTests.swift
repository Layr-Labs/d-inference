// Copyright © 2026 Eigen Labs.
//
// Live (weight-gated) regression for the v0.7.2 black-hole incident
// (7×64 GB gemma-4-26b-8bit + 1×36 GB qat-4bit boxes rejecting 100% of
// requests with the shared-KV capacity string from their first request,
// permanently).
//
// ROOT CAUSE (measured on the real 8-bit checkpoint, 2026-07-03):
// `MLXLMCommon.SwitchGLU` used to lazily concatenate a fused gate+up copy
// of its quantized expert weights on FIRST FORWARD and retain it on the
// module (~540 MB per MoE layer, ~15 GiB model-wide on gemma-4-26b-8bit).
// The v0.7.2 VLM text extraction created a SECOND SwitchGLU tree over the
// same weights, and the load-time parity probe ran one forward through
// EACH tree — materializing TWO ~15 GiB fused copies before the first
// request and pushing the box past the 90% unified-memory cap forever.
//
// The fused cache has since been DELETED from SwitchGLU (benchmarks showed
// ~0% decode win at its only active shape, B=1 solo decode, for 8–15 GiB
// of always-resident memory). The regression therefore tightens: the
// extraction + parity probe must retain (almost) NOTHING beyond the
// already-resident weights. This test asserts, on the real checkpoint:
//
//   1. GROWTH BOUND — extraction WITH the parity probe (production default)
//      grows MLX active memory by no more than a small tolerance (rope
//      tables / compiled-graph constants) — no multi-GiB retained state.
//   2. STEADY STATE AT LOAD — re-running both probe forwards afterwards
//      grows active memory by ~nothing: no lazy build is waiting to fire
//      mid-serving.
//   3. ADMISSION — a `GlobalKVCacheBudget` viewing the post-extraction MLX
//      state through a simulated 64 GB profile admits a typical worst-case
//      request reservation (the incident's first-request rejection,
//      inverted).
//   4. CAPACITY CONSISTENCY — the weights-derived v2 static ceiling equals
//      the shared gate's live headroom on the same profile: with no
//      engine-retained overhead there is nothing to net out, and the
//      heartbeat max and the gate agree by construction.
//
// Gated like the other multi-GB Gemma tests: DARKBLOOM_LIVE_MLX_TESTS +
// DARKBLOOM_LIVE_MLX_GEMMA; skipped cleanly when no checkpoint is cached.

import Foundation
import MLX
import MLXLMCommon
import MLXNN
import MLXVLM
import Testing

@testable import ProviderCore

@Suite("Gemma 4 VLM parity-probe memory hygiene (live)", .serialized)
struct GemmaVLMParityProbeMemoryLiveTests {

    /// The incident checkpoint (catalog id `gemma-4-26b-8bit`); falls back to
    /// the qat-4bit build when only that one is cached — the no-retained-
    /// growth invariant is checkpoint-independent.
    private static let preferredModelIDs = [
        LiveInferenceFixtures.gemmaModelID,
        "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
    ]

    private struct LoadedVLMSlot {
        let modelID: String
        let directory: URL
        let container: ModelContainer
        let scheduler: BatchScheduler
        let model: any LanguageModel
    }

    private func loadFirstCachedVLMSlot() async throws -> LoadedVLMSlot {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        var located: (String, URL)? = nil
        for modelID in Self.preferredModelIDs {
            if case .found(let directory) = LiveInferenceFixtures.locate(modelID) {
                located = (modelID, directory)
                break
            }
        }
        guard let (modelID, directory) = located else {
            throw LiveFixtureSkip.modelNotInCache(Self.preferredModelIDs[0])
        }
        #expect(ProviderLoop.modelIsVLM(at: directory))
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 64 * 1024 * 1024 * 1024)

        let container = try await VLMModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            pendingTimeout: .seconds(300),
            defaultMaxTokens: 256
        )
        await scheduler.loadModel(container: container, modelId: modelID)
        let snapshot = await container.perform { ctx in
            EngineV2ModelSnapshot(
                model: ctx.model,
                eosTokenIds: ctx.configuration.eosTokenIds,
                extraEOSTokens: [])
        }
        return LoadedVLMSlot(
            modelID: modelID,
            directory: directory,
            container: container,
            scheduler: scheduler,
            model: snapshot.model
        )
    }

    private static func gib(_ bytes: Int) -> String {
        String(format: "%.2f GiB", Double(bytes) / (1024 * 1024 * 1024))
    }

    @Test(
        "extraction + parity probe leave the shared KV budget serveable (64 GB profile)",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func parityProbeMemoryHygieneAndBudgetAdmission() async throws {
        let slot = try await loadFirstCachedVLMSlot()
        do {
            try await runBody(slot)
        } catch {
            await slot.scheduler.unloadModel()
            throw error
        }
        await slot.scheduler.unloadModel()
    }

    private func runBody(_ slot: LoadedVLMSlot) async throws {
        // Mirror the production sequence: the load path's post-load headroom
        // check trims the cold-load pool BEFORE the bridge build, so the
        // pre-extraction baseline starts from a clean pool exactly like prod.
        MLX.Stream().synchronize()
        MLX.Memory.clearCache()
        let activeBefore = MLX.GPU.activeMemory
        let sysBefore = SystemMemory.availableBytes() ?? 0
        print(
            "[parity-mem] pre-extraction: active=\(Self.gib(activeBefore)) "
                + "cache=\(Self.gib(MLX.GPU.cacheMemory)) sysAvail=\(Self.gib(Int(sysBefore)))")

        // REAL extraction with the parity gate ON (production default env).
        let extraction = try EngineV2VLMTextExtraction.extractTextModel(
            from: slot.model, modelDirectory: slot.directory)
        #expect(extraction.parityMaxAbsLogitDiff != nil)

        let activeAfter = MLX.GPU.activeMemory
        let cacheAfter = MLX.GPU.cacheMemory
        let activeGrowth = max(0, activeAfter - activeBefore)
        print(
            "[parity-mem] post-extraction: active=\(Self.gib(activeAfter)) "
                + "cache=\(Self.gib(cacheAfter)) activeGrowth=\(Self.gib(activeGrowth))")

        // 1. GROWTH BOUND: the extraction shares the wrapper's weight arrays
        //    and retains no engine-side caches, so the only legitimate
        //    growth is small one-time state (rope tables, compiled-graph
        //    constants, probe stragglers). Pre-v0.7.3 this measured ~30 GiB
        //    (two fused copies); with the fused cache deleted outright the
        //    bar is a flat 2 GiB.
        let tolerance = 2 * 1024 * 1024 * 1024
        #expect(
            activeGrowth < tolerance,
            Comment(
                rawValue: "extraction + parity probe retained \(Self.gib(activeGrowth)) "
                    + "(> 2 GiB) — a weight or cache copy is being built "
                    + "(the v0.7.2 black-hole shape)"))
        //    The pool must also come back trimmed (post-probe clearCache).
        #expect(
            cacheAfter < 1 * 1024 * 1024 * 1024,
            Comment(
                rawValue: "probe left \(Self.gib(cacheAfter)) in the MLX pool — "
                    + "the post-probe clearCache is missing"))

        // 2. STEADY STATE AT LOAD: re-running both probe forwards must not
        //    materialize anything new — no lazy multi-GiB build can be
        //    waiting to fire on the first real request.
        guard let wrapper = slot.model as? MLXVLM.Gemma4 else {
            Issue.record("prod Gemma 4 slot did not load the MLXVLM.Gemma4 wrapper")
            return
        }
        let probeTokens = MLXArray([2, 651, 6134, 1024, 578, 108, 2364].map(Int32.init))
            .expandedDimensions(axis: 0)
        eval(wrapper(probeTokens, cache: nil))
        eval(extraction.model(probeTokens, cache: nil))
        MLX.Stream().synchronize()
        MLX.Memory.clearCache()
        let activeSteady = MLX.GPU.activeMemory
        let steadyGrowth = max(0, activeSteady - activeAfter)
        print("[parity-mem] steady-state re-forward growth=\(Self.gib(steadyGrowth))")
        #expect(
            steadyGrowth < 512 * 1024 * 1024,
            Comment(
                rawValue: "serving forwards after load grew active memory by "
                    + "\(Self.gib(steadyGrowth)) — a lazy per-tree cache still fires at "
                    + "request time"))

        // 3. ADMISSION on the incident profile: view the REAL post-extraction
        //    MLX counters through a synthetic 64 GB box (the incident
        //    hardware). The budget must admit one typical worst-case request
        //    (2 KiB prompt + 4096 max tokens at the slot's fp16 KV rate) —
        //    pre-fix this is exactly the reservation that failed 100% of the
        //    time from the first request.
        let fp16Rate = await slot.scheduler.fp16KVBytesPerToken
        let totalBytes: UInt64 = 64 * 1024 * 1024 * 1024
        let budget = GlobalKVCacheBudget(
            memorySnapshot: {
                let active = UInt64(max(0, MLX.GPU.activeMemory))
                let cache = UInt64(max(0, MLX.GPU.cacheMemory))
                let used = active + cache
                // Simulated OS view of the 64 GB box: whatever the provider
                // isn't holding, minus a 4 GiB OS/wired allowance.
                let osAllowance: UInt64 = 4 * 1024 * 1024 * 1024
                let free = totalBytes > used + osAllowance ? totalBytes - used - osAllowance : 0
                return .init(
                    total: totalBytes, active: active, cache: cache, systemAvailable: free)
            }
        )
        let worstCaseTokens = 2048 + 4096
        let admitted = await budget.reserve(
            requestID: "incident-probe", kvBytesPerToken: fp16Rate, tokenCount: worstCaseTokens)
        print(
            "[parity-mem] 64GB-profile admission: fp16KVBytesPerToken=\(fp16Rate) "
                + "worstCaseTokens=\(worstCaseTokens) admitted=\(admitted)")
        #expect(
            admitted,
            Comment(
                rawValue: "the shared KV budget rejected a typical request on the simulated "
                    + "64 GB profile after the parity probe — the v0.7.2 black-hole signature"))
        await budget.release(requestID: "incident-probe")
        #expect(await budget.reservationIDsForTesting().isEmpty)

        // 4. CAPACITY CONSISTENCY: the v2 static ceiling is sized from the
        //    SCHEDULER's weight figure (the exact input production
        //    makeEngineV2BridgeForSlot passes — ProviderLoop+EngineV2), NOT
        //    from live MLX usage, so this genuinely catches the
        //    over-advertising shape: if extraction/probe retained any
        //    non-weight state, the weights-derived ceiling would exceed the
        //    gate's live headroom by exactly that retained amount. With the
        //    fused cache deleted, the divergence must fit inside the same
        //    2 GiB retained-state bar as step 1 (rope tables, compiled-graph
        //    constants), and can never be negative beyond rounding (live use
        //    cannot be below the resident weights).
        MLX.Stream().synchronize()
        MLX.Memory.clearCache()
        let schedulerWeightBytes = await slot.scheduler.modelWeightBytes
        let mlxUsedNow =
            UInt64(max(0, MLX.GPU.activeMemory)) + UInt64(max(0, MLX.GPU.cacheMemory))
        let ceiling = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: schedulerWeightBytes,
            coResidentWeightBytes: 0,
            existingEngineKVCapacities: [],
            physicalBytes: totalBytes)
        let gateHeadroom = UnifiedMemoryCap.liveKVHeadroomBytes(
            physicalBytes: totalBytes,
            mlxUsedBytes: mlxUsedNow,
            systemAvailableBytes: .max)
        let retainedOverhead = Int64(ceiling) - Int64(clamping: gateHeadroom)
        print(
            "[parity-mem] 64GB-profile capacity: ceiling=\(Self.gib(ceiling)) "
                + "gateHeadroom=\(Self.gib(Int(gateHeadroom))) "
                + "retainedOverhead=\(Self.gib(Int(retainedOverhead)))")
        #expect(
            retainedOverhead <= Int64(tolerance),
            Comment(
                rawValue: "weights-derived v2 ceiling \(Self.gib(ceiling)) exceeds the "
                    + "shared-gate live headroom \(Self.gib(Int(gateHeadroom))) by more than "
                    + "the retained-state bar — extraction/probe is holding non-weight "
                    + "memory the heartbeat would over-advertise (the finding-2 "
                    + "over-routing shape)"))
        #expect(
            retainedOverhead >= -(64 * 1024 * 1024),
            Comment(
                rawValue: "shared-gate headroom exceeds the weights-derived ceiling — "
                    + "live MLX usage measured below the scheduler's resident weights, "
                    + "which means the weight figure itself is inflated"))
    }
}
