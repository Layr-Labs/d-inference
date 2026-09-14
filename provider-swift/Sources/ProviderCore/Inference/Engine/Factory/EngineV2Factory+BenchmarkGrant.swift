import Foundation

/// Single loaded production slot's logical grant, independent of a live
/// allocator/OS headroom sample. Encoded into the benchmark evidence.
@_spi(Benchmarking)
public struct EngineV2BenchmarkProductionGrant: Codable, Sendable, Equatable {
    public let physicalBytes: UInt64
    public let capFraction: Double
    public let hardCapBytes: UInt64
    public let effectiveCapBytes: UInt64
    public let operatorReserveBytes: UInt64
    public let activationReserveBytes: UInt64
    public let targetWeightBytes: Int
    public let assistantWeightBytes: Int
    public let residentWeightBytes: Int
    public let ramPrefixAllowanceBytes: UInt64
    public let slotCount: Int
    public let fleetBudgetBytes: UInt64
    public let grantBytes: Int
}

extension EngineV2Factory {
    /// Offline single-slot mode deliberately uses the standard provider settings.
    /// Co-resident callers must use explicit grants and a shared injected budget;
    /// their complete resident/draining serving set belongs to ProviderLoop.
    static func benchmarkProductionGrant(
        modelId: String, sizing: SlotSizingSnapshot,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        environment: [String: String]
    ) throws -> EngineV2BenchmarkProductionGrant {
        let operatorReserve = ProviderSettings(name: "benchmark").memoryReserveGB * (1 << 30)
        let fraction = UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: environment)
        let activation = UnifiedMemoryCap.resolvedActivationReserveBytes(env: environment, modelIDs: [modelId])
        let hardCap = UnifiedMemoryCap.hardCapBytes(physicalBytes: physicalBytes, capFraction: fraction)
        let effectiveCap = min(hardCap, physicalBytes > operatorReserve ? physicalBytes - operatorReserve : 0)
        let fleetBudget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physicalBytes, residentWeightBytes: UInt64(sizing.weightsBytes),
            activationReserveBytes: activation, ramPrefixAllowanceBytes: 0,
            configReserveBytes: operatorReserve, capFraction: fraction)
        let grants = EngineV2KVSizing.resliceGrants(existing: [], newcomer: .init(
            modelId: modelId, fp16KVBytesPerToken: sizing.fp16KVBytesPerToken,
            maxContextLength: sizing.maxContextLength), fleetKVBudgetBytes: fleetBudget)
        guard EngineV2KVSizing.resliceMeetsServiceabilityFloor(grants), let grant = grants[modelId] else {
            throw EngineV2BenchmarkSession.Failure.invalidCapacity
        }
        return .init(physicalBytes: physicalBytes, capFraction: fraction, hardCapBytes: hardCap,
            effectiveCapBytes: effectiveCap, operatorReserveBytes: operatorReserve,
            activationReserveBytes: activation, targetWeightBytes: sizing.targetWeightsBytes,
            assistantWeightBytes: sizing.auxiliaryWeightBytes, residentWeightBytes: sizing.weightsBytes,
            ramPrefixAllowanceBytes: 0, slotCount: 1, fleetBudgetBytes: fleetBudget, grantBytes: grant)
    }
}
