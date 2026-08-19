import Foundation
import Testing
@testable import DarkbloomApp

@Suite("FreshInstall actionable failures", .serialized)
@MainActor
struct FreshInstallFailureTests {
    @Test("unsupported readiness is actionable and a corrected check retries")
    func unsupportedReadinessRetry() async throws {
        let harness = try FreshInstallHarness()
        defer { harness.cleanup() }
        try harness.setMode("unsupported", for: .doctor)
        let flow = harness.makeFlow()

        await flow.runAutomaticWorkForCurrentStep()
        #expect(flow.readinessPhase == .unsupportedMac)
        #expect(!flow.canContinue)
        #expect(flow.readinessItems.first(where: { $0.id == "apple-silicon" })?.action != nil)

        try harness.clearMode(for: .doctor)
        await flow.retryReadinessChecks()
        #expect(flow.readinessPhase == .ready)
        #expect(flow.canContinue)
    }

    @Test(
        "expired and denied login attempts explain recovery and retry",
        arguments: ["expired", "denied"]
    )
    func loginFailureRetry(mode: String) async throws {
        let harness = try FreshInstallHarness(testName: mode)
        defer { harness.cleanup() }
        try harness.setMode(mode, for: .login)
        let flow = harness.makeFlow(startingAt: .account)

        flow.startAccountLink()
        if mode == "expired" {
            #expect(await freshInstallEventually { flow.accountPhase == .expired })
            #expect(flow.accountLinkFailureDetail?.localizedCaseInsensitiveContains("new code") == true)
        } else {
            #expect(await freshInstallEventually { flow.accountPhase == .unreachable })
            #expect(flow.accountLinkFailureDetail?.localizedCaseInsensitiveContains("retry") == true)
        }
        #expect(!flow.canContinue)

        try harness.clearMode(for: .login)
        flow.startAccountLink()
        #expect(await freshInstallEventually { flow.accountPhase == .linked })
        #expect(flow.accountLinkFailureDetail == nil)
        #expect(try harness.invocations() == [
            ["login", "--json"],
            ["login", "--json"],
        ])
    }

    @Test(
        "missing and conflicting profiles are distinct and recoverable",
        arguments: ["profile-missing", "conflicting-mdm"]
    )
    func enrollmentFailureRetry(mode: String) async throws {
        let harness = try FreshInstallHarness(testName: mode)
        defer { harness.cleanup() }
        try harness.setMode(mode, for: .doctor)
        let flow = harness.makeFlow(startingAt: .enrollment)

        await flow.confirmProfileInstallation()
        if mode == "profile-missing" {
            #expect(flow.enrollmentPhase == .profileMissing)
            #expect(flow.enrollmentFailureDetail?.localizedCaseInsensitiveContains("not installed") == true)
        } else {
            #expect(flow.enrollmentPhase == .conflictingManagement)
            #expect(flow.enrollmentFailureDetail?.localizedCaseInsensitiveContains("another MDM") == true)
        }
        #expect(!flow.canContinue)

        try harness.clearMode(for: .doctor)
        try harness.markProfileInstalled()
        await flow.retryProfileDetection()
        #expect(flow.enrollmentPhase == .profileDetected)
        #expect(flow.enrollmentFailureDetail == nil)
        #expect(flow.canContinue)
    }

    @Test("an interrupted download retains progress and retry resumes before starting")
    func interruptedDownloadRetry() async throws {
        let harness = try FreshInstallHarness()
        defer { harness.cleanup() }
        try harness.setMode("interrupt-once", for: .download)
        let flow = harness.makeFlow(startingAt: .preparation)

        await flow.runAutomaticWorkForCurrentStep()
        #expect(flow.preparationPhase == .choosingModel)
        flow.startPreparation()
        #expect(await freshInstallEventually { flow.preparationPhase == .downloadFailed })
        #expect(flow.preparationProgress == 0.5)
        #expect(flow.preparationFailureDetail?.localizedCaseInsensitiveContains("retry") == true)

        flow.retryPreparation()
        #expect(await freshInstallEventually { flow.preparationPhase == .ready })
        #expect(flow.preparationProgress == 1)
        #expect(harness.providerEvidence().reportsStarted(modelID: FreshInstallHarness.modelID))
        #expect(try harness.invocations().filter {
            $0 == ["models", "download", FreshInstallHarness.modelID, "--json"]
        }.count == 2)
    }

    @Test("provider start failure is actionable and retries without redownloading")
    func startFailureRetry() async throws {
        let harness = try FreshInstallHarness()
        defer { harness.cleanup() }
        try harness.markModelDownloaded()
        try harness.setMode("failure", for: .start)
        let flow = harness.makeFlow(startingAt: .preparation)

        await flow.runAutomaticWorkForCurrentStep()
        #expect(flow.selectedPreparationChoice?.isInstalled == true)
        flow.startPreparation()
        #expect(await freshInstallEventually { flow.preparationPhase == .startFailed })
        #expect(flow.preparationFailureDetail?.localizedCaseInsensitiveContains("retry") == true)
        #expect(!flow.canContinue)

        try harness.clearMode(for: .start)
        flow.retryPreparation()
        #expect(await freshInstallEventually { flow.preparationPhase == .ready })
        #expect(flow.canContinue)
        #expect(try harness.invocations().filter { $0.first == "start" }.count == 2)
        #expect(try harness.invocations().filter { $0.prefix(2) == ["models", "download"] }.isEmpty)
    }

    @Test("a newly downloaded model retries a failed start without redownloading")
    func newlyDownloadedStartFailureRetry() async throws {
        let harness = try FreshInstallHarness()
        defer { harness.cleanup() }
        try harness.setMode("failure", for: .start)
        let flow = harness.makeFlow(startingAt: .preparation)

        await flow.runAutomaticWorkForCurrentStep()
        #expect(flow.selectedPreparationChoice?.isInstalled == false)
        flow.startPreparation()
        #expect(await freshInstallEventually { flow.preparationPhase == .startFailed })
        #expect(flow.downloadCompletedModelID == FreshInstallHarness.modelID)

        try harness.clearMode(for: .start)
        flow.retryPreparation()
        #expect(await freshInstallEventually { flow.preparationPhase == .ready })
        #expect(try harness.invocations().filter {
            $0 == ["models", "download", FreshInstallHarness.modelID, "--json"]
        }.count == 1)
        #expect(try harness.invocations().filter { $0.first == "start" }.count == 2)
    }

    @Test("trust timeout stays blocked and a retry accepts later hardware trust")
    func trustTimeoutRetry() async throws {
        let harness = try FreshInstallHarness()
        defer { harness.cleanup() }
        let flow = harness.makeFlow(
            startingAt: .verification,
            verificationCheckInGrace: .milliseconds(40)
        )
        flow.selectedModelID = FreshInstallHarness.modelID

        let firstAttempt = Task { await flow.runAutomaticWorkForCurrentStep() }
        #expect(await freshInstallEventually { flow.verificationPhase == .checkInDelayed })
        #expect(!flow.canContinue)
        flow.cancelPendingOperations()
        await firstAttempt.value

        try harness.markProviderStarted(
            trust: .init(
                trustLevel: "hardware",
                status: "verified",
                reason: "",
                receivedAt: Date().timeIntervalSince1970
            )
        )
        await flow.retryVerification()
        #expect(flow.verificationPhase == .hardwareTrusted)
        #expect(flow.canContinue)
    }
}
