@testable import ProviderCore

/// Memory inputs for scripted engines that allocate no model weights. Keep
/// reslicing, request admission and recovery on the same simulated machine;
/// native allocator tests deliberately use their own real memory observations.
enum ScriptedProviderMemory {
    static let physicalBytes: UInt64 = 64 << 30

    static func budget(
        physicalBytes: UInt64 = ScriptedProviderMemory.physicalBytes,
        modelIDs: [String] = [], configReserveBytes: UInt64 = 0
    ) -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(
            activationReserveBytes: UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: modelIDs),
            configReserveBytes: configReserveBytes,
            memorySnapshot: {
                .init(total: physicalBytes, active: 0, cache: 0, systemAvailable: physicalBytes)
            })
    }

    static func headroom(modelIDs: [String] = []) -> UInt64 {
        UnifiedMemoryCap.liveKVHeadroomBytes(
            physicalBytes: physicalBytes, mlxUsedBytes: 0, systemAvailableBytes: physicalBytes,
            activationReserveBytes: UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: modelIDs))
    }
}
