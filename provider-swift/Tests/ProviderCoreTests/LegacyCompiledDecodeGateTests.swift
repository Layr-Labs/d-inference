// Copyright © 2026 Eigen Labs.
//
// LegacyCompiledDecodeGate — the provider-side opt-in gate over the
// mlx-swift-lm `DARKBLOOM_COMPILED_DECODE` env flag (library default ON;
// release posture OFF unless the operator opts in).

import Foundation
import Testing

@testable import ProviderCore

@Suite("legacy compiled decode gate")
struct LegacyCompiledDecodeGateTests {

    @Test("default posture: config false + env unset => force '0' (compiled decode OFF)")
    func defaultForcesOff() {
        #expect(
            LegacyCompiledDecodeGate.resolvedOverride(
                configEnabled: false, environment: [:]) == "0")
    }

    @Test("config opt-in: legacy_compiled_decode=true + env unset => untouched (library default ON)")
    func configOptInLeavesEnvUnset() {
        #expect(
            LegacyCompiledDecodeGate.resolvedOverride(
                configEnabled: true, environment: [:]) == nil)
    }

    @Test("explicit env always wins, both directions")
    func explicitEnvWins() {
        // Operator forced it ON; config default false must not clobber it.
        #expect(
            LegacyCompiledDecodeGate.resolvedOverride(
                configEnabled: false,
                environment: ["DARKBLOOM_COMPILED_DECODE": "1"]) == nil)
        // Operator forced it OFF; config opt-in must not clobber it.
        #expect(
            LegacyCompiledDecodeGate.resolvedOverride(
                configEnabled: true,
                environment: ["DARKBLOOM_COMPILED_DECODE": "0"]) == nil)
        // Empty string counts as unset by the GATE (an empty export is not
        // an operator decision), so it forces "0". Note the library itself
        // would treat a set-but-empty var as "not in the off-set" (ON) —
        // stomping it to "0" here keeps the release posture deterministic.
        #expect(
            LegacyCompiledDecodeGate.resolvedOverride(
                configEnabled: false,
                environment: ["DARKBLOOM_COMPILED_DECODE": ""]) == "0")
    }

    @Test("apply() writes the real environment so the library gate latches OFF")
    func applyWritesProcessEnvironment() {
        // Snapshot + restore: the suite must not leak env state into other
        // tests in this shared process.
        let key = LegacyCompiledDecodeGate.envKey
        let prior = ProcessInfo.processInfo.environment[key]
        defer {
            if let prior {
                setenv(key, prior, 1)
            } else {
                unsetenv(key)
            }
        }

        unsetenv(key)
        let wrote = LegacyCompiledDecodeGate.apply(
            configEnabled: false, environment: [:])
        #expect(wrote)
        // setenv must be visible through ProcessInfo (what the library's
        // `CompiledDecode.isEnabled` static reads on first access).
        #expect(ProcessInfo.processInfo.environment[key] == "0")

        // Config opt-in: no write.
        unsetenv(key)
        let wroteOptIn = LegacyCompiledDecodeGate.apply(
            configEnabled: true, environment: [:])
        #expect(!wroteOptIn)
        #expect(ProcessInfo.processInfo.environment[key] == nil)
    }

    @Test("backend config decodes legacy_compiled_decode (default false)")
    func backendConfigKey() throws {
        let decoder = JSONDecoder()
        let on = try decoder.decode(
            BackendSettings.self,
            from: Data(#"{"legacy_compiled_decode": true}"#.utf8)
        )
        #expect(on.legacyCompiledDecode)
        let absent = try decoder.decode(
            BackendSettings.self,
            from: Data(#"{}"#.utf8)
        )
        #expect(!absent.legacyCompiledDecode)
        #expect(!BackendSettings().legacyCompiledDecode)
    }
}
