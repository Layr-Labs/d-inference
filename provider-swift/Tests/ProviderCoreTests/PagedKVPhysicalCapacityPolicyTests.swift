// Copyright © 2026 Eigen Labs.

import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("PagedKV physical capacity policy")
struct PagedKVPhysicalCapacityPolicyTests {
    private let gib = 1 << 30

    private func decision(
        physicalGiB: Int,
        liveGiB: Int,
        logicalGiB: Int = 200,
        rate: Int = 48 * 1024,
        context: Int = 131_072,
        concurrency: Int = 4,
        maxBufferGiB: Int = 32
    ) -> PagedKVPhysicalCapacityPolicy.Decision {
        PagedKVPhysicalCapacityPolicy.decide(
            logicalGrantBytes: logicalGiB * gib,
            fp16BytesPerToken: rate,
            maxContextLength: context,
            maxConcurrentRequests: concurrency,
            inputs: .init(
                physicalMemoryBytes: UInt64(physicalGiB * gib),
                liveKVHeadroomBytes: UInt64(liveGiB * gib),
                maxBufferLength: maxBufferGiB * gib))
    }

    @Test("32/64/128/256 GiB hosts stay useful without scaling to the logical grant")
    func machineSizingMatrix() {
        let cases = [
            (physical: 32, live: 16, expectedGiB: 2),
            (physical: 64, live: 32, expectedGiB: 4),
            (physical: 128, live: 64, expectedGiB: 6),
            (physical: 256, live: 128, expectedGiB: 6),
        ]
        for item in cases {
            guard case .paged(let plan) = decision(
                physicalGiB: item.physical,
                liveGiB: item.live)
            else {
                Issue.record("\(item.physical) GiB host unexpectedly fell back")
                continue
            }
            #expect(plan.capacityBytes == item.expectedGiB * gib)
            #expect(plan.capacityBytes < 200 * gib)
            #expect(plan.capacityBytes <= PagedKVPhysicalCapacityPolicy.absoluteHardCapBytes)
        }
    }

    @Test("live memory and maxBufferLength can force a pre-allocation contiguous fallback")
    func resourceLimitsFailClosed() {
        #expect(
            decision(physicalGiB: 128, liveGiB: 3)
                == .contiguous(
                    reason: "physical_capacity: safe pool 805306368 B is below "
                        + "the 1073741824 B serviceability floor"))
        #expect(
            decision(
                physicalGiB: 128,
                liveGiB: 64,
                maxBufferGiB: 0)
                == .contiguous(
                    reason: "physical_capacity: Metal maxBufferLength unavailable"))
    }

    @Test("mixed-model load order remains bounded by live and machine caps")
    func mixedModelLoadOrders() {
        let rates = [48 * 1024, 32 * 1024]

        func loadOrder(_ order: [Int]) -> [Int] {
            var live = 40 * gib
            var pools: [Int] = []
            for index in order {
                let result = PagedKVPhysicalCapacityPolicy.decide(
                    logicalGrantBytes: 40 * gib,
                    fp16BytesPerToken: rates[index],
                    maxContextLength: 131_072,
                    maxConcurrentRequests: 4,
                    inputs: .init(
                        physicalMemoryBytes: UInt64(64 * gib),
                        liveKVHeadroomBytes: UInt64(live),
                        maxBufferLength: 32 * gib))
                guard case .paged(let plan) = result else {
                    Issue.record("mixed-model load \(index) unexpectedly fell back")
                    continue
                }
                pools.append(plan.capacityBytes)
                live -= plan.capacityBytes
            }
            return pools
        }

        let gptThenGemma = loadOrder([0, 1])
        let gemmaThenGPT = loadOrder([1, 0])
        #expect(gptThenGemma.reduce(0, +) == 8 * gib)
        #expect(gemmaThenGPT.reduce(0, +) == 8 * gib)
        #expect((gptThenGemma + gemmaThenGPT).allSatisfy { $0 <= 4 * gib })
    }

    // MARK: - D1: slab commitment and multi-model co-residency
    //
    // These MODEL a box rather than requiring one. Every derived figure is
    // produced by the production functions the daemon actually calls —
    // `UnifiedMemoryCap.hardCapBytes`/`kvBudgetBytes`/`liveKVHeadroomBytes`,
    // `PagedKVPhysicalCapacityPolicy.decide`, `EngineV2KVSizing.resliceGrants`
    // and `KVHeadroomProbe.postBuildServeable` — so the only fiction is
    // `physicalMemoryBytes` and the per-model weights. A regression in any of
    // those functions fails these tests exactly as it would on the hardware.
    //
    // Determinism: activation reserve and cap fraction are passed EXPLICITLY
    // everywhere. Both otherwise resolve from the environment
    // (`DARKBLOOM_ACTIVATION_RESERVE_GB`, `DARKBLOOM_MEM_CAP_FRACTION`), which
    // would make the arithmetic depend on the shell that ran the suite.

    private var activationReserve: UInt64 { UnifiedMemoryCap.defaultActivationReserveBytes }
    private var capFraction: Double { UnifiedMemoryCap.defaultCapFraction }

    /// Bytes as GiB to two decimals — the unit the D1 report states its
    /// measurements in.
    private static func gib2dp(_ bytes: UInt64) -> Double {
        (Double(bytes) / Double(1 << 30) * 100).rounded() / 100
    }

    /// One modelled machine, mutated as models load.
    private struct Box {
        let physicalBytes: UInt64
        let activationReserve: UInt64
        let capFraction: Double
        /// Resident model weights — MLX active memory that is not KV.
        var weightBytes: UInt64 = 0
        /// Paged slab bytes actually WIRED. The pre-D1 eager posture puts a
        /// pool here at engine construction; `.atFirstAdmission` leaves an
        /// idle pool out of it entirely.
        var wiredPoolBytes: UInt64 = 0

        /// What `KVHeadroomProbe.measuredLiveKVHeadroomBytes` would read:
        /// MLX active + cache is modelled as weights plus wired slabs.
        var measuredHeadroomBytes: UInt64 {
            UnifiedMemoryCap.liveKVHeadroomBytes(
                physicalBytes: physicalBytes,
                mlxUsedBytes: weightBytes + wiredPoolBytes,
                systemAvailableBytes: .max,
                activationReserveBytes: activationReserve,
                capFraction: capFraction)
        }

        /// The fleet KV budget the re-slicer splits. Derived from RESIDENT
        /// WEIGHTS only, so it is identical under both commitment postures —
        /// which is what keeps the logical gates out of the D1 comparison.
        var fleetKVBudgetBytes: UInt64 {
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: physicalBytes,
                residentWeightBytes: weightBytes,
                activationReserveBytes: activationReserve,
                capFraction: capFraction)
        }
    }

    /// One model in the modelled fleet.
    private struct Slot {
        let id: String
        let weightBytes: UInt64
        let rate: Int
        var context: Int = 131_072
    }

    private func resliceSlot(_ slot: Slot) -> EngineV2KVSizing.ResliceSlot {
        .init(
            modelId: slot.id, fp16KVBytesPerToken: slot.rate,
            maxContextLength: slot.context)
    }

    /// Outcome of loading one slot onto a box, in the daemon's order:
    /// weights land, the re-slicer hands down a logical grant (refusing the
    /// load outright if any slot would fall below the serviceability floor),
    /// the backend is chosen and sized, and finally the post-build guard
    /// re-measures live headroom.
    private struct LoadOutcome {
        var resliceRefused = false
        var poolBytes = 0
        var degradedToContiguous = false
        var serveable = false
        var measuredHeadroomBytes: UInt64 = 0
    }

    private func load(
        _ slot: Slot,
        onto box: inout Box,
        alreadyResident: [Slot],
        commitment: PagedKVSlabCommitment
    ) -> LoadOutcome {
        var outcome = LoadOutcome()
        box.weightBytes += slot.weightBytes

        // Gate 3 — the LOGICAL serviceability floor. Backend-independent by
        // construction: `resliceGrants` sees rates and contexts, never a pool.
        let grants = EngineV2KVSizing.resliceGrants(
            existing: alreadyResident.map(resliceSlot),
            newcomer: resliceSlot(slot),
            fleetKVBudgetBytes: box.fleetKVBudgetBytes)
        guard EngineV2KVSizing.resliceMeetsServiceabilityFloor(grants) else {
            outcome.resliceRefused = true
            return outcome
        }

        // Backend selection + physical sizing.
        let decision = PagedKVPhysicalCapacityPolicy.decide(
            logicalGrantBytes: grants[slot.id] ?? 0,
            fp16BytesPerToken: slot.rate,
            maxContextLength: slot.context,
            maxConcurrentRequests: 4,
            inputs: .init(
                physicalMemoryBytes: box.physicalBytes,
                liveKVHeadroomBytes: box.measuredHeadroomBytes,
                maxBufferLength: 32 * gib))

        let kind: EngineV2KVBackendKind
        switch decision {
        case .paged(let plan):
            kind = .paged
            outcome.poolBytes = plan.capacityBytes
            box.wiredPoolBytes += UInt64(
                PagedKVPhysicalCapacityPolicy.idleResidencyBytes(
                    capacityBytes: plan.capacityBytes, commitment: commitment))
        case .contiguous:
            kind = .contiguous
            outcome.degradedToContiguous = true
        }

        // Gate 4 — the post-build guard that unloads + 503s.
        outcome.measuredHeadroomBytes = box.measuredHeadroomBytes
        outcome.serveable = KVHeadroomProbe.postBuildServeable(
            kvBackendKind: kind,
            pagedPoolBytes: UInt64(outcome.poolBytes),
            measuredHeadroomBytes: outcome.measuredHeadroomBytes)
        return outcome
    }

    /// The 36 GiB pair from the D1 report: gpt-oss loads first and is paged,
    /// gemma-4 follows. Weights are chosen so the all-lazy residual matches
    /// the 2.40 GiB that was measured on the real box; every other figure
    /// falls out of the production math.
    private static let gptOss = Slot(
        id: "gpt-oss-20b", weightBytes: UInt64(11_776) << 20, rate: 40 * 1024)
    private static let gemma4 = Slot(
        id: "gemma-4-26b-qat-4bit", weightBytes: UInt64(15_872) << 20, rate: 40 * 1024)

    @Test("D1: an idle paged pool must not pre-empt the next model on a 36 GiB box")
    func idlePoolDoesNotPreemptSecondModelOn36GiB() {
        func loadPair(_ commitment: PagedKVSlabCommitment)
            -> (first: LoadOutcome, second: LoadOutcome)
        {
            var box = Box(
                physicalBytes: UInt64(36) << 30,
                activationReserve: activationReserve,
                capFraction: capFraction)
            let first = load(
                Self.gptOss, onto: &box, alreadyResident: [], commitment: commitment)
            let second = load(
                Self.gemma4, onto: &box, alreadyResident: [Self.gptOss],
                commitment: commitment)
            return (first, second)
        }

        let eager = loadPair(.atConstruction)
        let lazy = loadPair(.atFirstAdmission)

        // Preconditions. The first slot is paged and its pool is the 2.25 GiB
        // `physicalMemory / 16` machine cap — the exact figure D1 reported,
        // and identical under both postures because nothing is resident yet.
        #expect(eager.first.serveable)
        #expect(lazy.first.serveable)
        #expect(eager.first.poolBytes == 2_304 << 20, "36 GiB / 16 = 2.25 GiB")
        #expect(lazy.first.poolBytes == eager.first.poolBytes)

        // The LOGICAL gate is not what decides this case: the re-slice floor
        // is cleared under both postures, so the only thing separating them is
        // the physical headroom measurement.
        #expect(!eager.second.resliceRefused)
        #expect(!lazy.second.resliceRefused)

        // THE BUG, and THE FIX, in GiB. Asserted BOTH ways on purpose: the
        // byte literals catch a one-page drift in the sizing math, and the
        // two-decimal GiB figures are the numbers the D1 report was written
        // in, so a reader can check the claim without a calculator.
        #expect(
            eager.second.measuredHeadroomBytes == 161_061_273,
            Comment(rawValue:
                "pre-D1: the second model measures 0.15 GiB — its own headroom minus "
                    + "an untouched 2.25 GiB pool belonging to a slot that has served nothing"))
        #expect(
            lazy.second.measuredHeadroomBytes == 2_576_980_377,
            "post-D1: 2.40 GiB, the same figure an all-contiguous pair measures")
        #expect(Self.gib2dp(eager.second.measuredHeadroomBytes) == 0.15)
        #expect(Self.gib2dp(lazy.second.measuredHeadroomBytes) == 2.40)
        #expect(
            lazy.second.measuredHeadroomBytes - eager.second.measuredHeadroomBytes
                == UInt64(eager.first.poolBytes),
            "the whole difference is the first slot's idle pool, to the byte")
        #expect(Self.gib2dp(UInt64(eager.first.poolBytes)) == 2.25)

        #expect(!eager.second.serveable, "pre-D1 this is the unload + 503")
        #expect(lazy.second.serveable, "post-D1 the second model serves")

        // The floor was NOT lowered to achieve that: 0.15 GiB is still refused
        // and 2.40 GiB is still what clears the unchanged 1 GiB minimum.
        #expect(!UnifiedMemoryCap.loadIsServeable(
            measuredLiveKVHeadroomBytes: eager.second.measuredHeadroomBytes))
        #expect(UnifiedMemoryCap.loadIsServeable(
            measuredLiveKVHeadroomBytes: lazy.second.measuredHeadroomBytes))
        #expect(UnifiedMemoryCap.minimumLoadKVBytes == 1 << 30)

        // And the production posture really is the lazy one — without this the
        // rest of the suite would pass with the bug still shipped.
        #expect(PagedKVPhysicalCapacityPolicy.slabCommitment == .atFirstAdmission)
    }

    /// One fleet, three boxes. Weights and rates are held fixed so that the
    /// MACHINE SIZE is the only variable across the next three tests.
    private static let threeSlotFleet = [
        Slot(id: "a", weightBytes: UInt64(16) << 30, rate: 48 * 1024),
        Slot(id: "b", weightBytes: UInt64(14) << 30, rate: 40 * 1024),
        Slot(id: "c", weightBytes: UInt64(12) << 30, rate: 48 * 1024),
    ]

    private func loadFleet(
        physicalGiB: Int, commitment: PagedKVSlabCommitment
    ) -> [LoadOutcome] {
        var box = Box(
            physicalBytes: UInt64(physicalGiB) << 30,
            activationReserve: activationReserve,
            capFraction: capFraction)
        var resident: [Slot] = []
        var outcomes: [LoadOutcome] = []
        for slot in Self.threeSlotFleet {
            outcomes.append(
                load(slot, onto: &box, alreadyResident: resident, commitment: commitment))
            resident.append(slot)
        }
        return outcomes
    }

    @Test("D1: 128 GiB three-slot behaviour is unchanged by lazy commitment")
    func threeSlotsOn128GiBAreUnchanged() {
        let eager = loadFleet(physicalGiB: 128, commitment: .atConstruction)
        let lazy = loadFleet(physicalGiB: 128, commitment: .atFirstAdmission)

        // 6/5/6 GiB — the pool sequence the 128 GiB box was measured at. Here
        // the binding term is useful demand (32K tokens x 4 rows x rate), with
        // the 8 GiB machine cap above it and live headroom never close, so the
        // sequence cannot depend on whether earlier pools were committed.
        #expect(eager.map(\.poolBytes) == [6 * gib, 5 * gib, 6 * gib])
        #expect(lazy.map(\.poolBytes) == eager.map(\.poolBytes))
        #expect(eager.allSatisfy { $0.serveable && !$0.resliceRefused })
        #expect(lazy.allSatisfy { $0.serveable && !$0.resliceRefused })
        #expect(eager.allSatisfy { !$0.degradedToContiguous })
        #expect(lazy.allSatisfy { !$0.degradedToContiguous })
    }

    @Test("D1: 64 GiB three-slot behaviour is unchanged by lazy commitment")
    func threeSlotsOn64GiBAreUnchanged() {
        let eager = loadFleet(physicalGiB: 64, commitment: .atConstruction)
        let lazy = loadFleet(physicalGiB: 64, commitment: .atFirstAdmission)

        #expect(eager.allSatisfy { $0.serveable && !$0.resliceRefused })
        #expect(lazy.allSatisfy { $0.serveable && !$0.resliceRefused })
        // Lazy never sizes a pool SMALLER than eager: it can only ever see
        // more live headroom, never less. Pin the direction rather than a
        // literal, because on this box the 4 GiB machine cap and live headroom
        // trade places across the three loads.
        for (index, pair) in zip(lazy, eager).enumerated() {
            #expect(
                pair.0.poolBytes >= pair.1.poolBytes,
                "slot \(index): lazy pool \(pair.0.poolBytes) < eager \(pair.1.poolBytes)")
        }
        #expect(eager.map(\.poolBytes).allSatisfy { $0 <= 4 * gib }, "64 GiB / 16")
        #expect(lazy.map(\.poolBytes).allSatisfy { $0 <= 4 * gib })
    }

    @Test("D1: the 48 GiB third-slot refusal is backend-independent and survives")
    func thirdSlotStillRefusedOn48GiB() {
        for commitment in PagedKVSlabCommitment.allCases {
            let outcomes = loadFleet(physicalGiB: 48, commitment: commitment)
            #expect(
                outcomes.prefix(2).allSatisfy { $0.serveable && !$0.resliceRefused },
                "\(commitment): the first two slots must still load")
            #expect(
                outcomes[2].resliceRefused,
                Comment(rawValue:
                    "\(commitment): the third slot must still be refused — 42 GiB of "
                        + "weights plus the 3 GiB activation reserve exceeds the 43.2 GiB "
                        + "cap, so the fleet KV budget is zero and every grant is below "
                        + "the 1 GiB serviceability floor"))
            #expect(!outcomes[2].serveable, "\(commitment): and it must not serve")
        }

        // The refusal is produced by weights-only arithmetic, so no commitment
        // posture can reach it. This is the assertion that stops a future
        // 'fix' from papering over a correct refusal.
        var box = Box(
            physicalBytes: UInt64(48) << 30,
            activationReserve: activationReserve,
            capFraction: capFraction)
        box.weightBytes = Self.threeSlotFleet.reduce(0) { $0 + $1.weightBytes }
        #expect(box.fleetKVBudgetBytes == 0)
        let starvedBudget = box.fleetKVBudgetBytes
        box.wiredPoolBytes = UInt64(8) << 30
        #expect(
            box.fleetKVBudgetBytes == starvedBudget,
            Comment(rawValue:
                "the fleet KV budget is a function of resident WEIGHTS; wired slabs "
                    + "cannot move it in either direction"))
    }

    @Test("D1: lazy commitment leaves the coordinator's free_for_load_gb identical")
    func lazyCommitmentDoesNotMoveTheColdLoadReport() {
        // `free_for_load_gb` is `ModelLoadAdmission.maxLoadableWeightGb` over
        // `min(total, systemAvailable + reclaimableMlx)`, and the coordinator
        // only consults it on the IDLE path (`freeMemoryAdmits` gates the cold
        // branch on totalPending == 0), where `reclaimableMlx == mlxUsed`.
        // Committing the slabs therefore just moves the same bytes between the
        // two summands. Pin that, because a permissive drift here would move
        // the 503 to the coordinator rather than remove it.
        let total = UInt64(36) << 30
        let weights = UInt64(27) << 30
        let pool = UInt64(2_304) << 20
        let reserve = UnifiedMemoryCap.loadReserveBytes(
            physicalBytes: total, configReserveBytes: 0, capFraction: capFraction)

        func report(mlxUsed: UInt64) -> Double {
            ModelLoadAdmission.maxLoadableWeightGb(
                totalBytes: total,
                // The OS sees whatever MLX has actually taken.
                systemAvailableBytes: total - mlxUsed,
                mlxUsedBytes: mlxUsed,
                reserveBytes: reserve,
                headroomGb: 4.0)
        }

        let eager = report(mlxUsed: weights + pool)
        let lazy = report(mlxUsed: weights)
        #expect(eager == lazy, "eager \(eager) GB vs lazy \(lazy) GB")

        // Not vacuous: if a future change stopped treating the pool as
        // reclaimable on the idle path, the two WOULD diverge by the pool.
        let eagerUnreclaimable = ModelLoadAdmission.maxLoadableWeightGb(
            totalBytes: total,
            systemAvailableBytes: total - (weights + pool),
            mlxUsedBytes: 0,
            reserveBytes: reserve,
            headroomGb: 4.0)
        let lazyUnreclaimable = ModelLoadAdmission.maxLoadableWeightGb(
            totalBytes: total,
            systemAvailableBytes: total - weights,
            mlxUsedBytes: 0,
            reserveBytes: reserve,
            headroomGb: 4.0)
        #expect(lazyUnreclaimable > eagerUnreclaimable)
    }
}
