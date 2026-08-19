import Foundation
import Testing
@testable import DarkbloomApp

@Suite("doctor --json wire decoding + mapping")
struct DoctorJSONMappingTests {
    /// A payload exercising every mapping branch, shaped exactly like the
    /// CLI's schema-1 serializer (sorted keys, omitted `advice`/`fixes`).
    private static let sampleJSON = """
        {
          "schema": 1,
          "version": "0.8.5",
          "checks": [
            {"id": "runtime.daemon", "section": "runtime", "title": "daemon",
             "status": "pass", "detail": "running"},
            {"id": "trust.trust-level", "section": "trust", "title": "trust level",
             "status": "warn", "detail": "self_signed / online — not earning.",
             "advice": "run `darkbloom enroll`, then wait ~5 min for MDM verification."},
            {"id": "attestationKey.se-key-sign-test", "section": "attestationKey",
             "title": "se key sign test", "status": "fail",
             "detail": "missing keychain-access-groups entitlement.",
             "advice": "reinstall the official signed bundle (re-run the install script)"},
            {"id": "quantum-widget", "section": "quantum", "title": "quantum widget",
             "status": "flaky", "detail": "a future check this build has never heard of"}
          ],
          "fixes": [
            {"id": "fix-trust.trust-level", "check": "trust.trust-level",
             "title": "trust level",
             "detail": "run `darkbloom enroll`, then wait ~5 min for MDM verification.",
             "priority": "recommended"},
            {"id": "fix-attestationKey.se-key-sign-test", "check": "attestationKey.se-key-sign-test",
             "title": "se key sign test",
             "detail": "reinstall the official signed bundle (re-run the install script)",
             "priority": "urgent"}
          ],
          "verdict": {"status": "fail", "failures": 1, "warnings": 1}
        }
        """

    private func decodeSample() throws -> DoctorJSONReport {
        try JSONDecoder().decode(DoctorJSONReport.self, from: Data(Self.sampleJSON.utf8))
    }

    @Test func wireDecodesAllFields() throws {
        let payload = try decodeSample()
        #expect(payload.schema == 1)
        #expect(payload.version == "0.8.5")
        #expect(payload.checks.count == 4)
        #expect(payload.fixes?.count == 2)
        #expect(payload.verdict == DoctorJSONReport.Verdict(status: "fail", failures: 1, warnings: 1))

        let daemon = payload.checks[0]
        #expect(daemon.advice == nil) // omitted key decodes as nil
        #expect(payload.checks[3].status == "flaky") // unknown status stays raw
    }

    @Test func mappingConvertsStatusesSectionsAndFixes() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_784_330_000)
        let report = DiagnosticReport(doctor: try decodeSample(), generatedAt: generatedAt)

        #expect(report.generatedAt == generatedAt)
        #expect(report.checks.map(\.id) == [
            "runtime.daemon", "trust.trust-level",
            "attestationKey.se-key-sign-test", "quantum-widget",
        ])

        let daemon = report.checks[0]
        #expect(daemon.section == .runtime)
        #expect(daemon.severity == .passed)
        #expect(daemon.fix == nil)

        let trust = report.checks[1]
        #expect(trust.section == .trust)
        #expect(trust.severity == .warning)
        #expect(trust.title == "trust level") // CLI names show verbatim
        #expect(trust.fix?.id == "fix-trust.trust-level")
        #expect(trust.fix?.priority == .recommended)
        #expect(trust.fix?.action == .openEnrollment) // "enroll" keyword routes

        let seKey = report.checks[2]
        #expect(seKey.severity == .failure)
        #expect(seKey.fix?.priority == .urgent)
        #expect(seKey.fix?.action == .openSupport) // attestation-key fixes fall through

        let unknown = report.checks[3]
        #expect(unknown.section == .other) // forward-compat bucket
        #expect(unknown.severity == .warning) // unknown status → warning, not failure
        #expect(unknown.fix == nil) // no fix record and no advice → no card

        // Roll-up: one failure → blocked; the urgent fix sorts first.
        #expect(report.overallVerdict == .blocked)
        #expect(report.prioritizedFixes.map(\.id) == [
            "fix-attestationKey.se-key-sign-test", "fix-trust.trust-level",
        ])
    }

    @Test func adviceWithoutAFixRecordStillSurfacesACard() throws {
        let payload = DoctorJSONReport(
            schema: 1,
            version: "0.8.5",
            checks: [
                DoctorJSONReport.Check(
                    id: "runtime.daemon", section: "runtime", title: "daemon",
                    status: "warn", detail: "NOT running — run `darkbloom start`",
                    advice: "run `darkbloom start`, then re-run `darkbloom doctor`"
                ),
            ],
            fixes: nil,
            verdict: DoctorJSONReport.Verdict(status: "warn", failures: 0, warnings: 1)
        )

        let report = DiagnosticReport(doctor: payload)
        #expect(report.checks[0].fix?.id == "fix-runtime.daemon")
        #expect(report.checks[0].fix?.priority == .recommended)
        #expect(report.prioritizedFixes.count == 1)
    }

    @Test func fixActionRoutingCoversEverySectionClass() {
        let cases: [(DiagnosticSection, String, String, DiagnosticFixAction)] = [
            (.trust, "trust.trust-level", "`darkbloom update` first, then enroll again", .openEnrollment),
            (.runtime, "runtime.daemon", "`darkbloom stop && darkbloom start`", .restartProvider),
            (.runtime, "runtime.daemon", "restart the provider", .restartProvider),
            (.version, "version.provider", "`darkbloom update` to the latest build", .checkForUpdates),
            (.security, "sip", "boot into Recovery, run `csrutil enable`", .openRecoveryInstructions),
            (.connectivity, "coordinator", "confirm this Mac is online", .openNetworkSettings),
            (.billing, "billing.usage-gaps", "run `darkbloom report --dry-run`", .openSupport),
            (.traffic, "traffic.model-fit", "serve a model that fits this box's RAM", .openSupport),
        ]
        for (section, id, detail, expected) in cases {
            #expect(DiagnosticFixAction.route(forFixTargeting: id, section: section, detail: detail) == expected,
                    "section \(section) id \(id) should route to \(expected)")
        }
    }

    @Test func severityMappingTreatsUnknownStatusesAsWarnings() {
        #expect(DiagnosticSeverity(status: "pass") == .passed)
        #expect(DiagnosticSeverity(status: "warn") == .warning)
        #expect(DiagnosticSeverity(status: "fail") == .failure)
        #expect(DiagnosticSeverity(status: "whatever-comes-next") == .warning)
    }

    @Test func schemaTwoPayloadDecodesForTheRunnerToReject() throws {
        // The app tolerates forward fields but must REJECT forward schemas;
        // decoding here is fine — `ProcessDiagnosticsCLIRunner` does the
        // rejection. This pins the delegates of that contract.
        let json = """
            {"schema": 2, "version": "9.9", "checks": [], "verdict": {"status": "pass", "failures": 0, "warnings": 0}}
            """
        let payload = try JSONDecoder().decode(DoctorJSONReport.self, from: Data(json.utf8))
        #expect(payload.schema > DoctorJSONReport.supportedSchema)
    }
}
