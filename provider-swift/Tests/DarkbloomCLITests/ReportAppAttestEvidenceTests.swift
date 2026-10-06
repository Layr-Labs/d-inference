import Foundation
import ProviderAppAttest
import ProviderCore
import Testing

@testable import darkbloom

@Suite("Report App Attest evidence")
struct ReportAppAttestEvidenceTests {
    private func writeToken(_ token: String, at path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try token.write(to: path, atomically: true, encoding: .utf8)
    }

    @Test(arguments: [".config/eigeninference/auth_token", "Library/Application Support/eigeninference/auth_token"])
    func sudoReportIgnoresRetiredCredentialPaths(retiredPath: String) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("report-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let retired = home.appendingPathComponent(retiredPath)
        try writeToken("retired-test-token\n", at: retired)

        #expect(ReportAppAttestEvidence.authToken(invokingHome: home, environment: [:]) == nil)
        #expect(try String(contentsOf: retired, encoding: .utf8) == "retired-test-token\n")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".darkbloom").path))
    }

    @Test func sudoReportReadsTheCanonicalCredential() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("report-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let canonical = home.appendingPathComponent(".darkbloom/auth_token")
        try writeToken("canonical-test-token\n", at: canonical)

        #expect(ReportAppAttestEvidence.authToken(invokingHome: home, environment: [:]) == "canonical-test-token")
        #expect(try String(contentsOf: canonical, encoding: .utf8) == "canonical-test-token\n")
    }

    @Test func sudoReportLeavesAnAbsentTokenAbsent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("report-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        #expect(ReportAppAttestEvidence.authToken(invokingHome: home, environment: [:]) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    @Test func sudoReportHonorsAnExplicitOverrideWithoutFallback() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("report-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let canonical = home.appendingPathComponent(".darkbloom/auth_token")
        let override = home.appendingPathComponent("operator-token")
        try writeToken("canonical-test-token\n", at: canonical)
        try writeToken("override-test-token\n", at: override)
        let environment = ["DARKBLOOM_AUTH_TOKEN_PATH": override.path]

        #expect(ReportAppAttestEvidence.authToken(invokingHome: home, environment: environment) == "override-test-token")
        try FileManager.default.removeItem(at: override)
        #expect(ReportAppAttestEvidence.authToken(invokingHome: home, environment: environment) == nil)
        #expect(!FileManager.default.fileExists(atPath: override.path))
        #expect(try String(contentsOf: canonical, encoding: .utf8) == "canonical-test-token\n")
    }

    @Test func snapshotUsesInvocationAgesWithoutRewritingObservationMetadata() throws {
        let status = AppAttestLocalStatus(
            observedAt: 120, launchSession: .unknown, operationStalledSeconds: 90,
            keyHistory: .init(lastGenerationAgeSeconds: 50, keyAgeSeconds: 20),
            keyHistoryObservedAt: 100)
        let state = DaemonState(pid: 42, version: "test", writtenAt: 150, startedAt: 10, appAttest: status)
        let data = ReportAppAttestEvidence.snapshotLine(
            state: state, pushHistory: APNsPushHistory(), now: Date(timeIntervalSince1970: 200))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let appAttest = try #require(object["app_attest"] as? [String: Any])
        let history = try #require(appAttest["key_history"] as? [String: Any])

        #expect(appAttest["observed_at"] as? Double == 120)
        #expect(appAttest["operation_stalled_seconds"] as? Int == 90)
        #expect(appAttest["key_history_observed_at"] as? Double == 200)
        #expect(history["key_age_seconds"] as? Int == 120)
        #expect(history["last_generation_age_seconds"] as? Int == 150)
        #expect(history["last_success_age_seconds"] == nil)
        #expect(state.appAttest == status)
    }
}
