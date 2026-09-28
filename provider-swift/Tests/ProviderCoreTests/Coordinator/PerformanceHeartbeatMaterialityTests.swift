import Testing
@testable import ProviderCore

@Suite("Performance heartbeat materiality")
struct PerformanceHeartbeatMaterialityTests {
    private func capacity() -> BackendCapacity {
        var slot = BackendSlotCapacity(model: "model", state: "running", numRunning: 1, numWaiting: 0,
            activeTokens: 200, maxTokensPotential: 400)
        slot.performanceMeasurements = .init(epoch: "epoch", isolatedPrefill: .init(
            tokensPerSecond: 2_000, sampleCount: 1, sampleAgeMs: 1), workloadBuckets: [])
        slot.telemetry = .init(prefillTokensTotal: 200, prefillRequestsTotal: 1,
            generatedTokensTotal: 0, generationRequestsTotal: 0)
        return BackendCapacity(slots: [slot], gpuMemoryActiveGb: 1, gpuMemoryPeakGb: 1,
            gpuMemoryCacheGb: 0, totalMemoryGb: 64)
    }

    @Test func countAndEpochChangesAreMaterialAtIdenticalRates() {
        let before = capacity()
        var counted = before
        counted.slots[0].performanceMeasurements?.isolatedPrefill?.sampleCount = 2
        #expect(CapacityHeartbeatMateriality.isMaterial(previous: before, current: counted))
        var restarted = before
        restarted.slots[0].performanceMeasurements?.epoch = "replacement"
        #expect(CapacityHeartbeatMateriality.isMaterial(previous: before, current: restarted))
        var aged = before
        aged.slots[0].performanceMeasurements?.isolatedPrefill?.sampleAgeMs = 90_000
        #expect(!CapacityHeartbeatMateriality.isMaterial(previous: before, current: aged))
        #expect(!CapacityHeartbeatMateriality.isMaterial(previous: counted, current: counted))
    }

    @Test func untrainedWorkCountersStillTriggerPublication() {
        var before = capacity()
        before.slots[0].performanceMeasurements?.isolatedPrefill = nil
        var prefilling = before
        prefilling.slots[0].telemetry?.prefillRequestsTotal = 2
        prefilling.slots[0].telemetry?.prefillTokensTotal = 300
        #expect(CapacityHeartbeatMateriality.isMaterial(previous: before, current: prefilling))
        var generated = before
        generated.slots[0].telemetry?.generationRequestsTotal = 1
        generated.slots[0].telemetry?.generatedTokensTotal = 7
        #expect(CapacityHeartbeatMateriality.isMaterial(previous: before, current: generated))
        #expect(!CapacityHeartbeatMateriality.isMaterial(previous: generated, current: generated))
    }
}
