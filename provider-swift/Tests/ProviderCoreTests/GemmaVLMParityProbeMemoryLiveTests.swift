// Copyright © 2026 Eigen Labs.
//
// Live (weight-gated) regression for the v0.7.2 black-hole incident
// (7×64 GB gemma-4-26b-8bit + 1×36 GB qat-4bit boxes rejecting 100% of
// requests with the shared-KV capacity string from their first request,
// permanently).
//
// ROOT CAUSE (measured on the real 8-bit checkpoint, 2026-07-03):
// `MLXLMCommon.SwitchGLU` lazily concatenates a fused gate+up copy of its
// quantized expert weights on FIRST FORWARD and retains it on the module
// (~540 MB per MoE layer, ~15 GiB model-wide on gemma-4-26b-8bit). The
// v0.7.2 VLM text extraction created a SECOND SwitchGLU tree over the same
// weights, and the load-time parity probe ran one forward through EACH tree
// — materializing TWO ~15 GiB fused copies before the first request:
//
//     26.04 GiB (weights) + 15.06 (wrapper fused) + 15.07 (extracted fused)
//     = 56.17 GiB active  vs  57.6 GiB cap (0.9 × 64 GB)
//
// → `UnifiedMemoryCap.liveKVHeadroomBytes` ≈ 0 forever. MLX `clearCache`
// cannot reclaim module-retained ACTIVE memory, so the KVPoolReclaimer
// self-heal never helped, while the engine's own ledger stayed idle — the
// two-ledgers-disagree signature. Deterministic on any box where
// weights + 2×fusedCache crosses the cap (64 GB/8-bit, 36 GB/qat-4bit).
//
// THE FIX (v0.7.3): the extraction eagerly builds ONE fused cache and
// shares it wrapper↔extracted (`SwitchGLU.shareFusedGateUpCache`), so the
// load-time footprint returns to the pre-v0.7.2 steady state
// (weights + ONE fused cache — what a 0.7.1 box reached after its first
// request). This test asserts, on the real checkpoint:
//
//   1. GROWTH BOUND — extraction WITH the parity probe (production default)
//      grows MLX active memory by at most ONE fused cache (+ tolerance),
//      not two.
//   2. STEADY STATE AT LOAD — re-running both probe forwards afterwards
//      grows active memory by ~nothing: no lazy build is waiting to fire
//      mid-serving.
//   3. ADMISSION — a `GlobalKVCacheBudget` viewing the post-extraction MLX
//      state through a simulated 64 GB profile admits a typical worst-case
//      request reservation (the incident's first-request rejection,
//      inverted).
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
    /// the qat-4bit build when only that one is cached — the fused-cache
    /// sharing invariant is checkpoint-independent.
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
        #expect(extraction.sharedFusedMoELayerCount > 0)

        let activeAfter = MLX.GPU.activeMemory
        let cacheAfter = MLX.GPU.cacheMemory
        let activeGrowth = max(0, activeAfter - activeBefore)
        // ONE shared fused MoE cache is the only legitimate retained growth.
        let fusedBytes = slot.model.namedModules()
            .compactMap { ($0.1 as? SwitchGLU)?.fusedGateUpCacheBytes }
            .reduce(0, +)
        // The extraction's own measurement — what the slot factory nets out
        // of the v2 KV ceiling (PR#508 finding 2) — must agree with the
        // wrapper-side sum (shared arrays, counted once).
        #expect(extraction.fusedMoECacheBytes == fusedBytes)
        #expect(extraction.fusedMoECacheBytes > 0)
        print(
            "[parity-mem] post-extraction: active=\(Self.gib(activeAfter)) "
                + "cache=\(Self.gib(cacheAfter)) activeGrowth=\(Self.gib(activeGrowth)) "
                + "sharedFusedCache=\(Self.gib(fusedBytes)) "
                + "layers=\(extraction.sharedFusedMoELayerCount)")

        // 1. GROWTH BOUND: at most ONE fused cache (+ 2 GiB tolerance for
        //    rope tables / compiled-graph constants / probe stragglers).
        //    Pre-fix, this measured fusedBytes × 2 (30.13 GiB on 8-bit).
        let tolerance = 2 * 1024 * 1024 * 1024
        #expect(
            activeGrowth < fusedBytes + tolerance,
            Comment(
                rawValue: "extraction + parity probe retained \(Self.gib(activeGrowth)) "
                    + "(> one shared fused cache \(Self.gib(fusedBytes)) + 2 GiB) — a second "
                    + "fused/weight copy is being built (the v0.7.2 black hole)"))
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

        // 4. CAPACITY CONSISTENCY (PR#508 finding 2): the v2 static ceiling —
        //    the weights-derived grant netted of the MEASURED fused cache,
        //    exactly what the slot factory now hands `makeProductionEngine`
        //    and the heartbeat advertises — must equal the shared gate's
        //    live headroom on the same simulated 64 GB profile. Pre-fix the
        //    unadjusted grant exceeded that headroom by the cache size
        //    (~1.7×), so the coordinator over-routed into gate rejects.
        MLX.Stream().synchronize()
        MLX.Memory.clearCache()
        let mlxUsedNow =
            UInt64(max(0, MLX.GPU.activeMemory)) + UInt64(max(0, MLX.GPU.cacheMemory))
        // Resident weights as the static derivation would see them: live MLX
        // usage minus the (measured) engine-retained cache.
        let residentWeights =
            mlxUsedNow > UInt64(extraction.fusedMoECacheBytes)
            ? mlxUsedNow - UInt64(extraction.fusedMoECacheBytes) : 0
        let baseCeiling = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: Int(min(residentWeights, UInt64(Int.max))),
            coResidentWeightBytes: 0,
            existingEngineKVCapacities: [],
            physicalBytes: totalBytes)
        let grantedCeiling = EngineV2KVSizing.netOfEngineResidentOverhead(
            baseCeiling, overheadBytes: extraction.fusedMoECacheBytes)
        let gateHeadroom = UnifiedMemoryCap.liveKVHeadroomBytes(
            physicalBytes: totalBytes,
            mlxUsedBytes: mlxUsedNow,
            systemAvailableBytes: .max)
        print(
            "[parity-mem] 64GB-profile capacity: base=\(Self.gib(baseCeiling)) "
                + "granted=\(Self.gib(grantedCeiling)) gateHeadroom=\(Self.gib(Int(gateHeadroom)))")
        #expect(
            UInt64(grantedCeiling) == gateHeadroom,
            Comment(
                rawValue: "advertised v2 ceiling \(Self.gib(grantedCeiling)) != shared-gate "
                    + "headroom \(Self.gib(Int(gateHeadroom))) — heartbeat max and the gate "
                    + "would disagree (the finding-2 over-routing shape)"))
        #expect(
            UInt64(baseCeiling) > gateHeadroom,
            Comment(
                rawValue: "pre-fix (weights-only) ceiling no longer exceeds the gate headroom "
                    + "— the regression premise vanished; re-derive this stage"))
    }
}
