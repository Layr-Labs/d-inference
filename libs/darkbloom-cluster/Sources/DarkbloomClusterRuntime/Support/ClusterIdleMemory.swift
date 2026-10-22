import Darwin
import Foundation
import MLX

/// What a loaded worker gives back once it is idle (owner's report
/// 2026-10-21: memory stayed at the request's level after generation ended).
///
/// The model stays resident and wired: dropping it would make the next
/// request reload it from disk (about 93 GB a rank for GLM under tensor
/// parallel). MLX's freed-buffer cache does not need to stay: it holds the
/// buffers a finished request's intermediates used (up to the cache limit,
/// 4 GiB on a GLM tensor-parallel rank) only so the next request's identical
/// shapes skip the driver. Cleared, they leave the process's footprint and
/// the wired residency set at once, and the next request allocates them
/// again (`releaseDelayNanoseconds`).
///
/// Exactness: clearing changes where the next request's intermediates live,
/// never what is computed. A buffer reaches the cache only after its last
/// array is gone, and a cached buffer already comes back with whatever an
/// earlier request left in it, so no kernel may read an output it has not
/// written; a fresh buffer is just another such start.
public enum ClusterIdleMemory {
    /// How long a worker stays idle after a request retires before it clears
    /// the cache. Recreating it is the next request's cost, measured on an M5
    /// Ultra with MLX's own allocation sequence (a shared buffer joining the
    /// committed residency set, then its first GPU write): about 18 ms per
    /// GiB of large buffers plus 7 us per small one, so 75-100 ms for a full
    /// 4 GiB cache of prefill and decode shapes, paid once. Back-to-back
    /// requests (an agent's tool loop, a title request beside a turn) keep it;
    /// a pair that has had nothing to do for half a minute gives it back.
    public static let releaseDelayNanoseconds: UInt64 = 30_000_000_000

    /// Clears MLX's freed-buffer cache; returns the bytes it held. On the
    /// native executor, between requests.
    @discardableResult
    public static func releaseFreedBuffers() -> Int {
        let held = Memory.cacheMemory
        Memory.clearCache()
        return held
    }

    /// The host reports memory pressure now (`kern.memorystatus_vm_pressure_level`
    /// above normal). An unreadable level counts as none.
    public static func hostUnderPressure() -> Bool {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else { return false }
        return Int(level) > QwenDenseStageLoadPolicy.normalPressureLevel
    }
}
