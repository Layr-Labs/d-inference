import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

private func deadlineWorkBridge(model: String, budget: GlobalKVCacheBudget,
    profile: DeadlinePerformanceProfile? = nil) -> EngineV2Bridge {
    EngineV2Bridge(engine: PrefillScriptEngine(), modelId: model,
        tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [],
        deadlineProfile: profile, kvBudget: budget)
}

private func deadlineWorkCapacity(_ bridges: [EngineV2Bridge], budget: GlobalKVCacheBudget) async -> BackendCapacity {
    var slots: [BackendSlotCapacity] = []
    for bridge in bridges { slots.append(await bridge.backendSlotCapacity()) }
    let snapshot = budget.serviceBudget.capacitySnapshot(slots: slots)
    for index in slots.indices { slots[index].deadlineWork = snapshot.deadlineWorkByModel[slots[index].model] }
    return BackendCapacity(slots: slots, wholeMacServiceUsed: snapshot.usedFraction,
        wholeMacServiceReservations: snapshot.reservations, gpuMemoryActiveGb: 1,
        gpuMemoryPeakGb: 1, gpuMemoryCacheGb: 0, totalMemoryGb: 64)
}

@Test func unprofiledSSDActivityDoesNotAddDeadlineWorkOrMaterialHeartbeats() async throws {
    let service = WholeMacServiceBudget(posture: DeadlinePostureState())
    let budget = GlobalKVCacheBudget(memorySnapshot: {
        .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
    }, serviceBudget: service)
    let bridge = deadlineWorkBridge(model: "unprofiled", budget: budget)
    let before = await deadlineWorkCapacity([bridge], budget: budget)
    #expect(before.slots[0].deadlineWork == nil)
    let activity = service.beginUnboundedActivity()
    let during = await deadlineWorkCapacity([bridge], budget: budget)
    activity.finish()
    let after = await deadlineWorkCapacity([bridge], budget: budget)
    #expect(during.slots[0].deadlineWork == nil && after.slots[0].deadlineWork == nil)
    #expect(!CapacityHeartbeatMateriality.isMaterial(previous: before, current: during))
    #expect(!CapacityHeartbeatMateriality.isMaterial(previous: during, current: after))
    let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(after.slots[0])) as? [String: Any])
    #expect(wire["deadline_work"] == nil)

    let reservation = UUID().uuidString.lowercased()
    #expect(service.acquire(ownerID: "retiring", concurrency: 24, serviceReservationID: reservation))
    let owned = await deadlineWorkCapacity([bridge], budget: budget)
    #expect(owned.wholeMacServiceUsed == 1.0 / 24.0)
    #expect(owned.wholeMacServiceReservations == [.init(id: reservation, usedFraction: 1.0 / 24.0)])
    #expect(CapacityHeartbeatMateriality.isMaterial(previous: after, current: owned))
    service.release(ownerID: "retiring")
    #expect(CapacityHeartbeatMateriality.isMaterial(previous: owned,
        current: await deadlineWorkCapacity([bridge], budget: budget)))
    await bridge.shutdown()
}

@Test func retainedTimingProfileKeepsAllSlotWorkDuringTemporaryWithdrawal() async throws {
    let service = WholeMacServiceBudget(posture: DeadlinePostureState())
    let budget = GlobalKVCacheBudget(memorySnapshot: {
        .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
    }, serviceBudget: service)
    let profile = deadlineCalibrationProfileFixture()
    let profiled = deadlineWorkBridge(model: profile.modelId, budget: budget, profile: profile)
    let unprofiled = deadlineWorkBridge(model: "other", budget: budget)
    let bridges = [profiled, unprofiled]
    let before = await deadlineWorkCapacity(bridges, budget: budget)
    // No eligible posture has ever been observed. The immutable resolved
    // profile still requests all-slot work for cooldown/recovery accounting.
    #expect(before.slots.allSatisfy { $0.deadlineProfile == nil })
    #expect(before.slots.allSatisfy { $0.deadlineWork?.known == true })
    let activity = service.beginUnboundedActivity()
    let during = await deadlineWorkCapacity(bridges, budget: budget)
    #expect(during.slots.allSatisfy { $0.deadlineWork?.known == false })
    #expect(CapacityHeartbeatMateriality.isMaterial(previous: before, current: during))
    activity.finish()
    let after = await deadlineWorkCapacity(bridges, budget: budget)
    #expect(after.slots.allSatisfy { $0.deadlineWork?.known == true })
    #expect(CapacityHeartbeatMateriality.isMaterial(previous: during, current: after))
    // Removing the last profiled bridge withdraws all timing-only fields.
    let unloaded = await deadlineWorkCapacity([unprofiled], budget: budget)
    #expect(unloaded.slots[0].deadlineWork == nil)
    await profiled.shutdown()
    await unprofiled.shutdown()
}
