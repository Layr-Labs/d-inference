import Foundation

/// One warning per retired knob an operator is still setting.
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
    /// order: environment variables, then `[backend]` retired keys.
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
            out.append(retiredBackendKeyMessage(retired))
        }
        return out
    }

    /// The boolean `mtp` key gets its own wording because ignoring it changes
    /// behavior: a bare `mtp = false` used to mean off, and without an
    /// `mtp_mode` the box now resolves the `auto` default. The operator has to
    /// be told which `mtp_mode` value restores the old intent.
    static func retiredBackendKeyMessage(_ key: String) -> String {
        guard key == "mtp" else {
            return "provider.toml sets [backend] \(key), which is a RETIRED knob and is "
                + "IGNORED — remove the key"
        }
        return "provider.toml sets [backend] mtp, which is a RETIRED knob and is IGNORED — "
            + "MTP follows [backend] mtp_mode (default \"auto\"), not this key. "
            + "To keep MTP off, set mtp_mode = \"off\"; to force it on, set "
            + "mtp_mode = \"on\"; then remove the mtp key"
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
