import Foundation
import MLX

/// Hard ceiling on MLX's unified-memory footprint.
///
/// THE PROBLEM: on Apple Silicon, MLX allocates GPU buffers from the same
/// unified-memory pool as the OS. MLX's `memoryLimit` defaults to **1.5× the
/// device's recommended max working-set size** — which is *above* physical RAM —
/// so by default MLX will happily try to allocate past total RAM. When it does,
/// macOS jetsam sends the process an uncatchable SIGKILL: an invisible OOM
/// crash (no panic, no telemetry — the kill leaves no trace the process can
/// flush). This is the dominant office-Mac failure mode.
///
/// THE GUARD: pin `Memory.memoryLimit` to `physical − reserve` once at startup.
/// Past that limit MLX's allocator applies backpressure (malloc waits on
/// scheduled GPU tasks to free memory) instead of racing the machine into a
/// kernel kill. This is a *coarse backstop*; the precise, live, shared-machine
/// protection is the per-request admission gate (`GlobalKVCacheBudget` /
/// `tokenBudgetMax`, which clamp to `SystemMemory.availableBytes()`). The two
/// are complementary: admission keeps us from *trying* to over-allocate; the
/// ceiling bounds the blast radius if an estimate is ever wrong.
public enum MLXMemoryGuard {
    /// Default headroom (GB) left below physical RAM for macOS + non-MLX
    /// process memory. Deliberately larger than the per-request load reserve
    /// (4 GB) because this is the *whole-machine* ceiling: it must leave room
    /// for the OS, the window server, and whatever else shares the box.
    public static let defaultReserveGB: UInt64 = 6

    /// Floor so a tiny/misreported machine never gets a pathological (or zero)
    /// limit that would wedge every allocation.
    static let minimumLimitBytes = 2 * 1024 * 1024 * 1024  // 2 GiB

    public struct Limits: Equatable, Sendable {
        public let memoryLimitBytes: Int
        public let cacheLimitBytes: Int
    }

    /// Pure, testable sizing policy.
    /// - memoryLimit = max(floor, physical − reserve)
    /// - cacheLimit  = memoryLimit × cacheFraction (bounds the reusable buffer
    ///   pool below the ceiling so freed buffers return to the OS rather than
    ///   lingering as the classic "MLX memory wedge"). cacheFraction defaults to
    ///   0.75 — generous enough to preserve reuse/perf, bounded enough to help.
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

    /// Resolve the reserve in BYTES from an explicit byte value, the
    /// `DARKBLOOM_MLX_MEMORY_RESERVE_GB` env override (in GB), or the default.
    /// `explicit` is bytes — consistent with `reserveBytes` everywhere else
    /// (GlobalKVCacheBudget, ProviderLoop.memoryReserveBytes).
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

    // Idempotency: the ceiling only needs to be set once per process. loadModel
    // can run many times (reloads, multi-model), so guard with a lock + flag.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured = false

    /// Set the MLX memory + cache ceiling once for this process. Idempotent and
    /// safe to call from every model load. `apply` is injectable for tests so
    /// they exercise the sizing/once-logic without touching real MLX globals.
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
