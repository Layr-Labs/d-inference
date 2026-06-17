import Foundation

/// Pure memory arithmetic for deciding whether a model can be LOADED on this
/// machine. Kept separate from the runtime per-request KV admission
/// (`GlobalKVCacheBudget`) and unit-testable on any platform.
///
/// The foundational fix: loading a model is a one-time, known allocation (the
/// weights). The previous gate demanded `weights × 2.0` of headroom AND then
/// only counted `free × 0.7` as usable — together requiring `free ≥ weights ×
/// 2.86`. That baked full-concurrency KV headroom into the LOAD decision and
/// left every small/mid machine unable to load a model it could actually serve.
///
/// Correct model: load whenever the weights plus enough headroom for ONE
/// request physically fit alongside the OS reserve. Concurrency BEYOND one
/// request is then sized dynamically at runtime by the live token budget +
/// `GlobalKVCacheBudget`, which (since the unified-cap rework) strictly rejects
/// any request whose KV would push past the 90% unified-memory cap — net of the
/// activation reserve and clamped to real OS-free memory — so this looser load
/// gate cannot cause an OOM (worst case: a loaded model that serves a single
/// request at a time).
public enum ModelLoadAdmission {
    /// Default headroom (GB) reserved above the weights at load time. Derived
    /// from `UnifiedMemoryCap.loadHeadroomBytes()` (activation reserve + minimum
    /// serveable KV) so it is the SAME ceiling the runtime KV gate enforces — a
    /// model that passes the load gate can actually serve. Do NOT hardcode a
    /// smaller flat value here: a default below the activation reserve lets a
    /// near-cap model load and then have every request rejected at the KV gate
    /// (the admit-then-reject trap). Callers may still pass an explicit
    /// `headroomGb` for pure-arithmetic tests.
    public static var defaultLoadHeadroomGb: Double {
        Double(UnifiedMemoryCap.loadHeadroomBytes()) / (1024.0 * 1024.0 * 1024.0)
    }

    /// Physical memory (GB) available to load a model: the real free memory
    /// (clamped to what the OS actually reports available, not just total minus
    /// MLX's resident set) minus the OS reserve and any KV already promised to
    /// in-flight requests. NOTE: deliberately NO multiplicative safety discount
    /// here — weights are a known allocation, and runtime KV safety (the 90%
    /// unified cap + activation reserve) is applied per-request by
    /// GlobalKVCacheBudget. Discounting here too is the double-count that kept
    /// capable machines idle.
    /// - Parameters:
    ///   - systemAvailableBytes: real OS-reported available memory (free +
    ///     reclaimable). Pass `.max` when unavailable to fall back to the
    ///     MLX-only view. The result is clamped to this so the gate can never
    ///     count memory the OS or other processes have already taken — the fix
    ///     for the OOM hole where `total − MLX.active − MLX.cache` over-reports.
    ///   - outstandingReservationBytes: KV bytes already promised to in-flight
    ///     requests (`GlobalKVCacheBudget`). Subtracted so a concurrent load
    ///     can't claim memory a mid-decode request is counting on.
    public static func freeForLoadGb(
        totalBytes: UInt64,
        systemAvailableBytes: UInt64 = .max,
        gpuActiveBytes: UInt64,
        gpuCacheBytes: UInt64,
        reserveBytes: UInt64,
        outstandingReservationBytes: UInt64 = 0
    ) -> Double {
        let mlxUsed = saturatingAdd(gpuActiveBytes, gpuCacheBytes)
        let mlxFree = totalBytes > mlxUsed ? totalBytes - mlxUsed : 0
        // The OS view and the MLX view can each be the tighter bound; take the
        // smaller so we never over-count free memory.
        let realFree = min(mlxFree, systemAvailableBytes)
        let committed = saturatingAdd(reserveBytes, outstandingReservationBytes)
        let usable = realFree > committed ? realFree - committed : 0
        return Double(usable) / bytesPerGb
    }

    /// Maximum model-WEIGHT footprint (GB) this machine could load right now,
    /// assuming idle/evictable resident models are unloaded to make room. This is
    /// the number the coordinator needs for COLD-LOAD routing: it answers "if I
    /// send this model, will the provider successfully load it?" — net of the
    /// unified-memory cap, OS/operator reserve, the activation + min-serveable-KV
    /// load headroom, and real OS-available memory.
    ///
    /// Unlike `freeForLoadGb`, `mlxUsedBytes` (MLX active + cache) is treated as
    /// RECLAIMABLE: on a cold load the provider LRU-evicts idle models, freeing
    /// that memory back to the OS, so the memory we could reclaim is
    /// `min(total, systemAvailable + mlxUsed)`. The coordinator only consults this
    /// value on the idle path (totalPending == 0), where every resident model is
    /// in fact evictable, so the full-eviction assumption holds. The result is the
    /// loadable headroom MINUS the load headroom, i.e. weights only; clamped >= 0.
    ///
    /// - Parameters:
    ///   - reserveBytes: OS/operator reserve to hold back, i.e.
    ///     `UnifiedMemoryCap.loadReserveBytes(...)` = max(configReserve,
    ///     physical − hardCap). This is what enforces the 90% unified cap.
    ///   - headroomGb: activation reserve + min serveable KV (defaults to the
    ///     same `defaultLoadHeadroomGb` the load gate requires above weights).
    ///   - outstandingReservationBytes: KV already promised to in-flight requests
    ///     (coordinator OR local-endpoint streams). Subtracted just like the
    ///     real load gate (`availableMemoryGb`) does, so a heartbeat can't
    ///     advertise bytes a mid-decode request is counting on but that the OS
    ///     hasn't shown as used yet.
    public static func maxLoadableWeightGb(
        totalBytes: UInt64,
        systemAvailableBytes: UInt64 = .max,
        mlxUsedBytes: UInt64,
        reserveBytes: UInt64,
        headroomGb: Double = defaultLoadHeadroomGb,
        outstandingReservationBytes: UInt64 = 0
    ) -> Double {
        // Evicting idle models frees their MLX memory back to the OS, so the
        // reclaimable pool is current OS-available plus our own MLX usage, capped
        // at total physical. Hold back the load reserve and any outstanding KV
        // reservation, then the load headroom.
        let reclaimable = min(totalBytes, saturatingAdd(systemAvailableBytes, mlxUsedBytes))
        let committed = saturatingAdd(reserveBytes, outstandingReservationBytes)
        let usable = reclaimable > committed ? reclaimable - committed : 0
        let freeGb = Double(usable) / bytesPerGb
        return max(0, freeGb - max(0, headroomGb))
    }

    /// Memory (GB) required to load a model and serve at least one request:
    /// the (overhead-padded) weight footprint plus one-request headroom.
    public static func requiredToLoadGb(weightsGb: Double, headroomGb: Double = defaultLoadHeadroomGb) -> Double {
        max(0, weightsGb) + max(0, headroomGb)
    }

    /// Whether a model with the given weight footprint can be loaded now.
    public static func canLoad(
        weightsGb: Double,
        headroomGb: Double,
        totalBytes: UInt64,
        systemAvailableBytes: UInt64 = .max,
        gpuActiveBytes: UInt64,
        gpuCacheBytes: UInt64,
        reserveBytes: UInt64,
        outstandingReservationBytes: UInt64 = 0
    ) -> Bool {
        let free = freeForLoadGb(
            totalBytes: totalBytes,
            systemAvailableBytes: systemAvailableBytes,
            gpuActiveBytes: gpuActiveBytes,
            gpuCacheBytes: gpuCacheBytes,
            reserveBytes: reserveBytes,
            outstandingReservationBytes: outstandingReservationBytes)
        return requiredToLoadGb(weightsGb: weightsGb, headroomGb: headroomGb) <= free
    }

    private static let bytesPerGb = 1024.0 * 1024.0 * 1024.0

    private static func saturatingAdd(_ values: UInt64...) -> UInt64 {
        var total: UInt64 = 0
        for v in values {
            let (sum, overflow) = total.addingReportingOverflow(v)
            if overflow { return UInt64.max }
            total = sum
        }
        return total
    }
}
