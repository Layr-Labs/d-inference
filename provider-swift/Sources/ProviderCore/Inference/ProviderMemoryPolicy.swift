import Foundation

/// Process-wide home for the operator's effective memory reserve
/// (`max(memory_reserve_gb, physical − memory_limit_gb)`, see ``MemoryLimit``).
///
/// WHY A PROCESS-WIDE VALUE AND NOT A PARAMETER: almost every consumer of the
/// reserve receives it explicitly (`configReserveBytes:` threads from
/// `ProviderLoop`/`StandaloneServer` into `UnifiedMemoryCap`), and that stays
/// the preferred shape. ``KVHeadroomProbe`` is the exception: it is a static
/// probe invoked from inside engine/backend construction
/// (`EngineV2Factory.prepareProductionBackend`) that has no config in scope and
/// would need the reserve threaded through five call layers to reach it. Since
/// the reserve is derived once from a config file read at process start and the
/// limit requires a restart to change, a set-once process value is the honest
/// model — the same one ``MLXMemoryGuard`` already uses for the MLX ceiling.
///
/// Default is `0` (no operator reserve), so an unconfigured process — tests,
/// benchmarks, `darkbloom-publish` — behaves exactly as before.
public enum ProviderMemoryPolicy {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reserveBytes: UInt64 = 0

    /// The effective reserve every un-parameterized memory probe must hold
    /// back. Reads are lock-guarded; the value is written once at startup.
    public static var effectiveReserveBytes: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return reserveBytes
    }

    /// Publish the effective reserve for this process. Called from
    /// `ProviderLoop.init` and `StandaloneServer.init` immediately after the
    /// same value is computed for `GlobalKVCacheBudget`, so the probe and the
    /// runtime KV gate can never disagree about how much memory is held back.
    ///
    /// Idempotent by overwrite rather than by latch: a serve mode that
    /// constructs a loop twice in one process (tests, `--local` after a
    /// reconfigure) must end up with the CURRENT config's reserve, not the
    /// first one ever seen.
    public static func configure(effectiveReserveBytes bytes: UInt64) {
        lock.lock()
        reserveBytes = bytes
        lock.unlock()
    }

    /// Test-only: restore the unconfigured default so a test that configures a
    /// reserve cannot leak it into an unrelated suite.
    static func _resetForTest() {
        configure(effectiveReserveBytes: 0)
    }
}
