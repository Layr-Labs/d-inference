// Copyright © 2026 Eigen Labs.
import Foundation
import MLXLMCommon

extension EngineV2Factory {
    /// Called before either native backend's slot assembly. Validation uses
    /// the actual SDK dispatch latches, never a new process-environment sample.
    static func validateNativeMiMoPrefillPolicy(environment: [String: String]) throws {
        try MiMoV26PrefillPolicy.validateProcessControls(environment: environment)
    }

    /// Called only by the genuine native MiMo contiguous factory shared by
    /// ProviderLoop, Standalone and the native benchmark-session path.
    /// The engine may decline this request without changing the old profile.
    /// makeNativeMiMoBundle first validates any explicit injected controls
    /// against the process latches; this helper selects scheduler width only.
    static func nativeMiMoAutomaticPrefill(environment: [String: String]) -> Bool {
        guard environment[soloPrefillStripeKey] == nil,
              MiMoV26PrefillPolicy.latchedAttentionEnabled,
              MiMoV26PrefillPolicy.latchedGroupingEnabled,
              MiMoV26PrefillPolicy.isEnabled(environment[MiMoV26PrefillPolicy.attentionEnvironmentKey]),
              MiMoV26PrefillPolicy.isEnabled(environment[MiMoV26PrefillPolicy.groupedEnvironmentKey])
        else { return false }
        if let block = environment["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK"] {
            guard Int(block) == 128 else { return false }
        }
        return true
    }

    /// The loop settings both native MiMo engines (contiguous and paged) run with.
    ///
    /// A step longer than `stepTimeout` makes the SDK watchdog seal a native
    /// engine for good (`fail(.stepWatchdog)` is write-once), even when the step
    /// then finishes. A healthy MiMo prefill step grows with its context: on an
    /// M5 Ultra it took 15.6 s at about 170k tokens, and M3 Ultras prefill MiMo
    /// three to four times slower, about 47 to 78 s, past the SDK's 30 s
    /// default. So a native MiMo step may run as long as the engine's prefill
    /// progress lease, the point where the engine already treats a prefill as
    /// stalled. A step that never returns is still caught, two minutes in
    /// instead of 30 s.
    static func nativeMiMoLoopConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CBv2EngineLoopConfig {
        var config = CBv2EngineLoopConfig(
            useLegacyRequestTimeout: legacyRequestTimeoutEnabled(environment: environment))
        config.stepTimeout = max(config.stepTimeout, config.prefillProgressLease)
        return config
    }
}
