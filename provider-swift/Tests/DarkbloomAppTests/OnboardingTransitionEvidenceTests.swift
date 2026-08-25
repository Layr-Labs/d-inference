import Foundation
import ProviderCoreFoundation
import Testing
@testable import DarkbloomApp

@Suite("Onboarding transition evidence")
@MainActor
struct OnboardingTransitionEvidenceTests {
    @Test("Readiness is re-sampled before advancing")
    func readinessRecheckFailsClosed() async {
        let diagnostics = TransitionDiagnostics(reports: [
            Self.doctorReport(),
            Self.doctorReport(overrides: ["sip": "fail"]),
        ])
        let flow = OnboardingFlowModel(
            startingAt: .readiness,
            diagnosticsRunner: diagnostics,
            readinessFactsProvider: Self.healthyFacts,
            accountLinkRunner: nil,
            enrollmentRunner: nil,
            preparationService: nil
        )

        await flow.runAutomaticWorkForCurrentStep()
        #expect(flow.readinessPhase == .ready)

        await flow.continueToNextStep()

        #expect(flow.step == .readiness)
        #expect(flow.readinessPhase == .requirementsFailed)
        #expect(diagnostics.calls == 2)
    }

    @Test("Account linkage is re-sampled before advancing")
    func accountRecheckFailsClosed() async {
        let diagnostics = TransitionDiagnostics(reports: [
            Self.doctorReport(overrides: ["account-link": "warn"]),
        ])
        let flow = OnboardingFlowModel(
            startingAt: .account,
            diagnosticsRunner: diagnostics,
            accountLinkRunner: nil,
            enrollmentRunner: nil,
            preparationService: nil
        )
        flow.accountPhase = .linked

        await flow.continueToNextStep()

        #expect(flow.step == .account)
        #expect(flow.accountPhase == .introduction)
        #expect(flow.accountLinkFailureDetail?.contains("no longer reports") == true)
    }

    @Test("Enrollment profile is re-sampled before advancing")
    func enrollmentRecheckFailsClosed() async {
        let diagnostics = TransitionDiagnostics(reports: [
            Self.doctorReport(overrides: ["mdm-enrollment": "warn"]),
        ])
        let flow = OnboardingFlowModel(
            startingAt: .enrollment,
            diagnosticsRunner: diagnostics,
            accountLinkRunner: nil,
            enrollmentRunner: nil,
            preparationService: nil
        )
        flow.enrollmentPhase = .profileDetected

        await flow.continueToNextStep()

        #expect(flow.step == .enrollment)
        #expect(flow.enrollmentPhase == .profileMissing)
    }

    @Test("Provider and endpoint are re-sampled before verification")
    func preparationRecheckFailsClosed() async {
        let evidence = TransitionEvidenceBox(Self.startedEvidence())
        let flow = OnboardingFlowModel(
            startingAt: .preparation,
            diagnosticsRunner: nil,
            accountLinkRunner: nil,
            enrollmentRunner: nil,
            preparationService: nil,
            providerEvidenceProvider: evidence.read
        )
        flow.selectedModelID = "catalog/model"
        flow.preparationPhase = .ready
        flow.providerStartCompleted = true
        #expect(flow.canContinue)
        evidence.value = .init(
            daemonState: nil,
            localEndpoint: nil,
            processIsAlive: false,
            localEndpointProcessIsAlive: false
        )

        await flow.continueToNextStep()

        #expect(flow.step == .preparation)
        #expect(flow.preparationPhase == .startFailed)
        #expect(!flow.providerStartCompleted)
    }

    @Test("Final completion rechecks the local profile")
    func completionRechecksProfile() async {
        let diagnostics = TransitionDiagnostics(reports: [
            Self.doctorReport(overrides: ["mdm-enrollment": "warn"]),
        ])
        let evidence = TransitionEvidenceBox(Self.startedEvidence(trusted: true))
        let flow = OnboardingFlowModel(
            startingAt: .verification,
            diagnosticsRunner: diagnostics,
            readinessFactsProvider: Self.healthyFacts,
            accountLinkRunner: nil,
            enrollmentRunner: nil,
            preparationService: nil,
            providerEvidenceProvider: evidence.read
        )
        flow.selectedModelID = "catalog/model"
        flow.verificationPhase = .hardwareTrusted
        #expect(flow.canContinue)

        await flow.continueToNextStep()

        #expect(flow.step == .enrollment)
        #expect(flow.enrollmentPhase == .profileMissing)
    }

    private static let healthyFacts = {
        ReadinessMachineFacts(
            isAppleSilicon: true,
            physicalMemoryBytes: 16 * 1_073_741_824,
            availableStorageBytes: 100 * 1_073_741_824
        )
    }

    private static func doctorReport(
        overrides: [String: String] = [:]
    ) -> DoctorJSONReport {
        let ids = [
            "hardware",
            "metal-gpu",
            "macos",
            "attestationKey.se-key-sign-test",
            "sip",
            "authenticated-root",
            "account-link",
            "mdm-enrollment",
        ]
        let checks = ids.map { id in
            DoctorJSONReport.Check(
                id: id,
                section: "test",
                title: id,
                status: overrides[id] ?? "pass",
                detail: overrides[id] == nil ? "current evidence" : "evidence missing",
                advice: nil
            )
        }
        return DoctorJSONReport(
            schema: 1,
            version: "test",
            checks: checks,
            fixes: nil,
            verdict: .init(status: "pass", failures: 0, warnings: 0)
        )
    }

    private static func startedEvidence(
        trusted: Bool = false
    ) -> OnboardingProviderEvidence {
        let now = Date().timeIntervalSince1970
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 100)
        return OnboardingProviderEvidence(
            daemonState: DaemonState(
                pid: 42,
                processIdentity: identity,
                version: "test",
                writtenAt: now,
                startedAt: now - 10,
                trust: trusted
                    ? .init(
                        trustLevel: "hardware",
                        status: "verified",
                        reason: "current",
                        receivedAt: now
                    )
                    : nil,
                currentModel: "catalog/model",
                warmModels: ["catalog/model"]
            ),
            localEndpoint: LocalEndpointInfo(
                host: "127.0.0.1",
                port: 18_080,
                apiKey: "test",
                version: "test",
                pid: 42,
                processIdentity: identity,
                updatedAt: "now"
            ),
            processIsAlive: true,
            localEndpointProcessIsAlive: true,
            sampledAt: Date(timeIntervalSince1970: now)
        )
    }
}

private final class TransitionDiagnostics: DiagnosticsCLIRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [DoctorJSONReport]
    private var callCount = 0

    init(reports: [DoctorJSONReport]) {
        self.reports = reports
    }

    var calls: Int { lock.withLock { callCount } }

    func runDoctorJSON() async throws -> DoctorJSONReport {
        let report = lock.withLock {
            callCount += 1
            return reports.isEmpty ? nil : reports.removeFirst()
        }
        guard let report else { throw DiagnosticsCLIError.undecodable }
        return report
    }
}

private final class TransitionEvidenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: OnboardingProviderEvidence

    init(_ value: OnboardingProviderEvidence) {
        storage = value
    }

    var value: OnboardingProviderEvidence {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func read() -> OnboardingProviderEvidence {
        value
    }
}
