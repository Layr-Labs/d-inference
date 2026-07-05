// Copyright © 2026 Eigen Labs.
//
// LegacyCompiledDecodeGate — makes the LEGACY engine's compiled decode
// OPT-IN at the provider level.
//
// The mlx-swift-lm library ships `CompiledDecode.isEnabled` default-ON
// (env `DARKBLOOM_COMPILED_DECODE`, absent ⇒ enabled). Shipping that
// default would silently re-arm the exact code path v0.6.30 rolled back
// for prod Gemma: compile-on-first-dispatch cold start plus the known
// B=1 window-straddle divergence. Release behavior must stay identical
// to current prod (v0.6.30); single-stream speed comes from the v2
// engine canary instead.
//
// Resolution order (first match wins):
//   1. env `DARKBLOOM_COMPILED_DECODE` explicitly set — the operator's
//      per-box word is absolute; the gate never touches it.
//   2. config `legacy_compiled_decode = true` under `[backend]` — leave
//      the env unset so the library default (ON) applies.
//   3. default — force `DARKBLOOM_COMPILED_DECODE=0` into the process
//      environment so the library latches compiled decode OFF.
//
// MUST run before any engine/model code: `CompiledDecode.isEnabled` is a
// `static let`, latched on first access. Both serve entry points
// (`ProviderLoop.run()` and `StandaloneServer.start()`) apply the gate
// as their first action. (`setenv` is reflected by
// `ProcessInfo.processInfo.environment` on Darwin — verified in tests.)

import Foundation

public enum LegacyCompiledDecodeGate {
    /// The env var the mlx-swift-lm `CompiledDecode` gate reads.
    public static let envKey = "DARKBLOOM_COMPILED_DECODE"

    /// Pure decision: the value to force into the environment, or nil to
    /// leave it untouched. Unit-testable without process-env side effects.
    ///
    ///   * env set (non-empty) → nil (operator override wins, either way)
    ///   * config enabled      → nil (library default ON applies)
    ///   * otherwise           → "0" (disable legacy compiled decode)
    static func resolvedOverride(
        configEnabled: Bool,
        environment: [String: String]
    ) -> String? {
        if let raw = environment[envKey], !raw.isEmpty {
            return nil
        }
        return configEnabled ? nil : "0"
    }

    /// Apply the gate to the real process environment. Returns true when
    /// the env var was written (i.e. compiled decode was forced off).
    @discardableResult
    public static func apply(
        configEnabled: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard
            let value = resolvedOverride(
                configEnabled: configEnabled, environment: environment)
        else { return false }
        setenv(envKey, value, 1)
        return true
    }
}
