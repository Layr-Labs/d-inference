import Foundation

/// Owned by the provider loop. Only an actual coherent capacity refresh advances
/// the sample sequence; heartbeat sends age a scalar copy of the same sample.
struct ProcessMemoryTelemetrySampler {
    private let generation = UInt64.random(in: 1..<(1 << 52))
    private var sequence: UInt64 = 0

    mutating func capture(_ sample: GlobalKVCacheBudget.HeadroomSnapshot) -> ProcessMemoryTelemetry? {
        guard sequence < (1 << 53) - 1 else { return nil }
        sequence += 1
        var value = ProcessMemoryTelemetry()
        value.generation = generation
        value.sampleSeq = sequence
        value.policyEpoch = sample.policyEpoch
        value.capBytes = sample.capBytes
        value.activationReserveBytes = sample.activationReserveBytes
        value.activeBytes = sample.activeBytes
        value.cacheBytes = sample.cacheBytes
        value.chargedBytes = sample.totalOwnedBytes
        value.materializedBytes = sample.materializedBytes
        value.unmaterializedBytes = sample.unmaterializedCommittedBytes
        value.remainingBytes = sample.runtimeRemainingBytes
        value.commitmentDebtBytes = sample.commitmentDebtBytes
        value.ownerCount = UInt64(sample.ownerCount)
        value.closingOwnerCount = UInt64(sample.closingOwnerCount)
        value.systemAvailableBytes = sample.systemAvailableBytes == .max ? nil : sample.systemAvailableBytes
        value.capturedUptimeNanoseconds = sample.capturedUptimeNanoseconds
        return value
    }
}
