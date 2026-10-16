import Foundation
import MLX
@testable import ProviderCore

/// `--emulate-physical-gib N`: the runner's process budget, MLX limits and
/// load gate behave as on a Mac with N GiB of physical memory. The budget's
/// total is N GiB and the OS-available memory it reads is this machine's
/// minus the memory N GiB lacks, so the cap, the activation reserve, the
/// ledger remainder and the load-gate arithmetic are the smaller Mac's; MLX's
/// memory limit and buffer-cache cap are `MLXMemoryGuard`'s for N GiB.
/// Qualification only: it cannot make this machine's other processes smaller.
struct RunnerMemoryEmulation {
    let physicalBytes: UInt64
    /// Memory this machine has beyond the emulated one.
    let surplusBytes: UInt64

    init?(gib: Double?) {
        guard let gib else { return nil }
        let bytes = UInt64(gib * 1_073_741_824)
        let real = ProcessInfo.processInfo.physicalMemory
        guard bytes > 0, bytes <= real else { return nil }
        physicalBytes = bytes
        surplusBytes = real - bytes
    }

    /// The process budget the provider would build on the emulated Mac.
    func budget(capFraction: Double?) -> GlobalKVCacheBudget {
        let physical = physicalBytes, surplus = surplusBytes
        let snapshot: @Sendable () -> GlobalKVCacheBudget.MemorySnapshot = {
            let mlx = Memory.snapshot()
            let available = SystemMemory.availableBytes().map { $0 > surplus ? $0 - surplus : 0 }
            return .init(total: physical, active: UInt64(max(0, mlx.activeMemory)),
                cache: UInt64(max(0, mlx.cacheMemory)), systemAvailable: available ?? .max)
        }
        return GlobalKVCacheBudget(capFraction: capFraction, memorySnapshot: snapshot,
            clearCache: {
                MLX.Stream().synchronize()
                MLX.Memory.clearCache()
            })
    }

    /// `MLXMemoryGuard`'s limits for the emulated Mac, set before any weights.
    func configureMLX() -> RunnerJSON {
        MLXMemoryGuard.configureOnce(physicalBytes: physicalBytes)
        guard let limits = MLXMemoryGuard.configuredLimitsSnapshot() else { return .null }
        return ["memory_limit_bytes": .bytes(limits.memoryLimitBytes),
                "cache_limit_bytes": .bytes(limits.cacheLimitBytes)]
    }

    /// The managed slot's load gate on the emulated Mac, before any load:
    /// the scan-time footprint plus the load headroom (activation reserve and
    /// minimum KV) against the budget's available-for-load memory.
    func loadGate(budget: GlobalKVCacheBudget) -> (admits: Bool, json: RunnerJSON) {
        // The footprint's GiB do not depend on the checkpoint size argument.
        let footprint = NemotronSuperServingPolicy.discoveryFootprint(sizeBytes: 0)
        let headroom = UnifiedMemoryCap.loadHeadroomBytes(modelIDs: [NemotronSuperServingPolicy.modelID])
        let required = footprint.estimatedMemoryGb + Double(headroom) / 1_073_741_824
        let available = budget.availableForLoadGb()
        return (available >= required, ["physical_bytes": .bytes(physicalBytes),
                "cap_bytes": .bytes(UnifiedMemoryCap.hardCapBytes(physicalBytes: physicalBytes)),
                "activation_reserve_bytes": .bytes(UnifiedMemoryCap.resolvedActivationReserveBytes(
                    modelIDs: [NemotronSuperServingPolicy.modelID])),
                "footprint_gib": .double(footprint.estimatedMemoryGb),
                "load_headroom_bytes": .bytes(headroom), "required_gib": .double(required),
                "available_for_load_gib": .double(available), "admits": .bool(available >= required)])
    }
}
