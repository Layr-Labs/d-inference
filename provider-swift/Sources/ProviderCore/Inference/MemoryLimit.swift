import Foundation

/// Normalization for the operator's absolute memory limit (`memory_limit_gb`).
///
/// An operator who wants Darkbloom to use at most 150 GB of a 256 GB machine
/// sets `memory_limit_gb = 150`. Internally the limit is expressed as a
/// reserve — `physical − limit` — so it rides the existing
/// `configReserveBytes` plumbing (`UnifiedMemoryCap.loadReserveBytes`,
/// `GlobalKVCacheBudget`, EngineV2 KV sizing, heartbeat `free_for_load_gb`)
/// with no change to the cap policy itself. The resulting invariant:
///
///     effectiveCap = min(0.90 × physical, physical − memory_reserve_gb, limit)
///
/// The most conservative bound wins. The 0.90 fraction and the 2 GiB OS floor
/// keep binding on real physical memory, so the OS protections never weaken.
///
/// Like `UnifiedMemoryCap`, this is pure policy: no globals, no side effects.
public enum MemoryLimit {
    /// Smallest honored limit (GB). The CLI rejects smaller values outright;
    /// a hand-edited TOML below it is clamped up to this floor: dropping the
    /// cap would invert the operator's intent, and honoring e.g. 2 GB leaves
    /// no room for the ~6.5 GiB load headroom — the node would advertise
    /// models and reject every load. 8 GB is the smallest cap that can hold
    /// the headroom plus any weights at all.
    public static let minimumLimitGB: UInt64 = 8

    /// Normalized limit in bytes. `nil` when `limitGB` is nil, 0, or at/above
    /// physical RAM — all three mean "no artificial limit". A degenerate 0 is
    /// treated as unset (not as "no memory") for the same reason
    /// `DARKBLOOM_MEM_CAP_FRACTION` treats 0 as unset: a single bad config
    /// value must not silently brick the provider. Positive values below
    /// ``minimumLimitGB`` clamp up to it (see its doc).
    public static func limitBytes(limitGB: UInt64?, physicalBytes: UInt64) -> UInt64? {
        guard let limitGB, limitGB > 0 else { return nil }
        let bytes = saturatingGiBToBytes(max(limitGB, minimumLimitGB))
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

    /// The single effective operator reserve:
    /// `max(memory_reserve_gb, physical − memory_limit_gb)`, saturating.
    /// Shared by `ProviderLoop` (via `ProviderSettings.effectiveReserveBytes`)
    /// and `StandaloneServer`, so no serving mode holds back less than
    /// another regardless of which knob is the tighter one.
    public static func effectiveReserveBytes(
        reserveGB: UInt64, limitGB: UInt64?, physicalBytes: UInt64
    ) -> UInt64 {
        max(
            saturatingGiBToBytes(reserveGB),
            impliedReserveBytes(limitGB: limitGB, physicalBytes: physicalBytes))
    }

    /// The effective inference cap in bytes:
    /// `min(0.90 × physical (UnifiedMemoryCap), physical − effectiveReserve)`.
    /// One formula for every display/fit surface (`darkbloom memory`, status,
    /// the standalone model filter) so they can never disagree with the
    /// daemon's gates, which derive the same bound from the same reserve.
    public static func effectiveCapBytes(
        reserveGB: UInt64, limitGB: UInt64?, physicalBytes: UInt64
    ) -> UInt64 {
        let reserve = effectiveReserveBytes(
            reserveGB: reserveGB, limitGB: limitGB, physicalBytes: physicalBytes)
        let underReserve = physicalBytes > reserve ? physicalBytes - reserve : 0
        return min(UnifiedMemoryCap.hardCapBytes(physicalBytes: physicalBytes), underReserve)
    }

    static func saturatingGiBToBytes(_ gib: UInt64) -> UInt64 {
        let (bytes, overflow) = gib.multipliedReportingOverflow(by: 1_073_741_824)
        return overflow ? UInt64.max : bytes
    }
}

extension ProviderSettings {
    /// Effective operator reserve in bytes:
    /// `max(memory_reserve_gb, physical − memory_limit_gb)`, saturating.
    ///
    /// The value every `configReserveBytes` consumer must use: the load gate,
    /// the runtime KV budget, EngineV2 KV sizing, and the heartbeat
    /// `free_for_load_gb` all derive the same effective cap from it, keeping
    /// the load-time and run-time gates consistent (no gate can promise memory
    /// another gate holds back).
    public func effectiveReserveBytes(
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> UInt64 {
        MemoryLimit.effectiveReserveBytes(
            reserveGB: memoryReserveGB, limitGB: memoryLimitGB, physicalBytes: physicalBytes)
    }

    /// Effective inference cap in bytes — see ``MemoryLimit/effectiveCapBytes``.
    public func effectiveCapBytes(
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> UInt64 {
        MemoryLimit.effectiveCapBytes(
            reserveGB: memoryReserveGB, limitGB: memoryLimitGB, physicalBytes: physicalBytes)
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
