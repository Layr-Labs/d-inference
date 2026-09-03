// Copyright © 2026 Eigen Labs.
//
// Live (weight-gated) regression for Gemma 4 VLM shared-tower residency.
// The loaded MLXVLM wrapper must expose its already-owned text tower to
// CBv2 without constructing a second module or retaining a second checkpoint
// worth of state. On a real production checkpoint this suite proves:
//
//   1. DIRECT RESOLUTION — production model resolution returns the wrapper's
//      exact `textModel` object with negligible active-memory growth.
//   2. STEADY STATE — direct VLM and CBv2 forwards over that one object do not
//      trigger a second lazy multi-GiB module cache.
//   3. ADMISSION — the post-forward shared KV budget remains serveable on the
//      incident 64 GB profile.
//   4. CAPACITY CONSISTENCY — weights-derived capacity and live headroom stay
//      aligned because no separately reconstructed tower is resident.
//
// Gated by DARKBLOOM_LIVE_MLX_TESTS + DARKBLOOM_LIVE_MLX_GEMMA and skipped
// cleanly when no checkpoint is cached.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM
import Testing

@testable import ProviderCore

@Suite("Gemma 4 VLM shared-tower memory hygiene (live)", .serialized)
struct GemmaVLMSharedTowerMemoryLiveTests {

    /// The incident checkpoint (catalog id `gemma-4-26b-8bit`); falls back to
    /// the qat-4bit build when only that one is cached — the no-retained-
    /// growth invariant is checkpoint-independent.
    private static let preferredModelIDs = [
        LiveInferenceFixtures.gemmaModelID,
        "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
    ]

    private struct LoadedVLMSlot {
        let modelID: String
        let container: ModelContainer
        let model: any LanguageModel
        /// Scheduler-free sizing snapshot (v0.7.5 one-engine): the fp16 KV
        /// rate + weight bytes production feeds the load gate, the re-slice,
        /// and `makeEngineV2BridgeForSlot` (the legacy `BatchScheduler`
        /// surfaces this test used to read are deleted).
        let sizing: SlotSizingSnapshot
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
        // Same post-load sizing pass production runs (ProviderLoop+
        // ModelLoading): weight walk + engine-truth fp16 KV rate. Pure
        // reads — nothing here may allocate MLX state, so it cannot
        // perturb the growth baselines below.
        let sizing = await SlotSizingSnapshot.build(
            container: container,
            modelPath: directory,
            fallbackDefaultMaxTokens: 256)
        let snapshot = await container.perform { ctx in
            EngineV2ModelSnapshot(
                model: ctx.model,
                eosTokenIds: ctx.configuration.eosTokenIds,
                extraEOSTokens: [])
        }
        return LoadedVLMSlot(
            modelID: modelID,
            container: container,
            model: snapshot.model,
            sizing: sizing
        )
    }

    private static func gib(_ bytes: Int) -> String {
        String(format: "%.2f GiB", Double(bytes) / (1024 * 1024 * 1024))
    }

    @Test(
        "direct shared tower leaves the KV budget serveable (64 GB profile)",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func sharedTowerMemoryHygieneAndBudgetAdmission() async throws {
        let slot = try await loadFirstCachedVLMSlot()
        // The multi-GB residency dies with `slot` at scope exit; trim forward
        // buffers so the next serialized live suite starts from a clean pool.
        defer { MLX.Memory.clearCache() }
        try await runBody(slot)
    }

    private func runBody(_ slot: LoadedVLMSlot) async throws {
        // Mirror production: trim cold-load pool state before direct serving
        // model resolution and take the residency baseline.
        MLX.Stream().synchronize()
        MLX.Memory.clearCache()
        let activeBefore = MLX.GPU.activeMemory
        let sysBefore = SystemMemory.availableBytes() ?? 0
        print(
            "[shared-tower-mem] pre-resolution: active=\(Self.gib(activeBefore)) "
                + "cache=\(Self.gib(MLX.GPU.cacheMemory)) sysAvail=\(Self.gib(Int(sysBefore)))")

        let wrapper = try #require(
            slot.model as? MLXVLM.Gemma4,
            "production Gemma 4 slot must load the MLXVLM.Gemma4 wrapper")
        let owned = wrapper.textModel
        let serving = try EngineV2Factory.directServingModel(
            model: wrapper, isVLM: true)
        let textModel = try #require(serving as? MLXLLM.Gemma4TextModel)
        #expect(ObjectIdentifier(owned) == ObjectIdentifier(textModel))

        let activeAfter = MLX.GPU.activeMemory
        let activeGrowth = max(0, activeAfter - activeBefore)
        print(
            "[shared-tower-mem] post-resolution: active=\(Self.gib(activeAfter)) "
                + "activeGrowth=\(Self.gib(activeGrowth))")
        let tolerance = 64 * 1024 * 1024
        #expect(
            activeGrowth < tolerance,
            Comment(
                rawValue: "direct tower resolution retained \(Self.gib(activeGrowth)) "
                    + "(> 64 MiB), suggesting a second module or weight copy"))

        // Direct VLM and CBv2 paths call the same object. A second forward must
        // not materialize a second per-tree cache.
        let probeTokens = MLXArray([2, 65, 61, 24, 57, 10, 23].map(Int32.init))
            .expandedDimensions(axis: 0)
        eval(wrapper(probeTokens, cache: nil))
        eval(textModel(probeTokens, cache: nil))
        MLX.Stream().synchronize()
        MLX.Memory.clearCache()
        let activeSteady = MLX.GPU.activeMemory
        let steadyGrowth = max(0, activeSteady - activeAfter)
        print(
            "[shared-tower-mem] steady-state re-forward growth=\(Self.gib(steadyGrowth))")
        #expect(
            steadyGrowth < 512 * 1024 * 1024,
            Comment(
                rawValue: "shared-tower forwards grew active memory by "
                    + "\(Self.gib(steadyGrowth)); a lazy duplicate cache fired"))
        // Admission on the incident 64 GB profile: the live post-forward
        // counters must admit a typical worst-case request.
        let fp16Rate = slot.sizing.fp16KVBytesPerToken
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
            "[shared-tower-mem] 64GB-profile admission: fp16KVBytesPerToken=\(fp16Rate) "
                + "worstCaseTokens=\(worstCaseTokens) admitted=\(admitted)")
        #expect(
            admitted,
            Comment(
                rawValue: "the shared KV budget rejected a typical request on the "
                    + "64 GB profile after direct shared-tower resolution"))
        await budget.release(requestID: "incident-probe")
        #expect(await budget.reservationIDsForTesting().isEmpty)

        // Capacity consistency: direct ownership leaves no separately
        // reconstructed model state for the weights-derived ceiling to miss.
        MLX.Stream().synchronize()
        MLX.Memory.clearCache()
        let snapshotWeightBytes = slot.sizing.weightsBytes
        let mlxUsedNow =
            UInt64(max(0, MLX.GPU.activeMemory)) + UInt64(max(0, MLX.GPU.cacheMemory))
        let ceiling = EngineV2KVSizing.engineKVBytesCapacity(
            newModelWeightBytes: snapshotWeightBytes,
            coResidentWeightBytes: 0,
            existingEngineKVCapacities: [],
            physicalBytes: totalBytes)
        let gateHeadroom = UnifiedMemoryCap.liveKVHeadroomBytes(
            physicalBytes: totalBytes,
            mlxUsedBytes: mlxUsedNow,
            systemAvailableBytes: .max)
        let retainedOverhead = Int64(ceiling) - Int64(clamping: gateHeadroom)
        print(
            "[shared-tower-mem] 64GB-profile capacity: ceiling=\(Self.gib(ceiling)) "
                + "gateHeadroom=\(Self.gib(Int(gateHeadroom))) "
                + "retainedOverhead=\(Self.gib(Int(retainedOverhead)))")
        let capacityTolerance = 2 * 1024 * 1024 * 1024
        #expect(
            retainedOverhead <= Int64(capacityTolerance),
            Comment(
                rawValue: "weights-derived v2 ceiling \(Self.gib(ceiling)) exceeds the "
                    + "shared-gate live headroom \(Self.gib(Int(gateHeadroom))) by more "
                    + "than the retained-state bar, indicating unaccounted residency"))
        #expect(
            retainedOverhead >= -(64 * 1024 * 1024),
            Comment(
                rawValue: "shared-gate headroom exceeds the weights-derived ceiling — "
                    + "live MLX usage measured below the snapshot's resident weights, "
                    + "which means the weight figure itself is inflated"))
    }
}
