import Foundation
import MLX
@testable import ProviderCore

/// `--emulate-physical-gib N`: the runner's process budget, MLX limits and
/// load gate behave as on a dedicated Mac with N GiB of physical memory. The
/// budget's total is N GiB and the OS-available memory it reads is N GiB
/// minus this process's footprint (other processes are assumed to fit in the
/// memory the cap leaves to the OS), never more than this machine really has
/// available; so the cap, the activation reserve, the ledger remainder and
/// the load-gate arithmetic are the smaller Mac's, and MLX's memory limit and
/// buffer-cache cap are `MLXMemoryGuard`'s for N GiB. Qualification only.
struct RunnerMemoryEmulation {
    let physicalBytes: UInt64

    init?(gib: Double?) {
        guard let gib else { return nil }
        let bytes = UInt64(gib * 1_073_741_824)
        guard bytes > 0, bytes <= ProcessInfo.processInfo.physicalMemory else { return nil }
        physicalBytes = bytes
    }

    /// The process budget the provider would build on the emulated Mac.
    func budget(capFraction: Double?) -> GlobalKVCacheBudget {
        let physical = physicalBytes
        let snapshot: @Sendable () -> GlobalKVCacheBudget.MemorySnapshot = {
            let mlx = Memory.snapshot()
            let own = RunnerProcessMemory.footprint()?.current ?? physical
            let dedicated = physical > own ? physical - own : 0
            let available = min(dedicated, SystemMemory.availableBytes() ?? .max)
            return .init(total: physical, active: UInt64(max(0, mlx.activeMemory)),
                cache: UInt64(max(0, mlx.cacheMemory)), systemAvailable: available)
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

    /// The owner's default prefix bank is sized for the emulated Mac: an
    /// explicit size when it fits there, else no bank, as `loadPlan` decides
    /// (an operator's explicit size is kept).
    func engineEnvironment(_ environment: [String: String], grantBytes: Int) -> [String: String] {
        let flag = PrefixCachePolicy.memoryEnvironmentFlag
        guard environment[flag] == "1", environment["DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES"] == nil else {
            return environment
        }
        let speculates = environment[NemotronSuperLocalMTP.enabledKey]?.trimmingCharacters(in: .whitespaces) == "1"
        let requests = (try? NemotronSuperLocalBridgeBuilder.concurrentRequests(
            environment: environment, speculates: speculates)) ?? 1
        let bank = NemotronSuperServingPolicy.defaultPrefixBankBytes(kvBytesCapacity: grantBytes,
            requests: requests, speculates: speculates, environment: environment, physicalBytes: physicalBytes)
        var result = environment
        if bank > 0 { result["DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES"] = String(bank) } else { result[flag] = nil }
        return result
    }

    /// The KV grant the provider's re-slice gives a lone Super slot on the
    /// emulated Mac (cap minus the scanned checkpoint bytes and the reserve).
    func productionGrantBytes(checkpointBytes: UInt64) -> UInt64 {
        UnifiedMemoryCap.kvBudgetBytes(physicalBytes: physicalBytes, residentWeightBytes: checkpointBytes,
            activationReserveBytes: UnifiedMemoryCap.resolvedActivationReserveBytes(
                modelIDs: [NemotronSuperServingPolicy.modelID]))
    }

    /// The managed slot's load gate on the emulated Mac, before any load:
    /// the ledger room a Super LOAD claim could take
    /// (`loadClaimRemainingBytes`) against the narrowest configuration's
    /// requirement, as the provider's pre-accept and eviction decide.
    func loadGate(budget: GlobalKVCacheBudget) -> (admits: Bool, json: RunnerJSON) {
        let headroom = budget.memoryHeadroomSnapshot()
        let reserve = NemotronSuperLoadFit.systemReserveBytes(configReserveBytes: budget.configReserveBytes)
        let room = headroom.loadClaimRemainingBytes(systemReserveBytes: reserve)
        let required = NemotronSuperLoadFit.narrowestRequirementBytes
        return (room >= required, ["physical_bytes": .bytes(physicalBytes),
                "cap_bytes": .bytes(headroom.capBytes),
                "activation_reserve_bytes": .bytes(headroom.activationReserveBytes),
                "system_reserve_bytes": .bytes(reserve),
                "required_bytes": .bytes(required), "load_claim_room_bytes": .bytes(room),
                "admits": .bool(room >= required)])
    }
}
