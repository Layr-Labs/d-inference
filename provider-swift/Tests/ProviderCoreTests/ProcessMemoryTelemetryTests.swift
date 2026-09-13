import Foundation
import Testing
@testable import ProviderCore

@Suite("Process memory telemetry")
struct ProcessMemoryTelemetryTests {
    @Test func coherentOwnershipAndPolicyDebt() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let owner = budget.makeEngineMemoryOwner()
        try owner.replaceCharge(200)
        try owner.recordMaterialization(150)
        owner.retire()
        var sampler = ProcessMemoryTelemetrySampler()
        let firstSample = sampler.capture(budget.memoryHeadroomSnapshot())
        let first = try #require(firstSample)
        #expect(first.chargedBytes == 200 && first.materializedBytes == 150)
        #expect(first.unmaterializedBytes == 50 && first.closingOwnerCount == 1)
        #expect(first.ownerCount == 1 && first.systemAvailableBytes == nil)
        await budget.setActivationReserveBytes(8 << 30, epoch: 1)
        let debtSample = sampler.capture(budget.memoryHeadroomSnapshot())
        let debt = try #require(debtSample)
        #expect(debt.generation == first.generation && debt.sampleSeq > first.sampleSeq)
        #expect(debt.commitmentDebtBytes == 50 && debt.remainingBytes == 0)
        #expect(debt.policyEpoch > first.policyEpoch)
        try owner.withdrawCoverage(150)
        try owner.replaceCharge(0)
        let emptySample = sampler.capture(budget.memoryHeadroomSnapshot())
        let empty = try #require(emptySample)
        #expect(empty.ownerCount == 0 && empty.chargedBytes == 0 && empty.materializedBytes == 0)
    }

    @Test func heartbeatAgingRetainsCaptureAndWireOmitsLocalClock() throws {
        var sample = ProcessMemoryTelemetry()
        sample.generation = 7; sample.sampleSeq = 2
        sample.capturedUptimeNanoseconds = 100_000_000
        let aged = try #require(sample.agedForHeartbeat(now: 400_000_000))
        #expect(aged.sampleAgeMs == 300 && aged.sampleSeq == 2)
        #expect(sample.sampleAgeMs == 0)
        #expect(sample.agedForHeartbeat(now: 99_000_000) == nil)
        let twice = try #require(aged.agedForHeartbeat(now: 500_000_000))
        #expect(twice.sampleAgeMs == 400)
        let encoded = try JSONEncoder().encode(CapacityTelemetry(processMemory: twice))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let wire = try #require(object["process_memory"] as? [String: Any])
        #expect(wire["capturedUptimeNanoseconds"] == nil && wire["captured_uptime_nanoseconds"] == nil)
        #expect(wire["system_available_bytes"] == nil)
        #expect(wire["sample_age_ms"] as? Int == 400)
        let state = ProviderState()
        var capacity = BackendCapacity(slots: [], gpuMemoryActiveGb: 0, gpuMemoryPeakGb: 0,
            gpuMemoryCacheGb: 0, totalMemoryGb: 0, telemetry: .init(processMemory: sample))
        let first = try #require(state.stampAndPublishHeartbeatCapacity(capacity))
        let repeated = try #require(state.stampAndPublishHeartbeatCapacity(capacity))
        #expect(repeated.capacitySeq > first.capacitySeq)
        #expect(repeated.telemetry?.processMemory?.sampleSeq == sample.sampleSeq)
        #expect(try #require(repeated.telemetry?.processMemory?.sampleAgeMs) > 300)
        capacity.telemetry?.processMemory = nil
        #expect(state.stampAndPublishHeartbeatCapacity(capacity)?.telemetry?.processMemory == nil)
    }

    @Test func canonicalWireAndLegacyOmission() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("coordinator/protocol/testdata/process_memory_wire.json")
        let data = try Data(contentsOf: file)
        let value = try JSONDecoder().decode(CapacityTelemetry.self, from: data)
        let encoded = try JSONEncoder().encode(value)
        let before = try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let after = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        #expect(before == after)
        let memory = try #require(value.processMemory)
        #expect(memory.chargedBytes - memory.materializedBytes == memory.unmaterializedBytes)
        let legacy = try JSONDecoder().decode(CapacityTelemetry.self, from: Data("{}".utf8))
        #expect(legacy.processMemory == nil)
        #expect(String(data: try JSONEncoder().encode(legacy), encoding: .utf8) == "{}")
    }
}
