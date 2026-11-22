/// Deadline bounds describe the qualification runner's scrubbed environment.
/// Unknown performance settings cannot borrow those bounds, even when their
/// values appear to select a default. Universal serving policy is separate.
enum DeadlineRuntimeEnvironment {
    /// These exact keys select credentials, control-plane state paths, or
    /// update checks; none changes inference configuration. Keep unknown
    /// DARKBLOOM keys fail-closed instead of guessing from their names.
    private static let operationalKeys: Set<String> = [
        DeveloperSwitch.authTokenPath.environmentKey,
        DeveloperSwitch.keychainAccessGroup.environmentKey,
        DeveloperSwitch.localDirectory.environmentKey,
        DeveloperSwitch.loadedModelsFile.environmentKey,
        "DARKBLOOM_NO_UPDATE_CHECK",
        DeveloperSwitch.pidFile.environmentKey,
        DeveloperSwitch.daemonStateFile.environmentKey,
        DeveloperSwitch.verifiedWeightsFile.environmentKey,
        DeveloperSwitch.watchdogState.environmentKey,
        SDKFeatureDefaults.injectedMarkerKey,
    ]

    static func permitsQualification(_ environment: [String: String],
        cacheIsolation: DeadlineQualificationCacheIsolation? = nil,
        injected: Set<String> = SDKFeatureDefaults.injectedKeys) -> Bool {
        if let cacheIsolation {
            do { try cacheIsolation.validate(environment: environment) }
            catch { return false }
        }
        return !environment.keys.contains { key in
            // The release's own defaults (`SDKFeatureDefaults`) are part of every
            // darkbloom process, the qualification runner's included; profiles
            // are pinned to the provider version. An operator value is not.
            if SDKFeatureDefaults.isInjected(key, in: environment, injected: injected) { return false }
            if key == EngineV2KVQuantizationPolicy.environmentKey {
                // Existing bounds describe native execution only. The factory
                // publishes this resolved key even without an env override.
                return (try? EngineV2KVQuantizationPolicy.parseSelection(environment[key] ?? "")) != .native
            }
            if key == EngineV2KVQuantizationPolicy.checkpointEnvironmentKey {
                // Checkpoint encoding never selects live kernels or RAM rates.
                return (try? EngineV2KVQuantizationPolicy.parseSelection(
                    environment[key] ?? "", purpose: .checkpoint)) == nil
            }
            if cacheIsolation != nil && DeadlineQualificationCacheIsolation.isPlumbingKey(key) { return false }
            return key.hasPrefix("MLX_") || key.hasPrefix("MTPLX_") || key.hasPrefix("QWEN_")
                || (key.hasPrefix("DARKBLOOM_") && !operationalKeys.contains(key))
        }
    }
}
