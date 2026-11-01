import Foundation

/// Operator-facing explanation of a slot's SSD prefix-cache status: the same
/// state, reason and typed cause the heartbeat reports, with the fix. Read by
/// `status`, `doctor` (the desktop app's diagnostics run it) and the daemon's
/// load-time notice.
public enum PrefixCacheDiagnosis {
    /// `prefix_cache=…` for one slot; nil for a state file that predates it.
    public static func statusPhrase(_ slot: DaemonState.SlotPosture) -> String? {
        guard slot.prefixCacheState != nil, let reason = slot.prefixCacheReason else { return nil }
        switch state(of: slot) {
        case .ready: return "prefix_cache=ready"
        case .pending: return "prefix_cache=starting"
        case .error where isClosing(slot): return "prefix_cache=closed (unloading)"
        case .error: return "prefix_cache=FAILED (\(cause(reason: reason, detail: slot.prefixCacheDetail)))"
        case .disabled, nil: return "prefix_cache=off (\(reason))"
        }
    }

    /// The cause and fix behind an `error` status; nil for any other state or
    /// a cause with nothing for the operator to do.
    public static func advice(
        state: String?, reason: String?, detail: String?,
        cliName: String = BuildEnvironment.current.cliName
    ) -> DiagnosticAdvice? {
        guard state == PrefixCacheStatusState.error.rawValue else { return nil }
        let restart = "then `\(cliName) restart`"
        switch detail.flatMap(SSDPrefixCacheConstructionFailure.init(rawValue:)) {
        case .keyUnavailable:
            return DiagnosticAdvice(
                message: "its encryption key could not be loaded from the Secure Enclave and Keychain",
                fix: "run the signed release (`\(cliName) update`); on a Mac not unlocked since boot, "
                    + "log in at the console once; \(restart). The exact cause is in "
                    + "`log show --last 1h --predicate 'subsystem == \"\(BuildEnvironment.current.logSubsystem)\" "
                    + "AND category == \"ssd_prefix_cache\"'`")
        case .unsafePath:
            return DiagnosticAdvice(
                message: "the cache directory is missing, moved or unsafe",
                fix: "check `\(cliName) cache status`; reconnect the selected volume or run "
                    + "`\(cliName) cache set --reset-directory`; \(restart)")
        case .epochUnavailable, .writeBudgetUnavailable:
            return DiagnosticAdvice(
                message: "its cache records could not be read or written",
                fix: "free disk space and check that the cache directory is yours and writable "
                    + "(`\(cliName) cache status`); \(restart)")
        case .identityUnavailable, .blockContractMismatch, .layoutUnavailable:
            return DiagnosticAdvice(
                message: "this build cannot cache the model",
                fix: "update with `\(cliName) update`")
        case .promptContractUnavailable:
            return DiagnosticAdvice(
                message: "the model's prompt files could not be read",
                fix: "re-download the model; \(restart)")
        case .ephemeralKeyUnavailable:
            return DiagnosticAdvice(
                message: "the test-only in-memory cache key failed",
                fix: "unset DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL; \(restart)")
        case .cacheClosed, .missingWeightHash, .unsupportedPlan:
            return nil
        case nil:
            return reason == PrefixCacheStatusReason.cacheInitFailed.rawValue
                ? DiagnosticAdvice(
                    message: "the cache could not start",
                    fix: "see `\(cliName) logs`; \(restart)")
                : nil
        }
    }

    /// One runtime check per slot whose cache failed, else one passing check.
    public static func diagnostics(slots: [DaemonState.SlotPosture]?) -> [Diagnostic] {
        guard let slots, slots.contains(where: { $0.prefixCacheState != nil }) else { return [] }
        let failed = slots.filter { state(of: $0) == .error && !isClosing($0) }
        guard !failed.isEmpty else {
            let caching = slots.filter { state(of: $0) == .ready || state(of: $0) == .pending }
            return [Diagnostic(
                section: .runtime, name: "prefix cache", level: .pass,
                message: "\(caching.count) of \(slots.count) loaded model(s) cache prompts on SSD; "
                    + "no cache failed to start.")]
        }
        return failed.map { slot in
            let help = advice(
                state: slot.prefixCacheState, reason: slot.prefixCacheReason, detail: slot.prefixCacheDetail)
            return Diagnostic(
                section: .runtime, name: "prefix cache", level: .warn,
                message: "\(slot.model) serves uncached "
                    + "(\(cause(reason: slot.prefixCacheReason, detail: slot.prefixCacheDetail)))"
                    + (help.map { ": \($0.message)" } ?? "")
                    + "; it retries when the model next loads.",
                fix: help?.fix)
        }
    }

    /// The daemon's `provider.log` line for a slot published with a failed
    /// cache; nil for any other status.
    static func loadNotice(
        _ status: PrefixCacheModelStatus, cliName: String = BuildEnvironment.current.cliName
    ) -> String? {
        guard status.state == .error else { return nil }
        let reason = status.reason.rawValue
        let detail = status.detail?.rawValue
        let fix = advice(state: status.state.rawValue, reason: reason, detail: detail, cliName: cliName)?.fix
        return "SSD prefix cache unavailable for \(status.modelId) (\(cause(reason: reason, detail: detail))); "
            + "serving uncached until the model reloads." + (fix.map { " Fix: \($0)" } ?? "")
    }

    /// `<reason>: <detail>`, or the reason alone when no cause was reported.
    private static func cause(reason: String?, detail: String?) -> String {
        [reason, detail].compactMap { $0 }.joined(separator: ": ")
    }

    private static func state(of slot: DaemonState.SlotPosture) -> PrefixCacheStatusState? {
        slot.prefixCacheState.flatMap(PrefixCacheStatusState.init(rawValue:))
    }

    /// A store closed with its unloading slot; not a failure to report.
    private static func isClosing(_ slot: DaemonState.SlotPosture) -> Bool {
        slot.prefixCacheDetail == SSDPrefixCacheConstructionFailure.cacheClosed.rawValue
    }
}
