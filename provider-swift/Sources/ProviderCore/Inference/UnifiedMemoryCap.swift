import Foundation

/// Single source of truth for the provider's unified-memory budget.
///
/// The invariant the whole provider enforces is:
///
///     Σ(resident model weights) + KV cache + activations  ≤  hardCapBytes
///
/// where `hardCapBytes` is a fixed fraction (default 90%) of physical unified
/// memory. Everything else — which models may be co-resident, when one is
/// evicted, and how much memory KV cache may use — is derived from this one
/// number. The policy is general: it makes no assumption about WHICH models are
/// loaded or HOW MANY; it works for one model, two, or N.
///
/// This type is PURE POLICY: it reads no MLX globals and mutates nothing, so it
/// is fully unit-testable and safe to call from any context. Enforcement (load
/// admission, the KV reservation budget) consults these figures; MLX's own
/// `memoryLimit` is a soft guideline that cannot enforce the cap on its own
/// (the Metal allocator frees cache and then allocates past the byte limit
/// anyway — only the resource COUNT limit throws), so the cap lives here in the
/// admission layer, not in an MLX setting. See ``MLXMemoryGuard`` for the soft
/// MLX ceiling we still pin as defense-in-depth.
public enum UnifiedMemoryCap {
    /// Fraction of physical unified memory the provider may use for EVERYTHING
    /// (weights + KV + activations). The remaining `1 − fraction` is left for
    /// macOS and non-MLX processes. Default 0.90.
    public static let defaultCapFraction: Double = 0.90

    /// Absolute floor on the reserve held back for the OS, so a small box never
    /// hands almost all of RAM to the provider. The percentage reserve and this
    /// floor cross over at `minReserve / (1 − fraction)` — with the 0.90 default
    /// that is 2 GiB / 0.10 = 20 GiB: above 20 GiB the 10% fraction reserve
    /// dominates and this floor never binds; at/below it, this floor protects the
    /// OS (e.g. an 8 GiB box gets a 6 GiB cap, not 7.2 GiB).
    static let minimumReserveBytes: UInt64 = 2 * 1024 * 1024 * 1024  // 2 GiB

    /// Default activation/working-memory reserve carved out INSIDE the cap.
    ///
    /// Measured on M5 Max (Gemma-4-26B-qat-4bit + GPT-OSS-20B, both MoE): a
    /// 4-concurrent ~3000-token long-prefill burst moved RSS by only ~9 MB over
    /// the resident-weight baseline — MoE activates few experts, MLX fuses
    /// attention, and intermediates churn through the (count-bounded) buffer
    /// cache rather than growing the live set. So activations are small in
    /// practice; this is a conservative SAFETY FLOOR, not a per-batch estimate.
    static let defaultActivationReserveBytes: UInt64 = 3 * 1024 * 1024 * 1024  // 3 GiB

    /// Minimum KV headroom (bytes) a freshly-loaded model must have under the cap
    /// to be worth loading — a model that loads but can serve no KV is useless.
    /// Small (1 GiB): the load gate only needs to guarantee the model can serve
    /// at least a modest request; concurrency beyond that is sized at runtime.
    static let minimumLoadKVBytes: UInt64 = 1 * 1024 * 1024 * 1024  // 1 GiB

    /// The post-load guard decision, as a pure function so it's unit-testable
    /// (the BatchScheduler accessor that feeds it reads real MLX globals). A
    /// freshly-loaded model is serveable iff its MEASURED live KV headroom (taken
    /// AFTER trimming the cold-load buffer cache) is at least the minimum
    /// serveable KV. Below that, the caller unloads + rejects rather than keep a
    /// model whose every request the KV gate would reject.
    public static func loadIsServeable(measuredLiveKVHeadroomBytes: UInt64) -> Bool {
        measuredLiveKVHeadroomBytes >= minimumLoadKVBytes
    }

    /// Headroom (bytes) the model-LOAD gate must require ABOVE the weights, so a
    /// model that passes the gate can actually serve. The runtime KV path carves
    /// out the activation reserve and then needs some KV room; the load gate must
    /// reserve at least that much too, or it admits a model `GlobalKVCacheBudget`
    /// then rejects every request for (the load gate's old flat 2 GiB one-request
    /// headroom was LESS than the 3 GiB activation reserve, so a near-cap model
    /// loaded with zero serveable KV). Returns
    /// `activationReserve + minimumLoadKV`.
    public static func loadHeadroomBytes(
        activationReserveBytes: UInt64? = nil
    ) -> UInt64 {
        let activations = activationReserveBytes ?? resolvedActivationReserveBytes()
        return saturatingAdd(activations, minimumLoadKVBytes)
    }

    // MARK: - Cap

    /// The hard cap in bytes: `min(fraction × physical, physical − minReserve)`.
    /// Never exceeds physical and always leaves at least `minimumReserveBytes`.
    public static func hardCapBytes(
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        capFraction: Double? = nil
    ) -> UInt64 {
        let fraction = resolvedCapFraction(explicit: capFraction)
        let byFraction = scale(physicalBytes, by: fraction)
        // Never leave less than the absolute OS floor.
        let byFloor = physicalBytes > minimumReserveBytes
            ? physicalBytes - minimumReserveBytes
            : 0
        return min(byFraction, byFloor)
    }

    /// Bytes available for KV cache after subtracting all resident model weights,
    /// the activation reserve, and any RAM-resident prefix-cache allowance, from
    /// the hard cap. Clamps to 0 — never returns a negative budget.
    ///
    /// This is the core of the policy: `cap − Σweights − activations − ramPrefix`.
    /// It is recomputed whenever a model loads or unloads, so it rises as models
    /// leave and shrinks as they join, with no special-casing of model count.
    public static func kvBudgetBytes(
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        residentWeightBytes: UInt64,
        activationReserveBytes: UInt64? = nil,
        ramPrefixAllowanceBytes: UInt64 = 0,
        capFraction: Double? = nil
    ) -> UInt64 {
        let cap = hardCapBytes(physicalBytes: physicalBytes, capFraction: capFraction)
        let activations = activationReserveBytes ?? resolvedActivationReserveBytes()
        let claimed = saturatingAdd(residentWeightBytes, activations, ramPrefixAllowanceBytes)
        return cap > claimed ? cap - claimed : 0
    }

    /// Live KV headroom in bytes: how many more bytes may be committed to KV
    /// *right now* without crossing the cap, given current MLX usage, clamped to
    /// real OS-free RAM and net of the activation reserve.
    ///
    /// This is the runtime counterpart to ``kvBudgetBytes``: instead of
    /// subtracting a known Σweights, it subtracts `mlxUsedBytes` (MLX active +
    /// cache), which already reflects every co-resident model's weights AND its
    /// live/cached KV — so it is inherently multi-model with no per-model
    /// bookkeeping. The single per-request reservation gate and the per-scheduler
    /// live token budget both derive from this, which is what keeps them
    /// consistent (no competing reserve constants).
    ///
    /// Uses the same ``hardCapBytes`` ceiling — including its 2 GiB absolute OS
    /// floor — as the load gate, so the floor is honored as KV GROWS during
    /// serving (the load gate only guarantees it at load time; KV expands after).
    /// On boxes above ~20 GiB the floor never binds and this equals
    /// `capFraction × physical − mlxUsed`. Cross-process safety additionally
    /// comes from the `systemAvailableBytes` clamp.
    public static func liveKVHeadroomBytes(
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        mlxUsedBytes: UInt64,
        systemAvailableBytes: UInt64,
        activationReserveBytes: UInt64? = nil,
        configReserveBytes: UInt64 = 0,
        capFraction: Double? = nil
    ) -> UInt64 {
        // Honor an operator-configured reserve (`memory_reserve_gb`) that is
        // larger than the cap's own implied OS reserve (`physical − cap`), so the
        // runtime KV gate holds back the SAME memory the load gate does
        // (`loadReserveBytes = max(configReserve, physical − cap)`). Without this,
        // serving could grow KV up to the 90% cap and consume memory the operator
        // explicitly reserved, reintroducing the OS-pressure/OOM the reserve
        // exists to prevent. No-op when `configReserve ≤ physical − cap`.
        let cap = hardCapBytes(physicalBytes: physicalBytes, capFraction: capFraction)
        let reserveFloor = physicalBytes > configReserveBytes ? physicalBytes - configReserveBytes : 0
        let effectiveCap = min(cap, reserveFloor)
        let underCap = effectiveCap > mlxUsedBytes ? effectiveCap - mlxUsedBytes : 0
        let realFree = min(underCap, systemAvailableBytes)
        let activations = activationReserveBytes ?? resolvedActivationReserveBytes()
        return realFree > activations ? realFree - activations : 0
    }

    /// Whether a new model of `candidateWeightBytes` may be admitted while
    /// `currentResidentWeightBytes` are already resident, leaving at least
    /// `minimumKVBytes` of KV headroom under the cap (a model that loads with no
    /// room to serve any KV is useless). Pure check; eviction is the caller's job.
    public static func canAdmit(
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        currentResidentWeightBytes: UInt64,
        candidateWeightBytes: UInt64,
        minimumKVBytes: UInt64,
        activationReserveBytes: UInt64? = nil,
        ramPrefixAllowanceBytes: UInt64 = 0,
        capFraction: Double? = nil
    ) -> Bool {
        let cap = hardCapBytes(physicalBytes: physicalBytes, capFraction: capFraction)
        let activations = activationReserveBytes ?? resolvedActivationReserveBytes()
        let need = saturatingAdd(
            currentResidentWeightBytes, candidateWeightBytes,
            activations, ramPrefixAllowanceBytes, minimumKVBytes)
        return need <= cap
    }

    /// Effective reserve (bytes) the model-LOAD gate must hold back below total
    /// physical memory so that loading never pushes usage past the cap.
    ///
    /// The load gate works in "free memory" terms (`total − used − reserve`), so
    /// to honor the cap its reserve must be at least `physical − hardCap` (the
    /// 10% / 2 GiB-floor the cap leaves the OS). It is also never LESS than the
    /// operator's configured reserve — whichever is more conservative wins. This
    /// is what makes the existing free-memory load gate enforce the 90% cap
    /// without a separate code path: hold back `max(configReserve, physical −
    /// hardCap)`.
    public static func loadReserveBytes(
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        configReserveBytes: UInt64,
        capFraction: Double? = nil
    ) -> UInt64 {
        let cap = hardCapBytes(physicalBytes: physicalBytes, capFraction: capFraction)
        let capImpliedReserve = physicalBytes > cap ? physicalBytes - cap : 0
        return max(configReserveBytes, capImpliedReserve)
    }

    // MARK: - Resolution (explicit → env → default)

    /// Cap fraction from explicit value, env `DARKBLOOM_MEM_CAP_FRACTION`
    /// (0–1), or the 0.90 default. A `<= 0` or non-finite env value is treated as
    /// UNSET (→ default), not clamped to 0: a degenerate `0` fraction would make
    /// `hardCapBytes == 0` and reject every request, silently bricking the
    /// provider from a single bad env var. An explicit programmatic value (tests)
    /// is still clamped as given. Values `> 1` clamp to 1.0.
    static func resolvedCapFraction(
        explicit: Double?,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double {
        if let explicit { return clampFraction(explicit) }
        if let raw = env["DARKBLOOM_MEM_CAP_FRACTION"], let v = Double(raw),
            v.isFinite, v > 0 {
            return clampFraction(v)
        }
        return defaultCapFraction
    }

    /// Activation reserve from explicit bytes, env
    /// `DARKBLOOM_ACTIVATION_RESERVE_GB` (GB), or the default floor. A `<= 0` or
    /// non-finite env value is treated as UNSET (→ the 3 GiB default floor): a
    /// `0` reserve would remove the activation headroom the cap exists to
    /// guarantee, so an operator can RAISE the reserve but not silently disable it
    /// via env. An explicit programmatic value (tests) is honored as given.
    static func resolvedActivationReserveBytes(
        explicit: UInt64? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> UInt64 {
        if let explicit { return explicit }
        if let raw = env["DARKBLOOM_ACTIVATION_RESERVE_GB"], let gb = Double(raw),
            gb.isFinite, gb > 0 {
            let scaled = gb * 1_073_741_824
            return scaled >= uint64MaxAsDouble ? UInt64.max : UInt64(scaled)
        }
        return defaultActivationReserveBytes
    }

    // MARK: - Helpers

    /// `Double(UInt64.max)` (exactly 2^64) — the saturation threshold so a
    /// `>= uint64MaxAsDouble` test catches every value that would trap on
    /// `UInt64(_:)` conversion. Mirrors ``MLXMemoryGuard``.
    static let uint64MaxAsDouble = Double(UInt64.max)

    private static func clampFraction(_ v: Double) -> Double {
        guard v.isFinite else { return defaultCapFraction }
        return min(1.0, max(0.0, v))
    }

    /// Multiply a byte count by a 0–1 fraction without overflow or a trapping
    /// Double round-trip.
    private static func scale(_ bytes: UInt64, by fraction: Double) -> UInt64 {
        let scaled = Double(bytes) * fraction
        if !scaled.isFinite || scaled <= 0 { return 0 }
        return scaled >= uint64MaxAsDouble ? UInt64.max : UInt64(scaled)
    }

    private static func saturatingAdd(_ values: UInt64...) -> UInt64 {
        var total: UInt64 = 0
        for v in values {
            let (sum, overflow) = total.addingReportingOverflow(v)
            total = overflow ? UInt64.max : sum
        }
        return total
    }
}
