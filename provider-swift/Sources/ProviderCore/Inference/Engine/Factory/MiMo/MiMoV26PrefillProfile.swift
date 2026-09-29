// Copyright © 2026 Eigen Labs.
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
}
