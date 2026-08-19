import Foundation
import ProviderCore
import Testing
@testable import darkbloom

@Suite("doctor --json report")
struct DoctorJSONReportTests {
    /// Byte-stable golden pin for the schema-1 wire document: key order,
    /// optional-field omission, enum raw values, and the top-level shape.
    /// The Darkbloom app decodes this exact serialization.
    @Test func goldenEncodingIsByteStable() throws {
        let report = DoctorReport(
            version: "0.8.5",
            checks: [
                DoctorReport.Check(
                    id: "runtime.daemon",
                    section: "runtime",
                    title: "daemon",
                    status: .pass,
                    detail: "running"
                ),
                DoctorReport.Check(
                    id: "trust.trust-level",
                    section: "trust",
                    title: "trust level",
                    status: .warn,
                    detail: "self_signed / online — not earning.",
                    advice: "run `darkbloom enroll`"
                ),
            ],
            fixes: [
                DoctorReport.Fix(
                    id: "fix-trust.trust-level",
                    check: "trust.trust-level",
                    title: "trust level",
                    detail: "run `darkbloom enroll`",
                    priority: .recommended
                ),
            ],
            verdict: DoctorReport.Verdict(status: .warn, failures: 0, warnings: 1)
        )

        let rendered = try DoctorJSONReportRenderer.render(report)
        #expect(rendered == """
            {"checks":[{"detail":"running","id":"runtime.daemon","section":"runtime","status":"pass","title":"daemon"},{"advice":"run `darkbloom enroll`","detail":"self_signed / online — not earning.","id":"trust.trust-level","section":"trust","status":"warn","title":"trust level"}],"fixes":[{"check":"trust.trust-level","detail":"run `darkbloom enroll`","id":"fix-trust.trust-level","priority":"recommended","title":"trust level"}],"schema":1,"verdict":{"failures":0,"status":"warn","warnings":1},"version":"0.8.5"}
            """)

        // And it round-trips through a plain decoder (the app's path).
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: Data(rendered.utf8))
        #expect(decoded == report)
    }

    @Test func fixesAndVerdictOmitQuietlyWhenHealthy() throws {
        let checks = [
            DoctorJSONReportBuilder.checks(forDiagnosis: [
                Diagnostic(section: .billing, name: "usage reporting", level: .pass,
                           message: "412 requests reported."),
            ]),
            DoctorJSONReportBuilder.checks(forDetailedChecks: [
                DoctorCheck(name: "metal gpu", status: .pass,
                            detail: "Apple M4 Max, 56 GB working set",
                            section: DiagnosticSection.hardware.wireID),
            ]),
        ].flatMap { $0 }

        #expect(DoctorJSONReportBuilder.fixes(for: checks) == nil)
        #expect(DoctorJSONReportBuilder.verdict(for: checks)
            == DoctorReport.Verdict(status: .pass, failures: 0, warnings: 0))
    }

    @Test func fixesDeriveFromAdviceWithUrgentFirstStableOrder() {
        let diagnosis = [
            Diagnostic(section: .trust, name: "trust level", level: .warn,
                       message: "not earning.", fix: "run `darkbloom enroll`"),
            Diagnostic(section: .attestationKey, name: "se key sign test", level: .fail,
                       message: "key cannot sign.", fix: "log in at the console"),
        ]
        let checks = DoctorJSONReportBuilder.checks(forDiagnosis: diagnosis)
        let fixes = DoctorJSONReportBuilder.fixes(for: checks)

        #expect(fixes?.map(\.id) == ["fix-attestationKey.se-key-sign-test", "fix-trust.trust-level"])
        #expect(fixes?[0].priority == .urgent)
        #expect(fixes?[0].check == "attestationKey.se-key-sign-test")
        #expect(fixes?[0].detail == "log in at the console")
        #expect(fixes?[1].priority == .recommended)

        // The check keeps the advice too: per-check context, prioritized
        // cards — one source, two presentations.
        #expect(checks[0].advice == "run `darkbloom enroll`")
    }

    @Test func checkIDsAndSectionsAreStable() {
        let diagnosis = [
            Diagnostic(section: .attestationReadiness, name: "console session", level: .pass,
                       message: "logged in."),
        ]
        let detailed = [
            DoctorCheck(name: "metal gpu", status: .fail, detail: "gone",
                        section: DiagnosticSection.hardware.wireID),
        ]
        let report = DoctorJSONReportBuilder.build(
            version: "0.8.5", daemonRunning: false,
            diagnosis: diagnosis, detailedChecks: detailed
        )

        #expect(report.checks.map(\.id) == [
            "runtime.daemon",
            "attestationReadiness.console-session",
            "metal-gpu",
        ])
        #expect(report.checks.map(\.section) == ["runtime", "attestationReadiness", "hardware"])
        #expect(report.checks[0].status == .warn)
        #expect(report.checks[0].advice == "run `darkbloom start`, then re-run `darkbloom doctor`")
        #expect(report.checks[2].status == .fail)
        #expect(report.verdict == DoctorReport.Verdict(status: .fail, failures: 1, warnings: 1))
    }

    @Test func duplicateCheckIDsGetSuffixes() {
        let diagnosis = [
            Diagnostic(section: .trust, name: "trust level", level: .warn, message: "a", fix: nil),
            Diagnostic(section: .trust, name: "trust level", level: .warn, message: "b", fix: nil),
        ]
        let checks = DoctorJSONReportBuilder.build(
            version: "0.8.5", daemonRunning: true,
            diagnosis: diagnosis, detailedChecks: []
        ).checks
        #expect(checks.map(\.id) == ["runtime.daemon", "trust.trust-level", "trust.trust-level-2"])
    }

    @Test func slugsCollapseNonAlphanumerics() {
        #expect(DoctorJSONReportBuilder.slug("metal gpu") == "metal-gpu")
        #expect(DoctorJSONReportBuilder.slug("SE key sign test") == "se-key-sign-test")
        #expect(DoctorJSONReportBuilder.slug("APNs  readiness (live)") == "apns-readiness-live")
    }

    @Test func sectionWireIDsMatchTheAppEnumCaseNames() {
        #expect(DiagnosticSection.allCases.map(\.wireID) == [
            "hardware", "security", "attestationKey", "attestationReadiness",
            "trust", "traffic", "runtime", "connectivity", "version", "billing",
        ])
    }
}

@Suite("doctor human report (snapshot)")
struct DoctorHumanReportRendererTests {
    @Test func rendersTheEstablishedLayout() {
        let artifacts = DoctorRunArtifacts(
            version: "0.8.5",
            configDescription: "/tmp/darkbloom-doctor-test.json",
            daemonRunning: false,
            diagnosis: [
                Diagnostic(section: .trust, name: "trust level", level: .warn,
                           message: "self_signed / online — not earning.",
                           fix: "run `darkbloom enroll`"),
            ],
            detailedChecks: [
                DoctorCheck(name: "hardware", status: .pass,
                            detail: "Apple M4 Max, 128 GB RAM, 40 GPU cores",
                            section: DiagnosticSection.hardware.wireID),
                DoctorCheck(name: "sip", status: .warn, detail: "disabled",
                            section: DiagnosticSection.security.wireID),
            ],
            bootSecurityGuide: "macos: update macOS",
            support: DoctorSupportInfo(
                coordinator: "http://localhost:8080",
                serial: "C02TEST",
                authTokenPresent: true,
                mdmEnrolled: "no",
                pidFile: "/tmp/darkbloom.pid"
            )
        )

        #expect(DoctorHumanReportRenderer.render(artifacts) == """
            darkbloom doctor 0.8.5
            Config: /tmp/darkbloom-doctor-test.json
            Daemon: NOT running — run `darkbloom start`

            COORDINATOR TRUST   (why you are / aren't earning)
              [WARN] trust level — self_signed / online — not earning.
                     ↳ fix: run `darkbloom enroll`

            DETAILED CHECKS
              [PASS] hardware: Apple M4 Max, 128 GB RAM, 40 GPU cores
              [WARN] sip: disabled

            BOOT SECURITY — ACTION REQUIRED
            macos: update macOS

            Support
              coordinator: http://localhost:8080
              serial: C02TEST
              auth token: present
              mdm enrolled: no
              pid file: /tmp/darkbloom.pid
            """)
    }

    @Test func emptyDiagnosisAndNoOptionalBlocksStayCompact() {
        let artifacts = DoctorRunArtifacts(
            version: "0.8.5",
            configDescription: "default (in-memory defaults)",
            daemonRunning: true,
            diagnosis: [],
            detailedChecks: [
                DoctorCheck(name: "hardware", status: .pass, detail: "ok",
                            section: DiagnosticSection.hardware.wireID),
            ],
            bootSecurityGuide: nil,
            support: nil
        )

        #expect(DoctorHumanReportRenderer.render(artifacts) == """
            darkbloom doctor 0.8.5
            Config: default (in-memory defaults)
            Daemon: running

            DETAILED CHECKS
              [PASS] hardware: ok
            """)
    }
}
