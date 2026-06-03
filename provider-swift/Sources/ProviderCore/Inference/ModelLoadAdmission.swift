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
/// `GlobalKVCacheBudget`, which strictly rejects any request whose KV won't fit
/// real free memory (so this looser load gate cannot cause an OOM — the worst
/// case is a loaded model that serves a single request at a time).
public enum ModelLoadAdmission {
    /// Default headroom (GB) reserved above the weights for one request's KV
    /// cache + activations at load time. Small on purpose: it only needs to
    /// cover a single in-flight request; the runtime budget grows concurrency
    /// from whatever is left. Tunable via provider config.
    public static let defaultLoadHeadroomGb: Double = 2.0

    /// Physical memory (GB) available to load a model: total minus the OS
    /// reserve and whatever MLX already has resident (active + cache). NOTE:
    /// deliberately NO 0.7 safety discount — weights are a known allocation, and
    /// the 0.7 runtime safety is already applied per-request by
    /// GlobalKVCacheBudget. Discounting here too is the double-count that kept
    /// capable machines idle.
    public static func freeForLoadGb(
        totalBytes: UInt64,
        gpuActiveBytes: UInt64,
        gpuCacheBytes: UInt64,
        reserveBytes: UInt64
    ) -> Double {
        let used = saturatingAdd(gpuActiveBytes, gpuCacheBytes, reserveBytes)
        let usable = totalBytes > used ? totalBytes - used : 0
        return Double(usable) / bytesPerGb
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
        gpuActiveBytes: UInt64,
        gpuCacheBytes: UInt64,
        reserveBytes: UInt64
    ) -> Bool {
        let free = freeForLoadGb(totalBytes: totalBytes, gpuActiveBytes: gpuActiveBytes, gpuCacheBytes: gpuCacheBytes, reserveBytes: reserveBytes)
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
