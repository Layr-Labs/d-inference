/// TelemetryReporterTests — guards the Swift mirror of the telemetry wire
/// protocol against drift from the Go canonical definition.

import Testing
import Foundation
@testable import Darkbloom

@Suite("TelemetryReporter")
struct TelemetryReporterTests {

    @Test("enum raw values match Go wire format")
    func enumRawValues() {
        #expect(TelemetrySeverity.debug.rawValue == "debug")
        #expect(TelemetrySeverity.info.rawValue == "info")
        #expect(TelemetrySeverity.warn.rawValue == "warn")
        #expect(TelemetrySeverity.error.rawValue == "error")
        #expect(TelemetrySeverity.fatal.rawValue == "fatal")

        #expect(TelemetryKind.panic.rawValue == "panic")
        #expect(TelemetryKind.httpError.rawValue == "http_error")
        #expect(TelemetryKind.backendCrash.rawValue == "backend_crash")
        #expect(TelemetryKind.attestationFailure.rawValue == "attestation_failure")
        #expect(TelemetryKind.inferenceError.rawValue == "inference_error")
        #expect(TelemetryKind.runtimeMismatch.rawValue == "runtime_mismatch")
        #expect(TelemetryKind.connectivity.rawValue == "connectivity")
        #expect(TelemetryKind.log.rawValue == "log")
        #expect(TelemetryKind.custom.rawValue == "custom")
    }

    @Test("wss URL converts to https base")
    func wssToHttps() {
        let base = AppDelegate.httpsBase(from: "wss://api.darkbloom.dev/ws/provider")
        #expect(base?.absoluteString == "https://api.darkbloom.dev")
    }

    @Test("ws URL converts to http base")
    func wsToHttp() {
        let base = AppDelegate.httpsBase(from: "ws://localhost:8080/ws/provider")
        #expect(base?.absoluteString == "http://localhost:8080")
    }

    @Test("reporter instance has a stable machine id across accesses")
    func machineIDStable() {
        let a = TelemetryReporter.shared.machineID
        let b = TelemetryReporter.shared.machineID
        #expect(!a.isEmpty)
        #expect(a == b)
    }

    @Test("reporter has a per-launch session id")
    func sessionIDPresent() {
        #expect(!TelemetryReporter.shared.sessionID.isEmpty)
    }
}
