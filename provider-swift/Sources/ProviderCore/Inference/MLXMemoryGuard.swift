import Foundation
import MLX

/// Hard ceiling on MLX's unified-memory footprint.
///
/// MLX's `memoryLimit` defaults to 1.5× the device working set — above physical
/// RAM — so by default MLX can allocate past total RAM and hit an uncatchable
/// jetsam SIGKILL (an invisible OOM). Pinning it to `physical − reserve` makes
/// the allocator throttle (malloc waits on scheduled tasks) instead. Coarse
/// backstop; the live per-request gate (GlobalKVCacheBudget / tokenBudgetMax,
/// clamped to SystemMemory.availableBytes) is the precise one.
public enum MLXMemoryGuard {
    /// Headroom (GB) left below physical RAM for macOS + non-MLX memory. Larger
    /// than the per-request load reserve (4 GB): this is the whole-machine ceiling.
    public static let defaultReserveGB: UInt64 = 6

    /// Absolute ceiling (GiB) on MLX's reusable buffer pool. The pool's useful
    /// reuse set is bounded by the WORKLOAD — per-step activation churn (~5.5
    /// GiB measured peak at B=8) plus KV-growth churn — not by machine size.
    /// The previous policy (cache = 0.75 × memoryLimit alone) let a 512 GB Mac
    /// Studio park ~380 GB of freed buffers: every completed request's KV and
    /// activation buffers accumulated below that limit and were never returned
    /// to the OS (observed in the field as 377 GB of Metal allocation for a
    /// ~21 GB model). 8 GiB keeps steady-state buffer reuse while bounding the
    /// hoard on every machine size; `DARKBLOOM_MLX_CACHE_LIMIT_GB` overrides in
    /// either direction (floored at 1 GiB, bounded above by cacheFraction ×
    /// memoryLimit — a raise can restore the old pool size, not exceed it).
    public static let defaultCacheLimitGB: UInt64 = 8

    /// Floor so a tiny/misreported machine never gets a pathological limit.
    static let minimumLimitBytes = 2 * 1024 * 1024 * 1024  // 2 GiB

    public struct Limits: Equatable, Sendable {
        public let memoryLimitBytes: Int
        public let cacheLimitBytes: Int
    }

    /// Pure sizing policy. memoryLimit = max(floor, physical − reserve);
    /// cacheLimit = min(memoryLimit × cacheFraction, cacheCapBytes), floored at
    /// 1 GiB so buffer reuse survives a pathological override. The fraction
    /// scales the pool down on small machines; the absolute cap bounds it on
    /// big ones (see `defaultCacheLimitGB`).
    static func recommendedLimits(
        physicalBytes: UInt64,
        reserveBytes: UInt64,
        cacheFraction: Double = 0.75,
        cacheCapBytes: UInt64 = MLXMemoryGuard.defaultCacheLimitGB * 1_073_741_824
    ) -> Limits {
        let physical = Int(min(physicalBytes, UInt64(Int.max)))
        let reserve = Int(min(reserveBytes, UInt64(Int.max)))
        let limit = max(minimumLimitBytes, physical > reserve ? physical - reserve : minimumLimitBytes)
        let fraction = cacheFraction.isFinite ? min(1.0, max(0.0, cacheFraction)) : 0.75
        let cap = Int(min(cacheCapBytes, UInt64(Int.max)))
        let cache = max(minimumLimitBytes / 2, min(Int(Double(limit) * fraction), cap))
        return Limits(memoryLimitBytes: limit, cacheLimitBytes: min(cache, limit))
    }

    /// Reserve in BYTES from explicit (bytes), env DARKBLOOM_MLX_MEMORY_RESERVE_GB
    /// (GB), or default. `explicit` is bytes, like reserveBytes everywhere else.
    static func resolvedReserveBytes(
        explicit: UInt64?,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> UInt64 {
        if let explicit { return explicit }
        if let raw = env["DARKBLOOM_MLX_MEMORY_RESERVE_GB"], let gb = Double(raw), gb >= 0, gb.isFinite {
            // Saturate WITHOUT `UInt64(Double(UInt64.max))`: that round-trip rounds
            // UInt64.max up to 2^64, which is outside UInt64, so `UInt64(...)` traps
            // — a huge finite reserve override would crash the provider during
            // configureOnce() at startup/model load. `uint64MaxAsDouble` is exactly
            // 2^64; anything ≥ it saturates. Mirrors the VLM env clamps.
            let scaled = gb * 1_073_741_824
            return scaled >= uint64MaxAsDouble ? UInt64.max : UInt64(scaled)
        }
        return saturatingGiBToBytes(defaultReserveGB)
    }

    /// Cache cap in BYTES from explicit (bytes), env DARKBLOOM_MLX_CACHE_LIMIT_GB
    /// (GB), or default. Same saturation care as `resolvedReserveBytes` — a huge
    /// finite override must clamp, never trap. Zero is accepted and lands on the
    /// 1 GiB floor in `recommendedLimits`.
    static func resolvedCacheCapBytes(
        explicit: UInt64?,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> UInt64 {
        if let explicit { return explicit }
        if let raw = env["DARKBLOOM_MLX_CACHE_LIMIT_GB"], let gb = Double(raw), gb >= 0, gb.isFinite {
            let scaled = gb * 1_073_741_824
            return scaled >= uint64MaxAsDouble ? UInt64.max : UInt64(scaled)
        }
        return saturatingGiBToBytes(defaultCacheLimitGB)
    }

    /// `Double(UInt64.max)` rounded to the nearest representable Double — exactly
    /// 2^64 (one more than `UInt64.max`). Used as the saturation threshold so a
    /// `>= uint64MaxAsDouble` comparison catches every value that would trap on
    /// `UInt64(_:)` conversion.
    static let uint64MaxAsDouble = Double(UInt64.max)

    private static func saturatingGiBToBytes(_ gib: UInt64) -> UInt64 {
        let (bytes, overflow) = gib.multipliedReportingOverflow(by: 1_073_741_824)
        return overflow ? UInt64.max : bytes
    }

    // Set once per process; loadModel runs many times, so guard with lock + flag.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured = false

    /// Set the MLX ceiling once per process (idempotent). `apply` is injectable
    /// for tests so they avoid touching real MLX globals.
    @discardableResult
    public static func configureOnce(
        reserveBytes: UInt64? = nil,
        cacheCapBytes: UInt64? = nil,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        apply: (Limits) -> Void = { limits in
            Memory.memoryLimit = limits.memoryLimitBytes
            Memory.cacheLimit = limits.cacheLimitBytes
        },
        log: ((Limits) -> Void)? = nil
    ) -> Limits? {
        lock.lock()
        if configured {
            lock.unlock()
            return nil
        }
        configured = true
        lock.unlock()

        let limits = recommendedLimits(
            physicalBytes: physicalBytes,
            reserveBytes: resolvedReserveBytes(explicit: reserveBytes),
            cacheCapBytes: resolvedCacheCapBytes(explicit: cacheCapBytes))
        apply(limits)
        log?(limits)
        return limits
    }

    /// Test-only: reset the once-flag so a test can drive `configureOnce` again.
    static func _resetForTest() {
        lock.lock()
        configured = false
        lock.unlock()
    }
}
