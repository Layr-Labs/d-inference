import Cmlx
import Foundation
import MLX

/// What `ProcessForcedExit` releases in a process that holds MLX memory.
///
/// MLX's wired limit goes to zero first, which empties the residency set the
/// Metal allocator keeps for this process, and the buffer cache is returned
/// after it. Both go straight to mlx-c and so take only the allocator's own
/// lock: mlx-swift's `Memory.clearCache()` takes the process-wide evaluation
/// lock, which an executor blocked in a collective holds, and would wait for
/// the dead-man instead of releasing anything.
public enum ProcessNativeMemoryRelease {
    /// Installs the release for every forced exit of this process. Call once,
    /// before anything native is touched; a process that exits before then
    /// leaves without initializing Metal just to release nothing.
    public static func installForForcedExit(deadManNanoseconds: UInt64 = ProcessForcedExit.defaultDeadManNanoseconds) {
        ProcessForcedExit.install(release: release, deadManNanoseconds: deadManNanoseconds)
    }

    /// Wired limit to zero, then the cache. Returns what it found, for the log.
    public static func release() -> String {
        var cached: size_t = 0
        let cacheRead = mlx_get_cache_memory(&cached) == 0
        var previous: size_t = 0
        let unwired = mlx_set_wired_limit(&previous, 0) == 0
        let cleared = mlx_clear_cache() == 0
        return "wired_limit_before=\(unwired ? String(previous) : "refused") wired_limit=\(unwired ? "0" : "unknown")"
            + " cache_before=\(cacheRead ? String(cached) : "unknown") cache_cleared=\(cleared)"
    }
}

/// A standing MLX wired limit for a loaded stage, as `MiMoStageResidency` on
/// work/mimo and the product's `MiMoV26WiredResidency` keep for MiMo.
///
/// Qualification only for the dense Qwen stages: S00 measures whether they
/// should hold one between requests (see handoff/S00-NO-ORPHANED-MEMORY.md).
/// It sets MLX's own per-process limit (`mlx_set_wired_limit`), never a system
/// setting; the ceiling is the product's: never above the recommended working
/// set, and always leaving the larger of 16 GiB and a tenth of physical memory
/// unwired. Every exit of the process resets it to zero through
/// `ProcessForcedExit`; `end()` restores the previous value earlier.
public final class ProcessStageResidency {
    public static let policy = "stage_wired_residency_v1"

    public struct Receipt: Encodable, Equatable, Sendable {
        public let policy: String
        public let requestedBytes: Int
        public let ceilingBytes: Int
        public let appliedBytes: Int
        public let previousBytes: Int
        public let recommendedWorkingSetBytes: Int
        public let physicalMemoryBytes: Int
    }

    public let receipt: Receipt
    private var held = true

    /// The product's bound on this Mac's own figures; nil when nothing may be wired.
    public static func ceiling(physicalBytes: Int, recommendedBytes: Int) -> Int? {
        guard physicalBytes > 0, recommendedBytes > 0 else { return nil }
        let tenth = physicalBytes / 10 + (physicalBytes % 10 == 0 ? 0 : 1)
        let reserve = max(16 << 30, tenth)
        guard physicalBytes > reserve else { return nil }
        return min(physicalBytes - reserve, recommendedBytes)
    }

    /// Bytes MLX reports active now: after a load, the stage's tensors.
    public static var activeBytes: Int {
        var value: size_t = 0
        return mlx_get_active_memory(&value) == 0 ? Int(clamping: value) : 0
    }

    /// Call on the native executor with no evaluation in flight. `bytes` is
    /// what should stay resident: the stage's tensors and its request state.
    public init(bytes: Int) throws {
        let physical = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        guard bytes > 0, Device.defaultDevice().deviceType == .gpu,
              let recommended = GPU.maxRecommendedWorkingSetBytes(),
              let ceiling = Self.ceiling(physicalBytes: physical, recommendedBytes: recommended) else {
            throw ProbeError("Stage residency requires a GPU device and its recommended working set")
        }
        let applied = min(bytes, ceiling)
        var previous: size_t = 0
        guard mlx_set_wired_limit(&previous, size_t(applied)) == 0 else {
            throw ProbeError("MLX refused the stage wired limit of \(applied) bytes")
        }
        receipt = .init(policy: Self.policy, requestedBytes: bytes, ceilingBytes: ceiling, appliedBytes: applied,
            previousBytes: Int(clamping: previous), recommendedWorkingSetBytes: recommended, physicalMemoryBytes: physical)
    }

    /// Restores the limit that was in force before, on the native executor.
    public func end() {
        guard held else { return }
        held = false
        var replaced: size_t = 0
        _ = mlx_set_wired_limit(&replaced, size_t(receipt.previousBytes))
    }

    deinit { end() }
}
