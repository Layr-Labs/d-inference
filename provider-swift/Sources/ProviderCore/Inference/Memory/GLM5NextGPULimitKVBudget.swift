import Foundation

/// The KV budget of a residency set that includes GLM-5.3-Flash, held to the
/// GPU's wired-memory limit.
///
/// `UnifiedMemoryCap` sizes KV from physical memory, so at full KV a 256 GB
/// Mac plans its whole cap, 230.4 GiB, as GPU memory. GLM keeps its weights
/// wired (`GLM5NextWiredResidency`), and a command buffer past the GPU limit
/// fails with "Insufficient Memory", which ends the process. The limit is
/// `iogpu.wired_limit_mb`, or Metal's recommended working set while that is 0:
/// 222.72 GiB of a 256 GB Mac (`ClusterGPUMemoryLimit`), which is what a Mac
/// runs after a reboot without the boot job (`GLM5NextWiredLimit`).
///
/// Such a set therefore plans its KV within the limit, less the resident
/// weights, the activation reserve and MLX's buffer cache. Where the limit
/// leaves more than the cap does, as the production hosts' raised limit
/// (240 GiB) does, the cap's budget stands.
enum GLM5NextGPULimitKVBudget {
    struct GPULimit: Sendable, Equatable {
        /// The GPU's wired-memory limit; 0 when it could not be read.
        let limitBytes: UInt64
        /// MLX's buffer cache limit: freed buffers MLX keeps allocated.
        let cacheLimitBytes: UInt64

        /// No limit read: a machine whose physical memory a test pins.
        static let unread = GPULimit(limitBytes: 0, cacheLimitBytes: 0)

        /// The cache limit `MLXMemoryGuard` set, else its default.
        static func live() -> GPULimit {
            let cache = MLXMemoryGuard.configuredLimitsSnapshot().map { UInt64(max(0, $0.cacheLimitBytes)) }
            return GPULimit(
                limitBytes: GLM5NextWiredLimit.Limits.live().gpuLimitBytes,
                cacheLimitBytes: cache ?? MLXMemoryGuard.defaultCacheLimitGB << 30)
        }
    }

    /// `budget` (the cap's KV budget for the same set), held to `limit` when
    /// any of `modelTypes` is GLM-5.3-Flash or `retainedGLMBytes` is charged.
    static func budgetBytes(
        _ budget: UInt64,
        modelTypes: [String?],
        retainedGLMBytes: UInt64,
        residentWeightBytes: UInt64,
        activationReserveBytes: UInt64,
        limit: @autoclosure () -> GPULimit
    ) -> UInt64 {
        guard retainedGLMBytes > 0 || modelTypes.contains(where: GLM5NextPromptPolicy.applies(modelType:))
        else { return budget }
        let gpu = limit()
        guard gpu.limitBytes > 0 else { return budget }
        var held: UInt64 = 0
        for bytes in [residentWeightBytes, activationReserveBytes, gpu.cacheLimitBytes] {
            let (sum, overflow) = held.addingReportingOverflow(bytes)
            held = overflow ? .max : sum
        }
        return min(budget, gpu.limitBytes > held ? gpu.limitBytes - held : 0)
    }
}
