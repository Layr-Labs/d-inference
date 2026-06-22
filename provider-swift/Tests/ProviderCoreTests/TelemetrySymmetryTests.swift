import Foundation
import Testing
@testable import ProviderCore

/// Swift mirror of `coordinator/protocol/telemetry_symmetry_test.go`.
///
/// Pins the telemetry wire shape (enum casing, snake_case keys, optional-field
/// omission) and the `TelemetryKind` set/count so the Go canonical, this Swift
/// mirror, and `console-ui/src/lib/telemetry-types.ts` cannot drift silently.
@Suite("Telemetry wire symmetry")
struct TelemetrySymmetryTests {

    /// Mirror of Go `TestTelemetryJSONSymmetry`: the canonical event encodes the
    /// exact enum strings and omits nil optionals (Go uses `omitempty`; Swift's
    /// synthesized `Codable` uses `encodeIfPresent`).
    @Test func telemetryEventJSONSymmetry() throws {
        var event = TelemetryEvent(
            source: .provider,
            severity: .error,
            kind: .backendCrash,
            message: "hi"
        )
        // Match the Go fixture's deterministic, present fields.
        event.id = "00000000-0000-0000-0000-000000000001"
        event.timestamp = "2026-04-16T00:00:00Z"
        event.version = "0.3.10"
        event.sessionId = "abc"
        // Leave these nil to assert omission (as the Go fixture does).
        event.machineId = nil
        event.accountId = nil
        event.requestId = nil
        event.stack = nil
        event.fields = nil

        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)

        // Enum serialization contract.
        for want in [
            #""source":"provider""#,
            #""severity":"error""#,
            #""kind":"backend_crash""#,
        ] {
            #expect(json.contains(want), "missing \(want) in \(json)")
        }

        // snake_case key contract for a present optional.
        #expect(json.contains(#""session_id":"abc""#), "missing snake_case session_id in \(json)")

        // Optional-field omission contract (matches the Go omitempty mirror).
        for forbidden in [
            #""machine_id":"#,
            #""account_id":"#,
            #""request_id":"#,
            #""stack":"#,
            #""fields":"#,
        ] {
            #expect(!json.contains(forbidden), "optional \(forbidden) should be omitted in \(json)")
        }
    }

    /// Mirror of Go `TestTelemetryKindsMatch`: guards the kind raw-value set and
    /// count against accidental typos / additions across layers. `allCases` is
    /// the Swift equivalent of Go's `KnownKinds()`.
    @Test func telemetryKindsMatch() {
        let want: Set<String> = [
            "panic", "http_error", "protocol_error",
            "backend_crash", "attestation_failure",
            "inference_error", "runtime_mismatch",
            "connectivity", "oom", "log", "custom",
        ]
        let got = Set(TelemetryKind.allCases.map(\.rawValue))
        #expect(got == want, "kind raw-value set mismatch: got \(got)")
        #expect(
            TelemetryKind.allCases.count == want.count,
            "kind count mismatch: got \(TelemetryKind.allCases.count) want \(want.count)"
        )
    }

    /// Source and severity raw values are the exact lowercase strings the
    /// coordinator expects (a mismatch coerces to "custom" server-side).
    @Test func sourceAndSeverityRawValues() {
        #expect(TelemetrySource.coordinator.rawValue == "coordinator")
        #expect(TelemetrySource.provider.rawValue == "provider")
        #expect(TelemetrySource.app.rawValue == "app")
        #expect(TelemetrySource.console.rawValue == "console")
        #expect(TelemetrySource.bridge.rawValue == "bridge")

        #expect(TelemetrySeverity.debug.rawValue == "debug")
        #expect(TelemetrySeverity.info.rawValue == "info")
        #expect(TelemetrySeverity.warn.rawValue == "warn")
        #expect(TelemetrySeverity.error.rawValue == "error")
        #expect(TelemetrySeverity.fatal.rawValue == "fatal")
    }
}
