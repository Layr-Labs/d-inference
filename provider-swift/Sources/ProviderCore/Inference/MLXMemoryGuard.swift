import Foundation
import MLX

/// Ceiling on MLX's unified-memory footprint — an EVAL-SCHEDULING threshold,
/// not an allocation limit.
///
/// What `Memory.memoryLimit` actually does in the vendored MLX
/// (`libs/mlx-swift/Source/Cmlx/mlx/mlx`):
///
///   * `transforms.cpp` `eval_impl`: while `active_memory > memory_limit &&
///     n_active_tasks > 0`, commit every open stream and wait for one task
///     after EVERY primitive. Above the limit a ~1,760-dispatch decode step
///     becomes ~1,760 GPU round-trips — a silent, large slowdown that looks
///     like a wedged slot (`MLXMemoryLimitRegime` detects and logs it).
///   * `allocator.cpp` `set_memory_limit`: moves `block_limit_` and
///     recomputes `gc_limit_ = min(block_limit_, 0.95 × recommended working
///     set)` — the threshold above which freed buffers are returned instead
///     of cached. `malloc` never blocks or throws on BYTES; only the resource
///     COUNT (`num_resources_ ≥ resource_limit_`) throws.
///
/// So the limit cannot enforce the provider's cap (that is the admission
/// layer: `UnifiedMemoryCap` + `GlobalKVCacheBudget`), and it MUST NOT sit
/// below what the admission layer sanctions: sanctioned usage crossing it is
/// the serialization cliff above. MLX's default (1.5× the device working
/// set — above physical RAM) is still pinned down so a runaway allocation
/// at least releases its cache before jetsam; the pin is `physical −
/// reserve`, where the reserve resolves explicit > env
/// (`DARKBLOOM_MLX_MEMORY_RESERVE_GB`) > cap-derived > the 6 GiB legacy
/// default. Production passes the cap-derived reserve, so the limit equals
/// the provider's effective cap (`UnifiedMemoryCap.effectiveCapBytes`) —
/// looser than the legacy 6 GiB on every box below 60 GB (32 GB: 28 GiB vs
/// 26; 24 GB: 20 vs 18; 40 GB: 36 vs 34), where the old limit sat inside
/// sanctioned usage; slightly tighter at ≥ 64 GB (0.9 × physical), where the
/// provider gate already bounds active below it.
public enum MLXMemoryGuard {
    /// Legacy headroom (GB) left below physical RAM when no cap-derived
    /// reserve is supplied (tests, tools that never resolve a cap). Larger
    /// than the per-request load reserve (4 GB): this was sized as a
    /// whole-machine ceiling before the limit was aligned with the cap.
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

    /// The reserve that makes `physical − reserve` equal the provider's
    /// effective cap — `UnifiedMemoryCap.effectiveCapBytes(physical,
    /// configReserve)` = min(0.9 × physical, physical − memory_reserve_gb),
    /// the SAME figure the shared KV gate, the static budget and the load
    /// gate enforce. Passing it as `capDerivedReserveBytes` aligns the MLX
    /// eval threshold with the admission layer (T3-04).
    public static func capDerivedReserveBytes(
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        configReserveBytes: UInt64
    ) -> UInt64 {
        let cap = UnifiedMemoryCap.effectiveCapBytes(
            physicalBytes: physicalBytes, configReserveBytes: configReserveBytes)
        return physicalBytes > cap ? physicalBytes - cap : 0
    }

    /// Reserve in BYTES: explicit (bytes) > env DARKBLOOM_MLX_MEMORY_RESERVE_GB
    /// (GB) > cap-derived (bytes, from `capDerivedReserveBytes`) > the legacy
    /// default. `explicit` is bytes, like reserveBytes everywhere else. The
    /// env override stays above the cap-derived figure so an operator can
    /// still pin the limit by hand (the measurement lever for
    /// `MLXMemoryLimitRegime`).
    static func resolvedReserveBytes(
        explicit: UInt64?,
        capDerived: UInt64? = nil,
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
        if let capDerived { return capDerived }
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
    nonisolated(unsafe) private static var configuredLimits: Limits?

    /// The limits actually selected by `configureOnce`, without touching MLX
    /// globals. Capacity telemetry uses this snapshot because reading
    /// `Memory.cacheLimit` can initialize the Metal backend in no-GPU tests.
    static func configuredLimitsSnapshot() -> Limits? {
        lock.lock()
        defer { lock.unlock() }
        return configuredLimits
    }

    /// Set the MLX ceiling once per process (idempotent). `apply` is injectable
    /// for tests so they avoid touching real MLX globals.
    ///
    /// `capDerivedReserveBytes`: the reserve that aligns the limit with the
    /// provider's effective cap (`capDerivedReserveBytes(physicalBytes:
    /// configReserveBytes:)`). EVERY production call site passes it — the
    /// guard is once-per-process and whichever site runs first wins, so a
    /// site that omitted it would leave the legacy 6 GiB pin in place on
    /// the ordering where it runs first.
    @discardableResult
    public static func configureOnce(
        reserveBytes: UInt64? = nil,
        cacheCapBytes: UInt64? = nil,
        capDerivedReserveBytes: UInt64? = nil,
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
            reserveBytes: resolvedReserveBytes(
                explicit: reserveBytes, capDerived: capDerivedReserveBytes),
            cacheCapBytes: resolvedCacheCapBytes(explicit: cacheCapBytes))
        lock.lock()
        configuredLimits = limits
        lock.unlock()
        apply(limits)
        log?(limits)
        return limits
    }

    /// Test-only: reset the once-flag so a test can drive `configureOnce` again.
    static func _resetForTest() {
        lock.lock()
        configured = false
        configuredLimits = nil
        lock.unlock()
    }
}
