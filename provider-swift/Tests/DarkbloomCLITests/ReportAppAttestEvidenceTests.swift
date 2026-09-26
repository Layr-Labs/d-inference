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
    func sudoReportReadsLegacyCredentialsWithoutMigration(legacyPath: String) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("report-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = home.appendingPathComponent(legacyPath)
        try writeToken("legacy-test-token\n", at: legacy)

        #expect(ReportAppAttestEvidence.authToken(invokingHome: home, environment: [:]) == "legacy-test-token")
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "legacy-test-token\n")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".darkbloom").path))
    }

    @Test func sudoReportPreservesCanonicalAndLegacyPrecedence() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("report-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let canonical = home.appendingPathComponent(".darkbloom/auth_token")
        let configLegacy = home.appendingPathComponent(".config/eigeninference/auth_token")
        let supportLegacy = home.appendingPathComponent("Library/Application Support/eigeninference/auth_token")
        try writeToken("canonical-test-token\n", at: canonical)
        try writeToken("config-test-token\n", at: configLegacy)
        try writeToken("support-test-token\n", at: supportLegacy)

        #expect(ReportAppAttestEvidence.authToken(invokingHome: home, environment: [:]) == "canonical-test-token")
        try FileManager.default.removeItem(at: canonical)
        #expect(ReportAppAttestEvidence.authToken(invokingHome: home, environment: [:]) == "config-test-token")
        #expect(!FileManager.default.fileExists(atPath: canonical.path))
        try FileManager.default.removeItem(at: configLegacy)
        #expect(ReportAppAttestEvidence.authToken(invokingHome: home, environment: [:]) == "support-test-token")
        #expect(!FileManager.default.fileExists(atPath: canonical.path))
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
        let legacy = home.appendingPathComponent(".config/eigeninference/auth_token")
        let override = home.appendingPathComponent("operator-token")
        try writeToken("canonical-test-token\n", at: canonical)
        try writeToken("legacy-test-token\n", at: legacy)
        try writeToken("override-test-token\n", at: override)
        let environment = ["DARKBLOOM_AUTH_TOKEN_PATH": override.path]

        #expect(ReportAppAttestEvidence.authToken(invokingHome: home, environment: environment) == "override-test-token")
        try FileManager.default.removeItem(at: override)
        #expect(ReportAppAttestEvidence.authToken(invokingHome: home, environment: environment) == nil)
        #expect(!FileManager.default.fileExists(atPath: override.path))
        #expect(try String(contentsOf: canonical, encoding: .utf8) == "canonical-test-token\n")
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "legacy-test-token\n")
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
