import Foundation
import Testing
@testable import ProviderCore

@Suite("TelemetryClient flush + panic hook")
struct TelemetryClientTests {

    @Test("emit before configure is silently dropped")
    func emitBeforeConfigureIsDropped() async {
        // Use a fresh-looking event; we can't reset the global singleton's
        // state, so this just asserts no crash. The behavioural contract is
        // exercised more directly in the integration tests.
        let event = TelemetryEvent(
            source: .provider,
            severity: .info,
            kind: .log,
            message: "before configure"
        )
        TelemetryClient.shared.emit(event)
    }

    @Test("ingestEndpoint normalizes coordinator URLs")
    func ingestEndpointNormalization() {
        let cases: [(String, String)] = [
            // wss → https, /ws/provider stripped
            ("wss://api.darkbloom.dev/ws/provider", "https://api.darkbloom.dev/v1/telemetry/events"),
            // ws → http
            ("ws://localhost:8080/ws/provider", "http://localhost:8080/v1/telemetry/events"),
            // bare https stays https
            ("https://api.dev.darkbloom.xyz", "https://api.dev.darkbloom.xyz/v1/telemetry/events"),
            // trailing slash stripped
            ("https://api.dev.darkbloom.xyz/", "https://api.dev.darkbloom.xyz/v1/telemetry/events"),
        ]
        for (input, expected) in cases {
            #expect(TelemetryClient.ingestEndpoint(from: input) == expected,
                    "input '\(input)' produced wrong endpoint")
        }
    }

    @Test("PanicHook.install is idempotent")
    func panicHookInstallIdempotent() {
        // Calling twice must not throw, leak signal handlers, or change
        // behaviour. We don't actually trigger a signal -- doing so in a
        // test would terminate the test runner.
        PanicHook.install()
        PanicHook.install()
    }
}
