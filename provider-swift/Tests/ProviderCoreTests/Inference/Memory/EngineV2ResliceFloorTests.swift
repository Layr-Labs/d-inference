// Copyright © 2026 Eigen Labs.
//
// `EngineV2KVSizing.resliceGrants` given each slot's serviceability floor:
// the reported 0.10.5 refusal (`ResliceFloorScenario`), the unchanged
// proportional result whenever it already clears every floor, refusal when
// Σ(floors) exceeds the budget, and Σ(grants) ≤ budget throughout.

import Foundation
import Testing

@testable import ProviderCore

@Suite("EngineV2 KV re-slice with slot floors (pure)")
struct EngineV2ResliceFloorTests {
    private static let gib = 1 << 30

    private static func floors(_ models: [ResliceFloorScenario.Model]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.minimumGrantBytes) })
    }

    private static func sum(_ grants: [String: Int]) -> UInt64 {
        grants.values.reduce(UInt64(0)) { $0 + UInt64($1) }
    }

    @Test("the reported refusal: Lightning starves under the proportional split; floors first admits",
          arguments: [
            (ResliceFloorScenario.gemmaQAT.id, ResliceFloorScenario.reportedGemmaBudget),
            (ResliceFloorScenario.gptOSS.id, ResliceFloorScenario.reportedGPTOSSBudget),
          ])
    func reportedRefusalIsAdmitted(newcomerID: String, budget: UInt64) throws {
        let newcomer = newcomerID == ResliceFloorScenario.gptOSS.id
            ? ResliceFloorScenario.gptOSS : ResliceFloorScenario.gemmaQAT
        let residents = try ResliceFloorScenario.residents()
        // The newcomer has only the base floor, as on the load path.
        let minimums = Self.floors(residents)
        let floorTotal = residents.reduce(Int(EngineV2KVSizing.minimumServiceableGrantBytes)) {
            $0 + $1.minimumGrantBytes
        }
        #expect(UInt64(floorTotal) * 5 < budget)

        let proportional = EngineV2KVSizing.resliceGrants(existing: residents.map(\.resliceSlot),
            newcomer: newcomer.resliceSlot, fleetKVBudgetBytes: budget)
        #expect(!EngineV2KVSizing.resliceMeetsServiceabilityFloor(proportional, minimumGrantBytes: minimums))
        let lightningFloor = try #require(minimums[ResliceFloorScenario.lightningID])
        let lightningShare = try #require(proportional[ResliceFloorScenario.lightningID])
        #expect(lightningShare < lightningFloor)

        let grants = EngineV2KVSizing.resliceGrants(existing: residents.map(\.resliceSlot),
            newcomer: newcomer.resliceSlot, fleetKVBudgetBytes: budget, minimumGrantBytes: minimums)
        #expect(EngineV2KVSizing.resliceMeetsServiceabilityFloor(grants, minimumGrantBytes: minimums))
        #expect(grants.count == 7 && Self.sum(grants) <= budget)
        // Each slot holds its floor plus its weighted share of the rest.
        let remainder = EngineV2KVSizing.resliceGrants(existing: residents.map(\.resliceSlot),
            newcomer: newcomer.resliceSlot, fleetKVBudgetBytes: budget - UInt64(floorTotal))
        for slot in residents + [newcomer] {
            let floor = minimums[slot.id] ?? Int(EngineV2KVSizing.minimumServiceableGrantBytes)
            #expect(grants[slot.id] == floor + (remainder[slot.id] ?? 0), "\(slot.id)")
        }
    }

    @Test("a proportional split that clears every floor is returned unchanged")
    func clearingSplitIsUnchanged() throws {
        let residents = try ResliceFloorScenario.residents()
        let sixSlotBudget: UInt64 = 65_459_679_896
        let six = EngineV2KVSizing.resliceGrants(existing: residents.map(\.resliceSlot), newcomer: nil,
            fleetKVBudgetBytes: sixSlotBudget)
        #expect(EngineV2KVSizing.resliceMeetsServiceabilityFloor(six, minimumGrantBytes: Self.floors(residents)))
        #expect(EngineV2KVSizing.resliceGrants(existing: residents.map(\.resliceSlot), newcomer: nil,
            fleetKVBudgetBytes: sixSlotBudget, minimumGrantBytes: Self.floors(residents)) == six)

        let pair = [ResliceFloorScenario.gemmaQAT.resliceSlot]
        let budget = UInt64(40 * Self.gib)
        #expect(EngineV2KVSizing.resliceGrants(existing: pair, newcomer: ResliceFloorScenario.gptOSS.resliceSlot,
            fleetKVBudgetBytes: budget, minimumGrantBytes: [:])
            == EngineV2KVSizing.resliceGrants(existing: pair, newcomer: ResliceFloorScenario.gptOSS.resliceSlot,
                fleetKVBudgetBytes: budget))
    }

    @Test("Σ floors above the budget, or an unprovable floor, keeps the proportional split and refuses")
    func infeasibleFloorsStillRefuse() throws {
        let residents = try ResliceFloorScenario.residents()
        let newcomer = ResliceFloorScenario.gemmaQAT
        let minimums = Self.floors(residents)
        let floorTotal = residents.reduce(Int(EngineV2KVSizing.minimumServiceableGrantBytes)) {
            $0 + $1.minimumGrantBytes
        }
        var unprovable = minimums
        unprovable["gemma-4-26b"] = Int.max
        let cases: [(UInt64, [String: Int])] = [
            (UInt64(floorTotal - 1), minimums),
            (ResliceFloorScenario.reportedGemmaBudget, unprovable),
        ]
        for (budget, floors) in cases {
            let proportional = EngineV2KVSizing.resliceGrants(existing: residents.map(\.resliceSlot),
                newcomer: newcomer.resliceSlot, fleetKVBudgetBytes: budget)
            let grants = EngineV2KVSizing.resliceGrants(existing: residents.map(\.resliceSlot),
                newcomer: newcomer.resliceSlot, fleetKVBudgetBytes: budget, minimumGrantBytes: floors)
            #expect(grants == proportional)
            #expect(!EngineV2KVSizing.resliceMeetsServiceabilityFloor(grants, minimumGrantBytes: floors))
        }
    }

    @Test("Σ grants ≤ budget at every budget; every floor is met exactly when Σ floors fits")
    func budgetInvariantAcrossBudgets() throws {
        let residents = try ResliceFloorScenario.residents()
        let slots = residents.map(\.resliceSlot)
        let newcomer = ResliceFloorScenario.gptOSS.resliceSlot
        let minimums = Self.floors(residents)
        let floorTotal = UInt64(residents.reduce(Int(EngineV2KVSizing.minimumServiceableGrantBytes)) {
            $0 + $1.minimumGrantBytes
        })
        var budgets: [UInt64] = [0, floorTotal - 1, floorTotal, floorTotal + 1, UInt64(Int.max)]
        var step = floorTotal / 2
        while step < 4 * ResliceFloorScenario.reportedGPTOSSBudget {
            budgets.append(step)
            step += 997_001_003
        }
        for budget in budgets {
            let grants = EngineV2KVSizing.resliceGrants(existing: slots, newcomer: newcomer,
                fleetKVBudgetBytes: budget, minimumGrantBytes: minimums)
            #expect(Self.sum(grants) <= min(budget, UInt64(Int.max)), "budget \(budget)")
            #expect(EngineV2KVSizing.resliceMeetsServiceabilityFloor(grants, minimumGrantBytes: minimums)
                == (floorTotal <= budget), "budget \(budget)")
        }
        // At the boundary every slot holds exactly its floor.
        let tight = EngineV2KVSizing.resliceGrants(existing: slots, newcomer: newcomer,
            fleetKVBudgetBytes: floorTotal, minimumGrantBytes: minimums)
        for slot in slots + [newcomer] {
            #expect(tight[slot.modelId] == minimums[slot.modelId] ?? Self.gib, "\(slot.modelId)")
        }
    }

    @Test("an unknown rate splits what remains after the floors equally")
    func unknownRateSplitsRemainderEqually() {
        let starved = EngineV2KVSizing.ResliceSlot(modelId: "a", fp16KVBytesPerToken: 0, maxContextLength: 0)
        let other = EngineV2KVSizing.ResliceSlot(modelId: "b", fp16KVBytesPerToken: 20_480, maxContextLength: 131_072)
        let budget = UInt64(6 * Self.gib)
        let grants = EngineV2KVSizing.resliceGrants(existing: [starved], newcomer: other,
            fleetKVBudgetBytes: budget, minimumGrantBytes: ["a": 4 * Self.gib])
        #expect(grants == ["a": 4 * Self.gib + Self.gib / 2, "b": Self.gib + Self.gib / 2])
    }

    @Test("a single slot keeps the whole budget whatever its floor")
    func singleSlotKeepsWholeBudget() {
        let budget = UInt64(3 * Self.gib)
        let grants = EngineV2KVSizing.resliceGrants(existing: [], newcomer: ResliceFloorScenario.gemmaQAT.resliceSlot,
            fleetKVBudgetBytes: budget, minimumGrantBytes: [ResliceFloorScenario.gemmaQAT.id: 8 * Self.gib])
        #expect(grants == [ResliceFloorScenario.gemmaQAT.id: Int(budget)])
    }
}
