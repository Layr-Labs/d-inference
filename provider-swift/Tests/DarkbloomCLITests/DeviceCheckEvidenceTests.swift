import Foundation
import Testing

@testable import darkbloom

@Suite("devicecheckd evidence collector")
struct DeviceCheckEvidenceTests {
    /// Shape of `log show --style ndjson`, including the line an operator
    /// captured when App Attest keys died at a provider restart.
    private let sample = """
    {"timestamp":"2026-09-24 03:12:44.120981-0700","messageType":"Default","category":"attest","subsystem":"com.apple.devicecheck","processImagePath":"/usr/libexec/devicecheckd","eventMessage":"Should fetch CD hash { source=entitlement }"}
    {"timestamp":"2026-09-24 03:12:44.131442-0700","messageType":"Error","category":"attest","subsystem":"com.apple.devicecheck","processImagePath":"/usr/libexec/devicecheckd","eventMessage":"SecKeyCreateSignature failed: Error Domain=CryptoTokenKit Code=-3 \\"unable to sign digest\\" UserInfo={NSDebugDescription=unable to sign digest, AKSError=-536362989}"}
    {"timestamp":"2026-09-24 03:12:44.2-0700","messageType":"Default","category":"attest","eventMessage":"Attesting key 3xAMPLEk3y1D for /Users/alice/.darkbloom/Darkbloom.app"}
    {"timestamp":"2026-09-24 03:13:01.0-0700","messageType":"Error","category":"attest\\u0000<script>","eventMessage":"attestKey failed invalidKey for /Users/alice/secret"}
    not json at all
    {"timestamp":"2026-09-24 03:14:00.0-0700","messageType":"Fault","eventMessage":"unknownSystemFailure"}
    """

    @Test func extractsOnlyClosedPatternsAndCodesFromTheCapturedLine() throws {
        let events = DeviceCheckEvidence.extract(ndjson: Data(sample.utf8))
        #expect(events.count == 4, "the key-id/path line without a pattern and the non-JSON line are dropped")
        let signature = try #require(events.first { $0.messageType == "Error" && $0.category == "attest" })
        #expect(signature.matches == [
            .init(pattern: .secKeyCreateSignatureFailed, code: nil),
            .init(pattern: .cryptoTokenKitCode, code: -3),
            .init(pattern: .aksError, code: -536_362_989),
        ])
        #expect(events.first?.matches == [.init(pattern: .shouldFetchCDHash, code: nil)])
        let invalid = try #require(events.first { $0.matches.contains { $0.pattern == .invalidKey } })
        #expect(invalid.category == nil, "a category outside the closed character set is dropped")
        #expect(DeviceCheckEvidence.showsKeyLoss(events))

        let uploaded = String(decoding: DeviceCheckEvidence.reportLines(.collected(events)), as: UTF8.self)
        for secret in ["alice", "3xAMPLEk3y1D", "unable to sign digest", "/usr/libexec", "<script>"] {
            #expect(!uploaded.contains(secret), "leaked \(secret)")
        }
        #expect(uploaded.contains("-536362989"))
        #expect(DeviceCheckEvidence.summary(events).contains("CryptoTokenKit Code ×1 (-3)"))
    }

    @Test func accessDeniedIsReportedWithAdminGuidanceNotAFailure() {
        let outcome = DeviceCheckEvidence.collect { _ in
            (77, Data(), "log: Could not open local log store: Operation not permitted")
        }
        #expect(outcome == .accessDenied)
        let diagnostic = DeviceCheckEvidence.doctorDiagnostic(outcome)
        #expect(diagnostic.level == .warn)
        #expect(diagnostic.fix?.contains("administrator account") == true)
        #expect(String(decoding: DeviceCheckEvidence.reportLines(outcome), as: UTF8.self).contains("access_denied"))
    }

    @Test func runnerFailureDegradesToUnavailable() {
        struct Boom: Error {}
        #expect(DeviceCheckEvidence.collect { _ in throw Boom() } != .accessDenied)
        if case .failed = DeviceCheckEvidence.collect(runner: { _ in (1, Data(), "") }) {} else { Issue.record("expected .failed") }
        #expect(DeviceCheckEvidence.collect { _ in (0, Data(), "") } == .collected([]))
    }

    @Test func queryIsScopedToDeviceCheckForTwoHours() {
        #expect(DeviceCheckEvidence.arguments() == [
            "show", "--last", "2h", "--style", "ndjson",
            "--predicate", #"process == "devicecheckd" OR subsystem == "com.apple.appattest""#,
        ])
    }
}
