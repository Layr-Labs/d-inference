import Foundation

/// Switches and sizing for the RAM-only prefix tier that only `memory_only`
/// requests use. The tier holds nothing until such a request donates a
/// checkpoint, so `auto` costs no memory on a Mac that never serves one.
enum MemoryOnlyPrefixCachePolicy {
    static let modeEnvironmentKey = "DARKBLOOM_ZDR_PREFIX_CACHE_RAM"
    static let maximumMegabytesEnvironmentKey = "DARKBLOOM_ZDR_PREFIX_CACHE_RAM_MAX_MB"

    /// The default cap on the tier, and the share of the fleet KV headroom it
    /// may use at most. Below `minimumBudgetBytes` the tier is off: one long
    /// prefix's checkpoint would not fit beside another.
    static let defaultCapBytes: UInt64 = 8 << 30
    static let headroomDivisor: UInt64 = 4
    static let minimumBudgetBytes: UInt64 = 1 << 30

    /// On when unset, empty or `auto`; any other value turns the tier off, as
    /// does the global prefix-cache switch.
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard PrefixCachePolicy.isGloballyEnabled(environment: environment) else { return false }
        guard let raw = environment[modeEnvironmentKey]?.trimmingCharacters(in: .whitespaces).lowercased(),
            !raw.isEmpty
        else { return true }
        return raw == "auto"
    }

    /// Whether a slot's complete-checkpoint store gets the tier. A slot with
    /// an engine-resident tier (`DARKBLOOM_PREFIX_CACHE_MEMORY=1`) serves
    /// `memory_only` requests with their cache off, so it gets none, nor does
    /// an excluded model (GLM 5 Next, Nemotron Super).
    static func attachesTier(
        excludedModel: Bool, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !excludedModel && isEnabled(environment: environment)
            && !PrefixCachePolicy.isMemoryEnabled(environment: environment)
    }

    /// A positive whole number of MiB replaces the default cap; anything else
    /// keeps it.
    static func capBytes(environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt64 {
        guard let raw = environment[maximumMegabytesEnvironmentKey],
            let megabytes = UInt64(raw.trimmingCharacters(in: .whitespaces)), megabytes > 0,
            megabytes <= UInt64.max >> 20
        else { return defaultCapBytes }
        return megabytes << 20
    }

    /// `min(cap, headroom / 4)`, or 0 (off) when that is below 1 GiB.
    /// `fleetKVHeadroomBytes` is the unified-memory cap minus resident weights
    /// and the activation reserve (`UnifiedMemoryCap.kvBudgetBytes`): what the
    /// KV pool may use. The tier never takes it from the pool's grant; it is
    /// charged to the process ledger and released whenever a charge needs it.
    static func budgetBytes(
        fleetKVHeadroomBytes: UInt64,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UInt64 {
        guard isEnabled(environment: environment) else { return 0 }
        let budget = min(capBytes(environment: environment), fleetKVHeadroomBytes / headroomDivisor)
        return budget >= minimumBudgetBytes ? budget : 0
    }
}
