import Foundation

/// Normalization for the operator's absolute memory limit (`memory_limit_gb`).
///
/// A user with a 256 GB machine who wants to hand Darkbloom at most 150 GB
/// sets `memory_limit_gb = 150`. Internally the limit is expressed as an
/// operator RESERVE — `physical − limit` — so it rides the existing
/// `configReserveBytes` plumbing (`UnifiedMemoryCap.loadReserveBytes`,
/// `GlobalKVCacheBudget`, EngineV2 KV sizing, heartbeat `free_for_load_gb`)
/// with no change to the cap policy itself. The resulting invariant:
///
///     effectiveCap = min(0.90 × physical, physical − memory_reserve_gb, limit)
///
/// i.e. the most conservative of the fraction cap, the operator reserve, and
/// the absolute limit wins. The 0.90 fraction and the 2 GiB OS floor keep
/// binding on REAL physical memory, so the OS protections never weaken.
///
/// Like `UnifiedMemoryCap`, this is pure policy: no globals, no side effects.
public enum MemoryLimit {
    /// Normalized limit in bytes. `nil` when `limitGB` is nil, 0, or at/above
    /// physical RAM — all three mean "no artificial limit". A degenerate 0 is
    /// treated as unset (not as "no memory") for the same reason
    /// `DARKBLOOM_MEM_CAP_FRACTION` treats 0 as unset: a single bad config
    /// value must not silently brick the provider.
    public static func limitBytes(limitGB: UInt64?, physicalBytes: UInt64) -> UInt64? {
        guard let limitGB, limitGB > 0 else { return nil }
        let bytes = saturatingGiBToBytes(limitGB)
        guard bytes < physicalBytes else { return nil }
        return bytes
    }

    /// The reserve the limit implies: `physical − limit` when a limit is
    /// effective, else 0 (no extra hold-back).
    public static func impliedReserveBytes(limitGB: UInt64?, physicalBytes: UInt64) -> UInt64 {
        guard let limit = limitBytes(limitGB: limitGB, physicalBytes: physicalBytes) else {
            return 0
        }
        return physicalBytes - limit
    }

    /// GiB -> bytes, saturating instead of trapping. Public because the CLI
    /// (`darkbloom memory`) converts operator-supplied GB values too.
    public static func saturatingGiBToBytes(_ gib: UInt64) -> UInt64 {
        let (bytes, overflow) = gib.multipliedReportingOverflow(by: 1_073_741_824)
        return overflow ? UInt64.max : bytes
    }
}

extension ProviderSettings {
    /// Effective operator reserve in bytes:
    /// `max(memory_reserve_gb, physical − memory_limit_gb)`, saturating.
    ///
    /// This is THE value every `configReserveBytes` consumer must use — the
    /// load gate, the runtime KV budget, EngineV2 KV sizing, and the heartbeat
    /// `free_for_load_gb` all derive the same effective cap from it, keeping
    /// the load-time and run-time gates consistent (no gate can promise memory
    /// another gate holds back).
    public func effectiveReserveBytes(
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> UInt64 {
        max(
            MemoryLimit.saturatingGiBToBytes(memoryReserveGB),
            MemoryLimit.impliedReserveBytes(limitGB: memoryLimitGB, physicalBytes: physicalBytes)
        )
    }

    /// Normalized absolute cap in bytes; `nil` when no effective limit is
    /// configured (unset, 0, or ≥ physical). Feeds the MLX soft ceiling and
    /// the heartbeat's reported `total_memory_gb`.
    public func memoryLimitBytes(
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> UInt64? {
        MemoryLimit.limitBytes(limitGB: memoryLimitGB, physicalBytes: physicalBytes)
    }
}
