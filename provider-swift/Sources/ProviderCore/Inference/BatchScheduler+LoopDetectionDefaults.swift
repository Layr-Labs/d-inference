// Copyright © 2026 Eigen Labs.
//
// Default-on n-gram tail-loop detection for Gemma-4 requests.
//
// mlx-swift-lm's `TailLoopDetector` / `SamplingParams.loopDetectionMaxPatternSize`
// is a generic, opt-in library primitive -- disabled by default there, since
// the library has no way to know which model families it's safe to force on
// for. Gemma 4 specifically is known to hit a degenerate repetition-collapse
// bug (a reference MLX runtime, mlxcel, defaults its own n-gram loop breaker
// on for exactly this model family after validating it there). This file
// makes the analogous provider-side decision -- default loop detection ON
// for Gemma-4 requests -- mirroring the model-family gate already used by
// `BatchScheduler+B1FastPath.swift`.

import Foundation

extension BatchScheduler {

    // MARK: - Env gate

    /// Whether Gemma-4 default loop detection is enabled. **Default ON.** Opt
    /// OUT with `DARKBLOOM_GEMMA_LOOP_DETECTION` set to `"0"`/`"false"`/`"no"`/
    /// `"off"`, e.g. to disable it without a code deploy if it ever needs
    /// disabling. Read per-call (cheap), same pattern as
    /// `b1GreedyFastPathEnabled()`.
    static func gemmaLoopDetectionEnabled() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let off: Set<String> = ["0", "false", "no", "off"]
        if let v = env["DARKBLOOM_GEMMA_LOOP_DETECTION"], off.contains(v.lowercased()) {
            return false
        }
        return true
    }

    // MARK: - Defaults

    /// Loop-detection parameters to apply for `modelId`, or `nil` if this
    /// model family shouldn't get a default. Pure function -- no actor state
    /// -- so it's fully unit-testable without a loaded model, mirroring
    /// `b1FastPathEligiblePure`.
    ///
    /// Only Gemma-4 is covered today: it's the one family with a known,
    /// specific repetition-collapse issue (see mlxcel's own default-on scope
    /// for the same bug). Every other model family is unaffected until it has
    /// its own validated case for a default -- this is intentionally narrow,
    /// not a blanket "enable for everything" switch.
    static func loopDetectionDefaults(
        modelId: String,
        enabled: Bool
    ) -> (maxPatternSize: Int, minCount: Int)? {
        guard enabled else { return nil }
        guard modelId.lowercased().contains("gemma") else { return nil }
        return (maxPatternSize: 64, minCount: 3)
    }
}
