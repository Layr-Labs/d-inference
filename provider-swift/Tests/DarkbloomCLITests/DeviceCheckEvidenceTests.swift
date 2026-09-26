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

        let uploaded = String(decoding: DeviceCheckEvidence.reportLines(.collected(events)), as: UTF8.self)
        for secret in ["alice", "3xAMPLEk3y1D", "unable to sign digest", "/usr/libexec", "<script>"] {
            #expect(!uploaded.contains(secret), "leaked \(secret)")
        }
        #expect(uploaded.contains("-536362989"))
    }

    @Test func mixedApplicationRowsRemainUnattributedAndPrivate() throws {
        let rows = """
        {"timestamp":"2026-09-24 03:12:44.1-0700","category":"attest","messageType":"Error","eventMessage":"SecKeyCreateSignature failed: Error Domain=CryptoTokenKit Code=-3 for com.example.unrelated /Applications/Unrelated.app key=private-key"}
        {"timestamp":"2026-09-24 03:12:45.1-0700","category":"attest","messageType":"Error","eventMessage":"invalidKey for dev.darkbloom.provider /Users/alice/Darkbloom.app key=another-private-key"}
        """
        let events = DeviceCheckEvidence.extract(ndjson: Data(rows.utf8))
        #expect(events.map(\.matches) == [
            [.init(pattern: .secKeyCreateSignatureFailed, code: nil), .init(pattern: .cryptoTokenKitCode, code: -3)],
            [.init(pattern: .invalidKey, code: nil)],
        ])
        let data = DeviceCheckEvidence.reportLines(.collected(events))
        let lines = try data.split(separator: UInt8(ascii: "\n")).map {
            try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        #expect(lines.count == 2)
        for line in lines {
            #expect(Set(line.keys) == ["source", "scope", "attribution", "status", "event"])
            #expect(line["scope"] as? String == "device_wide")
            #expect(line["attribution"] as? String == "not_attributable_to_darkbloom")
            #expect(line["status"] as? String == "match")
            let event = try #require(line["event"] as? [String: Any])
            #expect(Set(event.keys) == ["timestamp", "category", "message_type", "matches"])
        }
        let uploaded = String(decoding: data, as: UTF8.self)
        for secret in ["com.example.unrelated", "dev.darkbloom.provider", "Unrelated.app", "Darkbloom.app", "alice", "private-key"] {
            #expect(!uploaded.contains(secret))
        }
        let unrelatedKeyFailure = DeviceCheckEvidence.doctorDiagnostic(.collected(Array(events.prefix(1))))
        let otherFailure = DeviceCheckEvidence.doctorDiagnostic(.collected(Array(events.suffix(1))))
        #expect(unrelatedKeyFailure.level == .warn)
        #expect(unrelatedKeyFailure.level == otherFailure.level)
        #expect(unrelatedKeyFailure.fix == otherFailure.fix)
    }

    @Test func unavailableAndEmptyEvidenceRetainDeviceWideScope() throws {
        let outcomes: [DeviceCheckEvidence.Outcome] = [.collected([]), .accessDenied, .failed("private failure detail")]
        for outcome in outcomes {
            let data = DeviceCheckEvidence.reportLines(outcome)
            let line = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(line.keys) == ["source", "scope", "attribution", "status"])
            #expect(line["scope"] as? String == "device_wide")
            #expect(line["attribution"] as? String == "not_attributable_to_darkbloom")
            #expect(!String(decoding: data, as: UTF8.self).contains("private failure detail"))
        }
    }

    @Test func accessDeniedIsReportedWithAdminGuidanceNotAFailure() {
        let outcome = DeviceCheckEvidence.collect { _ in
            (77, Data(), "log: Could not open local log store: Operation not permitted")
        }
        #expect(outcome == .accessDenied)
        let diagnostic = DeviceCheckEvidence.doctorDiagnostic(outcome)
        #expect(diagnostic.level == .warn)
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

@Suite("sudo report config")
struct ReportConfigPathTests {
    @Test func sudoReportReadsTheInvokingUsersConfig() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("report-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let appSupport = home.appendingPathComponent("Library/Application Support/darkbloom")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let legacy = appSupport.appendingPathComponent("provider.toml")
        try Data("[provider]\n".utf8).write(to: legacy)
        #expect(ReportAppAttestEvidence.configPath(explicit: nil, invokingHome: home) == legacy.path)
        let xdg = home.appendingPathComponent(".config/darkbloom/provider.toml")
        try FileManager.default.createDirectory(at: xdg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[provider]\n".utf8).write(to: xdg)
        #expect(ReportAppAttestEvidence.configPath(explicit: nil, invokingHome: home) == xdg.path)
        #expect(ReportAppAttestEvidence.configPath(explicit: "/tmp/explicit.toml", invokingHome: home) == "/tmp/explicit.toml")
        #expect(ReportAppAttestEvidence.configPath(explicit: nil, invokingHome: nil) == nil)
    }

    @Test func withoutSudoNothingIsAdopted() {
        // Tests never run as root, so the invoking-user switch cannot engage.
        #expect(ReportAppAttestEvidence.adoptInvokingUserFiles(environment: ["SUDO_USER": "someone"]) == nil)
    }
}
