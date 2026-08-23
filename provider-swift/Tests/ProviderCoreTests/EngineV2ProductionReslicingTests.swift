// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore
// MARK: - KV re-slicing across loads/unloads

@Suite("EngineV2 production wiring: KV re-slicing", .serialized)
struct EngineV2ReslicingWiringTests {

    init() {
        // unloadModel / updateAggregateCapacity read MLX GPU counters.
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("second load shrinks the resident engine and wires the newcomer grant")
    func secondLoadShrinksFirstEngine() async throws {
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = ProductionGrantRecorder()
        let (bridgeA, engineA, _) = try await productionBuildAndInstallSlotA(loop, runtime: runtime, recorder: recorder,
        engines: { _, grant in ScriptedCBv2Engine(script: .manual, kvBytesCapacity: grant) })
        let grantA0 = await bridgeA.engineKVBytesCapacity()

        // Load B (gpt-oss): A must SHRINK to its fair share before B's
        // engine is built, and B's grant is its own fair share.
        let sizingB = productionMakeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)
        let bridgeB = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            sizing: sizingB
        )
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            engineV2: bridgeB,
            sizing: sizingB,
            modelType: "gpt_oss")


        let grantA1 = await bridgeA.engineKVBytesCapacity()
        let grantB = await bridgeB.engineKVBytesCapacity()
        #expect(grantA1 < grantA0)
        #expect(grantB > 0)
        #expect(recorder.granted.last == grantB)
        // The shrink flowed through the engine's resize hook.
        #expect(engineA.capacityUpdates.last == grantA1)
    }

    @Test("unload grows the survivor back to the FULL fleet budget")
    func unloadRegrowsSurvivor() async throws {
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = ProductionGrantRecorder()
        let (bridgeA, engineA, _) = try await productionBuildAndInstallSlotA(loop, runtime: runtime, recorder: recorder,
        engines: { _, grant in ScriptedCBv2Engine(script: .manual, kvBytesCapacity: grant) })
        let originalA = await bridgeA.engineKVBytesCapacity()

        let sizingB = productionMakeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)
        let bridgeB = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            sizing: sizingB
        )
        await runtime.register(modelId: "gpt-oss-20b", bridge: bridgeB)
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            engineV2: bridgeB,
            sizing: sizingB,
            modelType: "gpt_oss")
        let shrunkA = await bridgeA.engineKVBytesCapacity()

        // Unload B: the production path restores A's original construction grant.
        await loop.unloadModel("gpt-oss-20b")
        let grownA = await bridgeA.engineKVBytesCapacity()
        #expect(grownA == originalA)
        #expect(grownA > shrunkA)
        #expect(engineA.capacityUpdates.last == grownA)
    }

    @Test("all-paged co-residency: the shrink strands physical KV, the regrow is deferred, and both residues are measured")
    func allPagedCoResidencyStrandsThenDefers() async throws {
        // THE POST-FLIP SHAPE. Once `.auto` resolves `.paged` there is no
        // contiguous slot left to contrast against — BOTH co-resident slots
        // are paged — so the surviving asymmetry is not paged-vs-contiguous.
        // It is between a slot's CONSTRUCTION-FIXED pool and the fair share
        // the fleet re-slicer keeps moving underneath it.
        //
        // Each pool here is smaller than the logical grant its slot was
        // built with: the production shape since #535, where
        // `PagedKVPhysicalCapacityPolicy` bounds physical capacity by useful
        // concurrent context, machine size, and live headroom — never by the
        // grant. (The stale premise in §15 of the migration plan, that a
        // lone paged slot commits ~the whole fleet budget as slabs, predates
        // that policy: it was written in #531 and bounded in #535.)
        //
        // The drill:
        //   1. A loads alone at the FULL fleet budget and materializes a
        //      pool sized for the box as it looked THEN;
        //   2. B arrives and the share is re-cut. A's pool is now LARGER
        //      than A's share — the surplus is STRANDED: re-promised to B on
        //      paper, still held by A's slabs in Metal;
        //   3. B leaves and A's share returns to the whole budget, far past
        //      the pool, which cannot grow — the regrow is DEFERRED.
        // Not one byte moves either way today. Both residues are now
        // MEASURED, which is exactly what a pool resize consumes and the
        // only signal an operator gets with no canary fleet.
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = ProductionGrantRecorder()
        let telemetry = TelemetrySink()
        let enginesBox = ProductionEngineBox()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                emitTelemetry: telemetry.callback(),
                physicalMemoryBytes: productionWiringPhysicalBytes,
                kvBackendKindByModel: [
                    "gemma-4-26b-qat-4bit": .paged,
                    "gpt-oss-20b": .paged,
                ],
                makeEngine: { _, grant in
                    recorder.record(grant)
                    let engine = ScriptedCBv2Engine(
                        script: .manual,
                        kvBytesCapacity: grant,
                        // Demand-shaped pool, capped below the logical grant.
                        kvBytesBackendCapacity: grant * 3 / 5)
                    enginesBox.append(engine)
                    return engine
                }))

        let sizingA = productionMakeSizing(weightsGiB: 15, kvRate: 20_480, maxContext: 262_144)
        let bridgeA = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            modelType: "gemma4",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            sizing: sizingA)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            engineV2: bridgeA,
            sizing: sizingA,
            modelType: "gemma4")
        let engineA = enginesBox.all[0]
        let grantA0 = recorder.granted[0]
        let poolA = grantA0 * 3 / 5
        #expect(await bridgeA.kvBackendKind == .paged)
        #expect(await bridgeA.kvBackendPoolBytes() == UInt64(poolA))
        // A lone slot has not been re-sliced, so there is no residue to
        // report yet — its ceiling IS its pool, by construction.
        #expect(await bridgeA.pagedPoolResizeShortfall() == nil)

        // ---- Load paged B: A's ledger shrinks past its own pool. ----
        let sizingB = productionMakeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)
        let bridgeB = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            sizing: sizingB)
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            engineV2: bridgeB,
            sizing: sizingB,
            modelType: "gpt_oss")
        #expect(await bridgeB.kvBackendKind == .paged)

        let fleetBudget2 = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: productionWiringPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes + sizingB.weightsBytes),
            configReserveBytes: productionWiringReserveBytes)
        let targets = EngineV2KVSizing.resliceGrants(
            existing: [
                .init(
                    modelId: "gemma-4-26b-qat-4bit",
                    fp16KVBytesPerToken: sizingA.fp16KVBytesPerToken,
                    maxContextLength: sizingA.maxContextLength)
            ],
            newcomer: .init(
                modelId: "gpt-oss-20b",
                fp16KVBytesPerToken: sizingB.fp16KVBytesPerToken,
                maxContextLength: sizingB.maxContextLength),
            fleetKVBudgetBytes: fleetBudget2)
        let targetA = try #require(targets["gemma-4-26b-qat-4bit"])
        let targetB = try #require(targets["gpt-oss-20b"])

        // The ledger contract is unchanged: the shrink reaches the engine
        // unclamped and the pool does not move a byte.
        #expect(targetA < poolA)
        #expect(engineA.capacityUpdates.last == targetA)
        #expect(await bridgeA.engineKVBytesCapacity() == targetA)
        #expect(await bridgeA.kvBackendPoolBytes() == UInt64(poolA))
        #expect(await bridgeB.engineKVBytesCapacity() == targetB)

        // …and the shrink's residue is now named: physical KV A still owns
        // after its share was cut. A ledger-only shrink frees nothing, so
        // callers must never bank these bytes.
        let afterLoad = try #require(await bridgeA.pagedPoolResizeShortfall())
        #expect(afterLoad.poolBytes == poolA)
        #expect(afterLoad.requestedBytes == targetA)
        #expect(afterLoad.strandedBytes == poolA - targetA)
        #expect(afterLoad.deferredGrowthBytes == 0)
        #expect(!afterLoad.isExact)

        // DEFECT PIN (migration plan §15). This is the whole reason a pool
        // resize is a release blocker: Σ(logical grants) ≤ fleet budget
        // still holds, but Σ(PHYSICAL pools) does not — A's slabs were
        // sized against a box that no longer exists. When the resize lands
        // this assertion MUST be inverted, not deleted.
        let poolB = await bridgeB.kvBackendPoolBytes()
        #expect(UInt64(targetA + targetB) <= fleetBudget2)
        #expect(UInt64(poolA) + poolB > fleetBudget2)

        // ---- Unload B: the regrow is deferred, not honoured. ----
        await loop.unloadModel("gpt-oss-20b")
        let regrowTarget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: productionWiringPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes),
            configReserveBytes: productionWiringReserveBytes)
        #expect(regrowTarget > UInt64(poolA))
        #expect(engineA.capacityUpdates.last == poolA)
        #expect(await bridgeA.engineKVBytesCapacity() == poolA)
        #expect(await bridgeA.kvBackendPoolBytes() == UInt64(poolA))
        #expect(await bridgeA.slotKVBytesClaim() == poolA)

        let afterUnload = try #require(await bridgeA.pagedPoolResizeShortfall())
        #expect(afterUnload.requestedBytes == Int(regrowTarget))
        #expect(afterUnload.deferredGrowthBytes == Int(regrowTarget) - poolA)
        #expect(afterUnload.strandedBytes == 0)

        // Both residues surfaced, in order, as operator-visible signals —
        // the substitute for a canary fleet.
        let clamps = telemetry.events.filter {
            $0.fields?["operation"]?.description == "paged_pool_resize_clamped"
        }
        #expect(clamps.map { $0.fields?["reason"]?.description } == [
            "unreclaimed_shrink", "deferred_grow",
        ])
        #expect(clamps.allSatisfy { $0.severity == .warn })
        #expect(clamps.allSatisfy { $0.fields?["kv_backend"]?.description == "paged" })
        #expect(clamps.allSatisfy {
            $0.fields?["model"]?.description == "gemma-4-26b-qat-4bit"
        })
        // Raw bytes, never a ratio (Main's ruling): the denominator ships
        // with every delta, so share-of-pool is derivable and the overflow
        // magnitude survives — a clamped ratio would read 1.0 for both of
        // these and lose exactly the number co-residency is diagnosed by.
        // The allowlist filter is applied at the producer, so an unmirrored
        // key would vanish silently; asserting the values back is what
        // proves all three cleared it.
        #expect(clamps.allSatisfy {
            $0.fields?["pool_bytes"]?.description == String(poolA)
        })
        let shrinkEvent = try #require(clamps.first)
        #expect(shrinkEvent.fields?["pool_stranded_bytes"]?.description
            == String(poolA - targetA))
        #expect(shrinkEvent.fields?["pool_deferred_growth_bytes"]?.description == "0")
        let regrowEvent = try #require(clamps.last)
        #expect(regrowEvent.fields?["pool_deferred_growth_bytes"]?.description
            == String(Int(regrowTarget) - poolA))
        #expect(regrowEvent.fields?["pool_stranded_bytes"]?.description == "0")
    }

    @Test("mixed paged+contiguous: only the contiguous survivor can actually take its regrow")
    func mixedPagedContiguousResliceIsLedgerOnly() async throws {
        // A mixed box stays reachable after the flip: `.auto` degrades to
        // contiguous whenever `PagedKVPhysicalCapacityPolicy` cannot carve a
        // ≥1 GiB pool, which is the normal outcome for the SECOND load on a
        // small box. So this pins what mixed now means, rather than the
        // pre-flip paged-vs-contiguous contrast that a paged default erases.
        //
        // Slot A is PAGED with a demand-capped physical pool SMALLER than
        // its logical grant; slot B is contiguous. The ProviderLoop-driven
        // load/unload re-slice must:
        //   * shrink/grow ONLY admission ledgers,
        //   * keep A's physical pool byte-for-byte constant, and
        //   * let the CONTIGUOUS survivor take its regrow in full — the one
        //     thing its paged neighbour cannot do (see
        //     `allPagedCoResidencyStrandsThenDefers`), and the reason a
        //     paged-by-default fleet loses capacity that a mixed one keeps.
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = ProductionGrantRecorder()
        let enginesBox = ProductionEngineBox()
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.setEngineV2SlotHooksForTesting(
            ProviderLoop.EngineV2SlotHooks(
                eosTokenIds: [2],
                physicalMemoryBytes: productionWiringPhysicalBytes,
                kvBackendKindByModel: ["gemma-4-26b-qat-4bit": .paged],
                makeEngine: { modelId, grant in
                    recorder.record(grant)
                    let engine = ScriptedCBv2Engine(
                        script: .manual,
                        kvBytesCapacity: grant,
                        // Paged slot: pool capped below the logical grant.
                        kvBytesBackendCapacity: modelId == "gemma-4-26b-qat-4bit"
                            ? grant * 3 / 5 : 0)
                    enginesBox.append(engine)
                    return engine
                }))

        let sizingA = productionMakeSizing(weightsGiB: 15, kvRate: 20_480, maxContext: 262_144)
        let bridgeA = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            modelType: "gemma4",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            sizing: sizingA)
        await loop.installModelSlotForTesting(
            modelId: "gemma-4-26b-qat-4bit",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            engineV2: bridgeA,
            sizing: sizingA,
            modelType: "gemma4")
        let engineA = enginesBox.all[0]
        let grantA0 = recorder.granted[0]
        let poolA = UInt64(grantA0 * 3 / 5)
        #expect(await bridgeA.kvBackendKind == .paged)
        #expect(await bridgeA.kvBackendPoolBytes() == poolA)
        // Fleet accounting reads pool truth for the paged slot, not the
        // (larger) logical ledger.
        #expect(await bridgeA.slotKVBytesClaim() == Int(poolA))

        // Load contiguous B: A's admission ledger shrinks to its fair
        // share; the physical pool is untouched.
        let sizingB = productionMakeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)
        let bridgeB = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            sizing: sizingB)
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            engineV2: bridgeB,
            sizing: sizingB,
            modelType: "gpt_oss")
        let engineB = enginesBox.all[1]
        #expect(await bridgeB.kvBackendKind == .contiguous)

        let fleetBudget2 = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: productionWiringPhysicalBytes,
            residentWeightBytes: UInt64(sizingA.weightsBytes + sizingB.weightsBytes),
            configReserveBytes: productionWiringReserveBytes)
        let targets = EngineV2KVSizing.resliceGrants(
            existing: [
                .init(
                    modelId: "gemma-4-26b-qat-4bit",
                    fp16KVBytesPerToken: sizingA.fp16KVBytesPerToken,
                    maxContextLength: sizingA.maxContextLength)
            ],
            newcomer: .init(
                modelId: "gpt-oss-20b",
                fp16KVBytesPerToken: sizingB.fp16KVBytesPerToken,
                maxContextLength: sizingB.maxContextLength),
            fleetKVBudgetBytes: fleetBudget2)
        let targetA = try #require(targets["gemma-4-26b-qat-4bit"])
        let targetB = try #require(targets["gpt-oss-20b"])
        // The two-model fair share sits below the pool here, so the shrink
        // reaches the engine unclamped — and the pool still never moved.
        #expect(UInt64(targetA) < poolA)
        #expect(engineA.capacityUpdates.last == targetA)
        #expect(await bridgeA.engineKVBytesCapacity() == targetA)
        #expect(await bridgeA.kvBackendPoolBytes() == poolA)
        #expect(await bridgeB.engineKVBytesCapacity() == targetB)
        // The paged slot is holding physical KV its share no longer covers.
        #expect(
            await bridgeA.pagedPoolResizeShortfall()?.strandedBytes
                == Int(poolA) - targetA)
        // A contiguous slot resizes ledger and physical capacity together,
        // so it has no residue to report at all.
        #expect(await bridgeB.pagedPoolResizeShortfall() == nil)

        // Unload the PAGED slot: the contiguous survivor's regrow target is
        // the FULL fleet budget under its own weights, and — unlike its
        // paged neighbour, whose identical regrow clamps to pool truth — it
        // takes every byte.
        await loop.unloadModel("gemma-4-26b-qat-4bit")
        let regrowB = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: productionWiringPhysicalBytes,
            residentWeightBytes: UInt64(sizingB.weightsBytes),
            configReserveBytes: productionWiringReserveBytes)
        #expect(regrowB > UInt64(targetB))
        #expect(engineB.capacityUpdates.last == Int(regrowB))
        #expect(await bridgeB.engineKVBytesCapacity() == Int(regrowB))
        #expect(await bridgeB.slotKVBytesClaim() == Int(regrowB))
        #expect(await bridgeB.pagedPoolResizeShortfall() == nil)
    }



    @Test("regression: a regrow parked on the re-slice gate cannot interleave mid-load")
    func regrowParkedOnGateCannotInterleaveMidLoad() async throws {
        // The reviewer-flagged race: the idle monitor's unloadModel →
        // resliceGrowSurvivors runs from its own task, NOT under the
        // isLoadingAny load gate. Without the re-slice gate it could run
        // in the middle of a load's shrink → build → install stretch —
        // recompute over the survivor ALONE (the newcomer's slot isn't
        // installed yet) and re-inflate it to the full single-model budget
        // while the newcomer holds its own grant: Σ(grants) > fleet budget.
        //
        // Deterministic shape: hold the gate via the seam (standing in for
        // an in-flight load), park a regrow behind it, install the
        // newcomer while the gate is held (as the real load does), then
        // release. The parked regrow must (a) mutate NOTHING while the
        // gate is held and (b) recompute over BOTH slots after release.
        let loop = try productionMakeWiringLoop()
        let runtime = EngineV2Runtime()
        let recorder = ProductionGrantRecorder()
        let (bridgeA, engineA, _) = try await productionBuildAndInstallSlotA(loop, runtime: runtime, recorder: recorder,
        engines: { _, grant in ScriptedCBv2Engine(script: .manual, kvBytesCapacity: grant) })
        let sizingB = productionMakeSizing(weightsGiB: 12, kvRate: 24_576, maxContext: 131_072)

        // Capture the production path's actual two-slot grants. Pure policy
        // arithmetic is covered by EngineV2ResliceTests; this suite only
        // replays the values through the coordination seam.
        let probeB = try await loop.resliceAndBuildEngineV2SlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            sizing: sizingB)
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            engineV2: probeB,
            sizing: sizingB,
            modelType: "gpt_oss")
        let targetA = await bridgeA.engineKVBytesCapacity()
        let targetB = await probeB.engineKVBytesCapacity()
        await loop.unloadModel("gpt-oss-20b")
        let updatesBeforeRace = engineA.capacityUpdates.count

        // "Load in flight": the gate is held, A already shrunk to its
        // two-model share and B's engine built with its own grant — but
        // B's slot not yet installed (the exact mid-stretch state).
        await loop.acquireResliceGateForTesting()
        await bridgeA.updateKVBytesCapacity(targetA)

        // The idle-unload regrow fires NOW, mid-stretch.
        let regrow = Task { await loop.resliceGrowSurvivorsForTesting() }
        // Give it ample time to run if it were NOT parked (without the
        // gate it completes in microseconds and re-inflates A).
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            engineA.capacityUpdates.count == updatesBeforeRace + 1,
            "regrow must be parked while the gate is held — no grant mutation")
        #expect(await bridgeA.engineKVBytesCapacity() == targetA)

        // The load completes its stretch: B's engine + slot installed,
        // gate released.
        let engineB = ScriptedCBv2Engine(script: .manual, kvBytesCapacity: targetB)
        let bridgeB = EngineV2Bridge(
            engine: engineB,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            eosTokenIds: [2])
        await runtime.register(modelId: "gpt-oss-20b", bridge: bridgeB)
        await loop.installModelSlotForTesting(
            modelId: "gpt-oss-20b",
            container: productionMakeStubContainer(),
            tokenizer: TokenizerHandle(productionWiringStubTokenizer()),
            engineV2: bridgeB,
            sizing: sizingB,
            modelType: "gpt_oss")
        await loop.releaseResliceGateForTesting()
        await regrow.value

        // The parked regrow recomputed over BOTH slots: the production
        // two-slot grants stand and A is not re-inflated.
        let grantA = await bridgeA.engineKVBytesCapacity()
        let grantB = await bridgeB.engineKVBytesCapacity()
        #expect(grantA == targetA, "regrow must not re-inflate A past its two-model share")
        #expect(grantB == targetB)
    }

}
