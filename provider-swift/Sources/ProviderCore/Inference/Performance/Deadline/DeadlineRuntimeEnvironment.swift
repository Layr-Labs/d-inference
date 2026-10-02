/// Deadline bounds describe the qualification runner's scrubbed environment.
/// Unknown performance settings cannot borrow those bounds, even when their
/// values appear to select a default. Universal serving policy is separate.
enum DeadlineRuntimeEnvironment {
    /// These exact keys select credentials, control-plane state paths, or
    /// update checks; none changes inference configuration. Keep unknown
    /// DARKBLOOM keys fail-closed instead of guessing from their names.
    private static let operationalKeys: Set<String> = [
        "DARKBLOOM_AUTH_TOKEN_PATH",
        "DARKBLOOM_KEYCHAIN_ACCESS_GROUP",
        "DARKBLOOM_LOCAL_DIR",
        "DARKBLOOM_LOADED_MODELS_FILE",
        "DARKBLOOM_NO_UPDATE_CHECK",
        "DARKBLOOM_PID_FILE",
        "DARKBLOOM_STATE_FILE",
        "DARKBLOOM_WATCHDOG_STATE",
    ]

    static func permitsQualification(_ environment: [String: String],
        cacheIsolation: DeadlineQualificationCacheIsolation? = nil) -> Bool {
        if let cacheIsolation {
            do { try cacheIsolation.validate(environment: environment) }
            catch { return false }
        }
        return !environment.keys.contains { key in
            if cacheIsolation != nil && DeadlineQualificationCacheIsolation.isPlumbingKey(key) { return false }
            return key.hasPrefix("MLX_") || key.hasPrefix("MTPLX_") || key.hasPrefix("QWEN_")
                || (key.hasPrefix("DARKBLOOM_") && !operationalKeys.contains(key))
        }
    }
}
