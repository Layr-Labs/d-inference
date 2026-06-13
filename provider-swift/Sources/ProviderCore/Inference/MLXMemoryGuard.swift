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

    /// Floor so a tiny/misreported machine never gets a pathological limit.
    static let minimumLimitBytes = 2 * 1024 * 1024 * 1024  // 2 GiB

    public struct Limits: Equatable, Sendable {
        public let memoryLimitBytes: Int
        public let cacheLimitBytes: Int
    }

    /// Pure sizing policy. memoryLimit = max(floor, physical − reserve);
    /// cacheLimit = memoryLimit × cacheFraction (bounds the reusable pool so
    /// freed buffers return to the OS; 0.75 keeps reuse/perf while helping).
    static func recommendedLimits(
        physicalBytes: UInt64,
        reserveBytes: UInt64,
        cacheFraction: Double = 0.75
    ) -> Limits {
        let physical = Int(min(physicalBytes, UInt64(Int.max)))
        let reserve = Int(min(reserveBytes, UInt64(Int.max)))
        let limit = max(minimumLimitBytes, physical > reserve ? physical - reserve : minimumLimitBytes)
        let fraction = cacheFraction.isFinite ? min(1.0, max(0.0, cacheFraction)) : 0.75
        let cache = max(minimumLimitBytes / 2, Int(Double(limit) * fraction))
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
            return UInt64(min(gb * 1_073_741_824, Double(UInt64.max)))
        }
        return saturatingGiBToBytes(defaultReserveGB)
    }

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
            reserveBytes: resolvedReserveBytes(explicit: reserveBytes))
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
