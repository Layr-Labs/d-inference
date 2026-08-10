import Foundation

/// One warning per retired knob an operator is still setting, plus one per
/// one-time config migration this decode applied silently.
///
/// WHY THIS IS NOT IN THE SERVE LOOP. These warnings used to live inline at
/// the top of `ProviderLoop.run()`, which meant only the coordinator-serving
/// modes ever emitted them: `darkbloom start --local` builds a
/// `StandaloneServer` and no `ProviderLoop` at all, so an operator upgrading
/// a `provider.toml` that still set `kv_quant` was told nothing — while
/// `docs/provider/beta-features.md` promises "startup logs one warning per
/// retired key". Hoisting them here, called once from `Start.run()` before
/// the serving-mode split, gives every mode the same one implementation.
///
/// `messages` is pure so the wording is testable without a daemon, a
/// coordinator, or a config file on disk.
public enum RetiredKnobWarnings {
    /// Every config warning this config + environment earns, in a stable
    /// order: environment variables, then `[backend]` retired keys, then
    /// applied migrations.
    public static func messages(
        config: ProviderConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var out: [String] = []
        // v0.7.5 one-engine: the v2 selection knobs are retired — warn
        // operators still setting them so nobody believes a kill switch
        // exists that doesn't. Selection is unconditional; rollback is
        // release-level.
        for retired in EngineV2Config.retiredEnvironmentKeysSet(environment: environment) {
            out.append(
                "\(retired) is retired and IGNORED as of v0.7.5 — the v2 engine serves "
                    + "everything; rollback is release-level, not a per-box switch")
        }
        for retired in config.backend.retiredKeysPresent {
            out.append(
                "provider.toml sets [backend] \(retired), which is a RETIRED knob and is "
                    + "IGNORED — remove the key")
        }
        // One-time migrations applied during decode. The operator's file on
        // disk still reads the OLD value until the startup stamp rewrites
        // it, so a silent migration would leave the file and the running
        // behaviour disagreeing with nothing to explain the gap.
        for id in config.appliedMigrations {
            guard let step = ConcurrencyDefaultMigration.step(id: id) else { continue }
            out.append(
                "provider.toml is at config_version \(step.fromVersion) and sets [backend] "
                    + "engine_v2_max_concurrent = \(step.fromCap), the default that release "
                    + "generated — changing it to \(step.toCap). B=\(step.toCap) is the knee of "
                    + "the measured contiguous batch curve: aggregate throughput is flat from "
                    + "B=\(step.toCap) to B=\(step.fromCap) while per-request decode is "
                    + "aggregate/B, so the smaller batch is worth ~87% more tok/s per request "
                    + "at essentially the same aggregate. THIS CANNOT TELL a generated "
                    + "\(step.fromCap) from one you chose deliberately — if you meant it, set "
                    + "it again: this migration runs once and an explicit \(step.fromCap) is "
                    + "honoured from then on.")
        }
        return out
    }

    /// Log the above at WARN and hand them back so a caller with an operator
    /// at a terminal (`darkbloom start`) can echo them too — the unified log
    /// is not where someone watching a standalone server come up is looking.
    /// Call once per process, before the serving mode is chosen.
    @discardableResult
    public static func emit(
        config: ProviderConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let logger = ProviderLogger(subsystem: "dev.darkbloom.provider", category: "config")
        let out = messages(config: config, environment: environment)
        for message in out {
            logger.warning(message)
        }
        return out
    }
}
