import Foundation
import MLX

/// Diagnostic policy for this dedicated rank worker, not a provider default.
/// It changes recycling of freed buffers, never active-allocation admission.
struct QwenResidentBenchmarkAllocatorPolicy: Encodable {
    static let cacheLimitBytes = 0
    let schema = "qwen_resident_rank_allocator_cache_disabled_v1"
    let requestedCacheLimitBytes = Self.cacheLimitBytes
    let beforeReadyCacheClear: Memory.Snapshot
    let afterReadyCacheClear: Memory.Snapshot
    let activeAllocationLimitChanged = false
    let cacheLimitGetterUsedAsBackendProof = false

    static func prepareReady(check: () throws -> Void) throws -> Self {
        try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            Stream.gpu.synchronize(); Stream.cpu.synchronize()
            try checked()
            let before = Memory.snapshot()
            Memory.clearCache()
            try checked()
            let after = Memory.snapshot()
            guard after.cacheMemory == 0, after.activeMemory == before.activeMemory,
                  after.peakMemory >= after.activeMemory else {
                throw ProbeError("Resident rank cache clearing changed active storage or retained cached buffers")
            }
            return .init(beforeReadyCacheClear: before, afterReadyCacheClear: after)
        }
    }
}
