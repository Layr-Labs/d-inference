// Copyright © 2026 Eigen Labs.
import Foundation
import MLXLMCommon

extension EngineV2Factory {
    /// The loop settings both native MiMo engines (contiguous and paged) run with.
    ///
    /// A step longer than `stepTimeout` makes the SDK watchdog seal a native
    /// engine for good (`fail(.stepWatchdog)` is write-once), even when the step
    /// then finishes. A healthy MiMo prefill step grows with its context: on an
    /// M5 Ultra it reached 11.8 s at about 129k tokens, and M3 Ultras prefill
    /// MiMo three to four times slower, past the SDK's 30 s default. So a native
    /// MiMo step may run as long as the engine's prefill progress lease, the
    /// point where the engine already treats a prefill as stalled. A step that
    /// never returns is still caught, two minutes in instead of 30 s.
    static func nativeMiMoLoopConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CBv2EngineLoopConfig {
        var config = CBv2EngineLoopConfig(
            useLegacyRequestTimeout: legacyRequestTimeoutEnabled(environment: environment))
        config.stepTimeout = max(config.stepTimeout, config.prefillProgressLease)
        return config
    }
}
