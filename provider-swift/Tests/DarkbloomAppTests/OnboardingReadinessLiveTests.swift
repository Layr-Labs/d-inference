import Foundation
import Testing
@testable import DarkbloomApp

@Suite("Onboarding live readiness evaluation")
struct OnboardingReadinessLiveTests {
    @Test("Account, enrollment, provider, model, and connectivity failures do not gate prerequisites")
    func mutableSetupChecksDoNotGate() {
        let report = makeReport(extra: [
            check("account-link", status: "fail", detail: "not logged in"),
            check("mdm-enrollment", status: "fail", detail: "not enrolled"),
            check("runtime.daemon", status: "fail", detail: "not running"),
            check("local-mlx-models", status: "fail", detail: "0 discovered"),
            check("connectivity.coordinator", status: "fail", detail: "offline"),
        ])

        let evaluation = ReadinessEvaluator.evaluate(report: report, facts: healthyFacts)

        #expect(evaluation.phase == .ready)
        #expect(evaluation.items.count == OnboardingFlowModel.readinessItemCount)
        #expect(evaluation.items.allSatisfy { $0.state == .complete })
    }

    @Test("Every immutable prerequisite is mapped by stable doctor id")
    func immutableChecksAreExplicit() {
        let evaluation = ReadinessEvaluator.evaluate(report: makeReport(), facts: healthyFacts)
        let ids = Dictionary(uniqueKeysWithValues: evaluation.items.map { ($0.id, $0.doctorCheckIDs) })

        #expect(ids["apple-silicon"] == ["hardware", "metal-gpu"])
        #expect(ids["supported-macos"] == ["macos"])
        #expect(ids["secure-enclave"] == ["attestationKey.se-key-sign-test"])
        #expect(ids["unified-memory"] == ["hardware"])
        #expect(ids["available-storage"] == [])
        #expect(ids["boot-security"] == ["sip", "authenticated-root"])
    }

    @Test("Hardware, RAM, disk, Secure Enclave, and boot failures stay blocked with actions")
    func immutableFailuresBlock() {
        let cases: [(DoctorJSONReport, ReadinessMachineFacts, ReadinessPhase, String)] = [
            (
                makeReport(replacing: check("hardware", status: "fail", detail: "Apple silicon unavailable")),
                healthyFacts,
                .unsupportedMac,
                "apple-silicon"
            ),
            (
                makeReport(),
                ReadinessMachineFacts(
                    isAppleSilicon: true,
                    physicalMemoryBytes: 4 * 1_073_741_824,
                    availableStorageBytes: 100 * 1_073_741_824
                ),
                .insufficientMemory,
                "unified-memory"
            ),
            (
                makeReport(),
                ReadinessMachineFacts(
                    isAppleSilicon: true,
                    physicalMemoryBytes: 32 * 1_073_741_824,
                    availableStorageBytes: 4 * 1_073_741_824
                ),
                .insufficientStorage,
                "available-storage"
            ),
            (
                makeReport(replacing: check(
                    "attestationKey.se-key-sign-test",
                    status: "fail",
                    detail: "sign test failed",
                    advice: "Reinstall the signed app."
                )),
                healthyFacts,
                .requirementsFailed,
                "secure-enclave"
            ),
            (
                makeReport(replacing: check("sip", status: "warn", detail: "disabled")),
                healthyFacts,
                .requirementsFailed,
                "boot-security"
            ),
        ]

        for (report, facts, phase, issueID) in cases {
            let evaluation = ReadinessEvaluator.evaluate(report: report, facts: facts)
            #expect(evaluation.phase == phase)
            let issue = evaluation.items.first { $0.id == issueID }
            #expect(issue?.state == .issue)
            #expect(issue?.action?.isEmpty == false)
            #expect(!evaluation.phase.allowsContinuation)
        }
    }

    @Test("Missing required doctor ids never become an optimistic pass")
    func missingCheckBlocks() {
        var checks = requiredChecks
        checks.removeAll { $0.id == "authenticated-root" }
        let report = DoctorJSONReport(
            schema: 1,
            version: "test",
            checks: checks,
            fixes: nil,
            verdict: .init(status: "pass", failures: 0, warnings: 0)
        )

        let evaluation = ReadinessEvaluator.evaluate(report: report, facts: healthyFacts)
        #expect(evaluation.phase == .requirementsFailed)
        #expect(evaluation.items.first { $0.id == "boot-security" }?.state == .issue)
    }

    private var healthyFacts: ReadinessMachineFacts {
        ReadinessMachineFacts(
            isAppleSilicon: true,
            physicalMemoryBytes: 32 * 1_073_741_824,
            availableStorageBytes: 100 * 1_073_741_824
        )
    }

    private var requiredChecks: [DoctorJSONReport.Check] {
        [
            check("hardware", detail: "Apple M4 Pro, 32 GB RAM, 20 GPU cores"),
            check("metal-gpu", detail: "Apple M4 Pro, 28 GB working set"),
            check("macos", detail: "macOS 15.0; full security"),
            check("attestationKey.se-key-sign-test", detail: "sign and verify succeeded"),
            check("sip", detail: "enabled"),
            check("authenticated-root", detail: "enabled"),
        ]
    }

    private func makeReport(
        replacing replacement: DoctorJSONReport.Check? = nil,
        extra: [DoctorJSONReport.Check] = []
    ) -> DoctorJSONReport {
        var checks = requiredChecks
        if let replacement, let index = checks.firstIndex(where: { $0.id == replacement.id }) {
            checks[index] = replacement
        }
        checks.append(contentsOf: extra)
        return DoctorJSONReport(
            schema: 1,
            version: "test",
            checks: checks,
            fixes: nil,
            verdict: .init(status: "fail", failures: 1, warnings: 1)
        )
    }

    private func check(
        _ id: String,
        status: String = "pass",
        detail: String,
        advice: String? = nil
    ) -> DoctorJSONReport.Check {
        DoctorJSONReport.Check(
            id: id,
            section: "test",
            title: id,
            status: status,
            detail: detail,
            advice: advice
        )
    }
}
