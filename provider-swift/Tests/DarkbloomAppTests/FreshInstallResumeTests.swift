import Foundation
import Testing
@testable import DarkbloomApp

@Suite("FreshInstall termination resume", .serialized)
@MainActor
struct FreshInstallResumeTests {
    enum Checkpoint: String, CaseIterable, Sendable {
        case account
        case profile
        case download
        case start
        case trust
    }

    @Test(
        "persisted drafts reconcile against machine truth",
        arguments: Checkpoint.allCases
    )
    func resume(checkpoint: Checkpoint) async throws {
        let harness = try FreshInstallHarness(testName: checkpoint.rawValue)
        defer { harness.cleanup() }
        try seedMachineTruth(for: checkpoint, in: harness)

        // First process: seat the normalized draft in an actual temporary
        // file. Dropping this preferences object models app termination.
        do {
            let firstProcessPreferences = harness.preferences()
            firstProcessPreferences.onboardingDraft = draft(for: checkpoint)
            #expect(firstProcessPreferences.onboardingDraft != nil)
        }

        // Relaunch: a fresh store/flow pair reads the disk draft, then replaces
        // optimistic UI progress with doctor/list/daemon/local machine truth.
        let relaunchedFlow = harness.makeFlow()
        let relaunched = AppFlowStore(
            preferences: harness.preferences(),
            launchOverride: nil,
            onboardingFlow: relaunchedFlow
        )
        #expect(relaunched.phase == .welcome)
        #expect(relaunched.resumableOnboardingDraft != nil)
        relaunched.resumeOnboarding()
        #expect(relaunchedFlow.resumeReconciliationState == .required)

        await relaunchedFlow.reconcileRestoredProgress()
        #expect(relaunchedFlow.resumeReconciliationState == .reconciled)

        switch checkpoint {
        case .account:
            #expect(relaunchedFlow.accountPhase == .linked)
            #expect(relaunchedFlow.step == .enrollment)
            #expect(relaunchedFlow.enrollmentPhase == .profileMissing)
        case .profile:
            #expect(relaunchedFlow.accountPhase == .linked)
            #expect(relaunchedFlow.enrollmentPhase == .profileDetected)
            #expect(relaunchedFlow.step == .preparation)
            #expect(relaunchedFlow.preparationPhase == .choosingModel)
        case .download:
            #expect(relaunchedFlow.step == .preparation)
            #expect(relaunchedFlow.preparationPhase == .downloadFailed)
            #expect(relaunchedFlow.preparationFailureDetail?.contains("Resume") == true)
            #expect(relaunchedFlow.selectedModelID == FreshInstallHarness.modelID)
        case .start:
            #expect(relaunchedFlow.step == .preparation)
            #expect(relaunchedFlow.preparationPhase == .startFailed)
            #expect(relaunchedFlow.preparationFailureDetail?.contains("Start") == true)
        case .trust:
            #expect(relaunchedFlow.step == .verification)
            #expect(relaunchedFlow.preparationPhase == .ready)
            #expect(relaunchedFlow.verificationPhase == .trustPending)
        }
    }

    @Test("reconciliation does not let live historical trust override current missing MDM evidence")
    func reconciliationUsesCurrentMDMEvidence() async throws {
        let harness = try FreshInstallHarness()
        defer { harness.cleanup() }
        try harness.markAccountLinked()
        try harness.markModelDownloaded()
        try harness.markProviderStarted(trust: .init(
            trustLevel: "hardware",
            status: "online",
            reason: "previously verified",
            receivedAt: Date().timeIntervalSince1970
        ))
        let flow = harness.makeFlow()
        flow.restore(from: OnboardingDraft(
            step: .complete,
            readinessCompletedCount: OnboardingFlowModel.readinessItemCount,
            accountPhase: .linked,
            enrollmentPhase: .profileDetected,
            preparationPhase: .ready,
            preparationProgress: 1,
            verificationCompletedCount: VerificationPhase.hardwareTrusted.completedMilestoneCount,
            readinessPhase: .ready,
            verificationPhase: .hardwareTrusted,
            selectedModelID: FreshInstallHarness.modelID,
            downloadCompletedModelID: FreshInstallHarness.modelID
        ))

        await flow.reconcileRestoredProgress()

        #expect(flow.resumeReconciliationState == .reconciled)
        #expect(flow.step == .enrollment)
        #expect(flow.enrollmentPhase == .profileMissing)
        #expect(!flow.canContinue)
    }

    private func seedMachineTruth(
        for checkpoint: Checkpoint,
        in harness: FreshInstallHarness
    ) throws {
        try harness.markAccountLinked()
        guard checkpoint != .account else { return }
        try harness.markProfileInstalled()
        guard checkpoint != .profile && checkpoint != .download else { return }
        try harness.markModelDownloaded()
        guard checkpoint == .trust else { return }
        try harness.markProviderStarted()
    }

    private func draft(for checkpoint: Checkpoint) -> OnboardingDraft {
        let step: OnboardingStep
        let account: AccountLinkPhase
        let enrollment: EnrollmentPhase
        let preparation: PreparationPhase
        let progress: Double
        let modelID: String?
        let verification: VerificationPhase

        switch checkpoint {
        case .account:
            (step, account, enrollment, preparation, progress, modelID, verification) =
                (.account, .waitingForApproval, .overview, .reservingSpace, 0.04, nil, .profileDetected)
        case .profile:
            (step, account, enrollment, preparation, progress, modelID, verification) =
                (.enrollment, .linked, .systemSettingsOpen, .reservingSpace, 0.04, nil, .profileDetected)
        case .download:
            (step, account, enrollment, preparation, progress, modelID, verification) =
                (.preparation, .linked, .profileDetected, .downloading, 0.5, FreshInstallHarness.modelID, .profileDetected)
        case .start:
            (step, account, enrollment, preparation, progress, modelID, verification) =
                (.preparation, .linked, .profileDetected, .startingProvider, 1, FreshInstallHarness.modelID, .profileDetected)
        case .trust:
            (step, account, enrollment, preparation, progress, modelID, verification) =
                (.verification, .linked, .profileDetected, .ready, 1, FreshInstallHarness.modelID, .trustPending)
        }

        return OnboardingDraft(
            step: step,
            readinessCompletedCount: OnboardingFlowModel.readinessItemCount,
            accountPhase: account,
            enrollmentPhase: enrollment,
            preparationPhase: preparation,
            preparationProgress: progress,
            verificationCompletedCount: verification.completedMilestoneCount,
            readinessPhase: .ready,
            verificationPhase: verification,
            selectedModelID: modelID
        )
    }
}
