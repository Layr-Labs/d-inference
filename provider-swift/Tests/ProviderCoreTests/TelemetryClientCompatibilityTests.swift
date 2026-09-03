import Testing
import ProviderCore

@Suite("TelemetryClient compatibility")
struct TelemetryClientCompatibilityTests {
    @Test("ingestEndpoint preserves historical URL normalization")
    func ingestEndpointNormalization() {
        let cases: [(input: String, expected: String)] = [
            (
                "wss://api.darkbloom.dev/ws/provider",
                "https://api.darkbloom.dev/v1/telemetry/events"
            ),
            (
                "ws://localhost:8080/ws/provider/",
                "http://localhost:8080/v1/telemetry/events"
            ),
            (
                "https://api.dev.darkbloom.xyz",
                "https://api.dev.darkbloom.xyz/v1/telemetry/events"
            ),
            (
                "https://api.dev.darkbloom.xyz///",
                "https://api.dev.darkbloom.xyz/v1/telemetry/events"
            ),
        ]

        for testCase in cases {
            #expect(
                TelemetryClient.ingestEndpoint(from: testCase.input) == testCase.expected,
                "input '\(testCase.input)' produced the wrong compatibility endpoint"
            )
        }
    }
}
