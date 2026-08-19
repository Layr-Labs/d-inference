import Foundation
import ProviderCoreFoundation
import Testing
@testable import DarkbloomApp

@Suite("Onboarding live enrollment CLI and evidence")
@MainActor
struct OnboardingEnrollmentLiveTests {
    @Test("All schema-1 enrollment statuses decode with snake-case fields")
    func statusDecoding() throws {
        let cases: [(String, EnrollmentCLIStatus, String?)] = [
            ("already_enrolled", .alreadyEnrolled, nil),
            ("profile_opened", .profileOpened, "/tmp/Darkbloom.mobileconfig"),
            ("profile_downloaded", .profileDownloaded, "/tmp/Darkbloom.mobileconfig"),
        ]

        for (status, expected, path) in cases {
            let pathJSON = path.map { ",\"profile_path\":\"\($0)\"" } ?? ""
            let data = Data("{\"schema\":1,\"status\":\"\(status)\",\"serial_number\":\"SERIAL\"\(pathJSON)}".utf8)
            let response = try JSONDecoder().decode(EnrollmentCLIResponse.self, from: data)
            #expect(response.status == expected)
            #expect(response.serialNumber == "SERIAL")
            #expect(response.profilePath == path)
        }
    }

    @Test("Fast enrollment children always drain complete stdout after exit")
    func fastChildStdoutIsDeterministic() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("enrollment-fast-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("darkbloom")
        try """
        #!/bin/sh
        printf '%s\\n' '{"schema":1,"serial_number":"FAST","status":"already_enrolled"}'
        printf '%s\\n' 'fast child diagnostic' >&2
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        let cli = ProcessEnrollmentCLI(locator: EnrollmentScriptLocator(url: script))

        for _ in 0..<100 {
            let response = try await cli.enroll()
            #expect(response.status == .alreadyEnrolled)
            #expect(response.serialNumber == "FAST")
        }
    }

    @Test("Current doctor MDM evidence cannot be overridden by historical daemon trust")
    func doctorMDMEvidenceIsAuthoritative() {
        let trusted = providerEvidence()

        #expect(EnrollmentEvidence.evaluate(
            report: evidenceReport(enrolled: false),
            providerEvidence: trusted
        ) == .missing(detail: "not enrolled"))

        let conflict = report(mdmCheck: .init(
            id: "mdm-enrollment",
            section: "trust",
            title: "MDM enrollment",
            status: "fail",
            detail: "another MDM enrollment is installed",
            advice: nil
        ))
        #expect(EnrollmentEvidence.evaluate(
            report: conflict,
            providerEvidence: trusted
        ) == .conflicting(detail: "another MDM enrollment is installed"))
    }

    @Test("Daemon MDM fallback requires fresh live verified hardware evidence")
    func daemonFallbackRequiresFreshLiveHardwareTrust() {
        let unavailableDoctorCheck = report(mdmCheck: nil)
        let live = providerEvidence()
        #expect(EnrollmentEvidence.evaluate(
            report: unavailableDoctorCheck,
            providerEvidence: live
        ) == .enrolled)

        let dead = providerEvidence(processIsAlive: false)
        #expect(EnrollmentEvidence.evaluate(
            report: unavailableDoctorCheck,
            providerEvidence: dead
        ) == .missing(detail: "The system check did not report local MDM enrollment evidence."))

        let stale = providerEvidence(writtenAt: 1_000, sampledAt: 2_000)
        #expect(EnrollmentEvidence.evaluate(
            report: unavailableDoctorCheck,
            providerEvidence: stale
        ) == .missing(detail: "The system check did not report local MDM enrollment evidence."))

        let selfSigned = providerEvidence(trustLevel: "self_signed")
        #expect(EnrollmentEvidence.evaluate(
            report: unavailableDoctorCheck,
            providerEvidence: selfSigned
        ) == .missing(detail: "The system check did not report local MDM enrollment evidence."))
    }

    @Test("already_enrolled advances without pretending to install a profile")
    func alreadyEnrolledAdvances() async {
        let enrollment = ScriptedEnrollmentRunner(results: [
            .success(.init(schema: 1, status: .alreadyEnrolled, serialNumber: "SERIAL", profilePath: nil)),
        ])
        let flow = makeFlow(enrollment: enrollment, diagnostics: ScriptedDiagnosticsRunner(reports: []))

        await flow.beginEnrollment()

        #expect(flow.enrollmentPhase == .profileDetected)
        #expect(flow.canContinue)
        #expect(enrollment.calls == 1)
    }

    @Test("profile_opened stays blocked until doctor reports real enrollment")
    func profileOpenedNeedsEvidence() async {
        let enrollment = ScriptedEnrollmentRunner(results: [
            .success(.init(
                schema: 1,
                status: .profileOpened,
                serialNumber: "SERIAL",
                profilePath: "/tmp/Darkbloom.mobileconfig"
            )),
        ])
        let diagnostics = ScriptedDiagnosticsRunner(reports: [
            evidenceReport(enrolled: false),
            evidenceReport(enrolled: true),
        ])
        let flow = makeFlow(enrollment: enrollment, diagnostics: diagnostics)

        await flow.beginEnrollment()
        flow.cancelPendingOperations()
        #expect(flow.enrollmentPhase == .systemSettingsOpen)
        #expect(!flow.canContinue)

        await flow.confirmProfileInstallation()
        #expect(flow.enrollmentPhase == .profileMissing)
        #expect(!flow.canContinue)

        await flow.retryProfileDetection()
        #expect(flow.enrollmentPhase == .profileDetected)
        #expect(flow.canContinue)
    }

    @Test("profile_downloaded exposes the saved file and allows a real reopen attempt")
    func downloadedProfileCanReopen() async {
        let path = "/tmp/Darkbloom.mobileconfig"
        let enrollment = ScriptedEnrollmentRunner(results: [
            .success(.init(schema: 1, status: .profileDownloaded, serialNumber: "SERIAL", profilePath: path)),
            .success(.init(schema: 1, status: .profileOpened, serialNumber: "SERIAL", profilePath: path)),
        ])
        let flow = makeFlow(enrollment: enrollment, diagnostics: ScriptedDiagnosticsRunner(reports: []))

        await flow.beginEnrollment()
        #expect(flow.enrollmentPhase == .instructions)
        #expect(flow.enrollmentProfilePath == path)

        await flow.beginEnrollment()
        flow.cancelPendingOperations()
        #expect(flow.enrollmentPhase == .systemSettingsOpen)
        #expect(enrollment.calls == 2)
    }

    @Test("Enrollment command failures are visible and retryable")
    func commandFailureRetry() async {
        let enrollment = ScriptedEnrollmentRunner(results: [
            .failure(EnrollmentCLIError.exited(1, message: "Profile request failed. Try again.")),
            .success(.init(schema: 1, status: .profileOpened, serialNumber: "SERIAL", profilePath: "/tmp/profile")),
        ])
        let flow = makeFlow(enrollment: enrollment, diagnostics: ScriptedDiagnosticsRunner(reports: []))

        await flow.beginEnrollment()
        #expect(flow.enrollmentPhase == .enrollmentFailed)
        #expect(flow.enrollmentFailureDetail?.contains("Try again") == true)

        await flow.beginEnrollment()
        flow.cancelPendingOperations()
        #expect(flow.enrollmentPhase == .systemSettingsOpen)
        #expect(flow.enrollmentFailureDetail == nil)
    }

    private func makeFlow(
        enrollment: ScriptedEnrollmentRunner,
        diagnostics: ScriptedDiagnosticsRunner
    ) -> OnboardingFlowModel {
        OnboardingFlowModel(
            startingAt: .enrollment,
            diagnosticsRunner: diagnostics,
            accountLinkRunner: nil,
            enrollmentRunner: enrollment,
            preparationService: nil,
            daemonStateProvider: { nil },
            enrollmentPollInterval: .seconds(60)
        )
    }

    private func evidenceReport(enrolled: Bool) -> DoctorJSONReport {
        report(mdmCheck: .init(
            id: "mdm-enrollment",
            section: "trust",
            title: "MDM enrollment",
            status: enrolled ? "pass" : "warn",
            detail: enrolled ? "Darkbloom profile installed" : "not enrolled",
            advice: nil
        ))
    }

    private func report(mdmCheck: DoctorJSONReport.Check?) -> DoctorJSONReport {
        DoctorJSONReport(
            schema: 1,
            version: "test",
            checks: mdmCheck.map { [$0] } ?? [],
            fixes: nil,
            verdict: .init(status: mdmCheck?.status == "pass" ? "pass" : "warn", failures: 0, warnings: 1)
        )
    }

    private func providerEvidence(
        processIsAlive: Bool = true,
        trustLevel: String = "hardware",
        writtenAt: Double = 1_990,
        sampledAt: Double = 2_000
    ) -> OnboardingProviderEvidence {
        OnboardingProviderEvidence(
            daemonState: DaemonState(
                pid: 42,
                version: "test",
                writtenAt: writtenAt,
                startedAt: 1_900,
                trust: .init(
                    trustLevel: trustLevel,
                    status: "online",
                    reason: "",
                    receivedAt: writtenAt
                )
            ),
            localEndpoint: nil,
            processIsAlive: processIsAlive,
            sampledAt: Date(timeIntervalSince1970: sampledAt)
        )
    }
}

private struct EnrollmentScriptLocator: DarkbloomCLILocating {
    let url: URL

    func locate() -> URL? { url }
}

private final class ScriptedEnrollmentRunner: EnrollmentCLIRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<EnrollmentCLIResponse, Error>]
    private var callCount = 0

    init(results: [Result<EnrollmentCLIResponse, Error>]) {
        self.results = results
    }

    var calls: Int { lock.withLock { callCount } }

    func enroll() async throws -> EnrollmentCLIResponse {
        let result: Result<EnrollmentCLIResponse, Error>? = lock.withLock {
            callCount += 1
            return results.isEmpty ? nil : results.removeFirst()
        }
        guard let result else { throw EnrollmentCLIError.unreadableOutput }
        return try result.get()
    }
}

private final class ScriptedDiagnosticsRunner: DiagnosticsCLIRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [DoctorJSONReport]

    init(reports: [DoctorJSONReport]) {
        self.reports = reports
    }

    func runDoctorJSON() async throws -> DoctorJSONReport {
        let report = lock.withLock { reports.isEmpty ? nil : reports.removeFirst() }
        guard let report else { throw DiagnosticsCLIError.undecodable }
        return report
    }
}
