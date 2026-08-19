import Foundation
import Testing
@testable import DarkbloomApp

@Suite("Onboarding flow resilience")
@MainActor
struct OnboardingFlowTests {
    @Test("A ready Mac advances into account connection")
    func readinessAdvancesToAccount() {
        let flow = preview(.readiness, "ready")

        #expect(flow.readinessPhase == .ready)
        #expect(flow.canContinue)
        flow.continueToNextStep()
        #expect(flow.step == .account)
    }

    @Test("Readiness issues are distinct deterministic preview states")
    func readinessIssueVariants() {
        #expect(preview(.readiness, "unsupported").readinessPhase == .unsupportedMac)
        #expect(preview(.readiness, "low-memory").readinessPhase == .insufficientMemory)
        #expect(preview(.readiness, "low-storage").readinessPhase == .lowStorage)
        #expect(preview(.readiness, "offline").readinessPhase == .offline)
        #expect(preview(.readiness, "low-storage").canContinue)
        #expect(preview(.readiness, "low-storage").readinessCompletedCount == OnboardingFlowModel.readinessItemCount)
    }

    @Test("Immutable hardware failures stay blocked after a preview recheck")
    func hardwareFailuresDoNotAutoHeal() async {
        for variant in ["unsupported", "low-memory"] {
            let flow = preview(.readiness, variant)
            let failure = flow.readinessPhase

            await flow.retryReadinessChecks()

            #expect(flow.readinessPhase == failure)
            #expect(!flow.canContinue)
        }
    }

    @Test("Account codes are wire-shaped and failure states can request a new code")
    func accountCodeAndRecovery() {
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let flow = OnboardingFlowModel(
            startingAt: .account,
            previewVariant: "waiting",
            freezesAutomaticProgress: true,
            accountLinkIssuedAt: issuedAt
        )
        let groups = flow.accountLinkSession.code.split(separator: "-")
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.count == 4 })
        #expect(flow.accountLinkSession.remainingMinutes(at: issuedAt) == 15)
        #expect(OnboardingAccountLinkSession.pollInterval == 5)

        let firstCode = flow.accountLinkSession.code
        flow.retryAccountLink(at: issuedAt.addingTimeInterval(60))
        #expect(flow.accountLinkSession.code != firstCode)
        #expect(flow.accountLinkSession.remainingMinutes(at: issuedAt.addingTimeInterval(60)) == 15)

        let expired = preview(.account, "expired")
        #expect(expired.accountPhase == .expired)
        #expect(!expired.canContinue)
        expired.retryAccountLink()
        #expect(expired.accountPhase == .waitingForApproval)

        let unreachable = preview(.account, "unreachable")
        #expect(unreachable.accountPhase == .unreachable)
        unreachable.retryAccountLink()
        #expect(unreachable.accountPhase == .waitingForApproval)
    }

    @Test("Darkbloom account policy blocks network setup until linking succeeds")
    func accountPolicyRequiresLink() {
        let waiting = preview(.account, "waiting")
        waiting.continueToNextStep()
        #expect(waiting.step == .account)

        let linked = preview(.account, "linked")
        linked.continueToNextStep()
        #expect(linked.step == .enrollment)
    }

    @Test("Profile detection is separate from enrollment and trust")
    func profileDetectionIsSeparate() {
        let detected = preview(.enrollment, "profile-detected")
        #expect(detected.enrollmentPhase == .profileDetected)
        #expect(detected.verificationPhase == .profileDetected)
        detected.continueToNextStep()
        #expect(detected.step == .preparation)
        #expect(detected.goBack())
        #expect(detected.step == .enrollment)

        let pending = preview(.verification, "enrollment-pending")
        #expect(pending.verificationPhase == .enrollmentPending)
        #expect(!pending.canContinue)

        let trust = preview(.verification, "trust-pending")
        #expect(trust.verificationPhase == .trustPending)
        #expect(!trust.canContinue)

        let trusted = preview(.verification, "hardware-trusted")
        #expect(trusted.verificationPhase == .hardwareTrusted)
        #expect(trusted.canContinue)
    }

    @Test("Enrollment failures expose deterministic recovery transitions")
    func enrollmentFailureRecovery() async {
        let missing = preview(.enrollment, "profile-missing")
        #expect(missing.enrollmentPhase == .profileMissing)
        missing.reopenSystemSettings()
        #expect(missing.enrollmentPhase == .systemSettingsOpen)

        let conflict = preview(.enrollment, "conflicting-mdm")
        #expect(conflict.enrollmentPhase == .conflictingManagement)
        conflict.downloadProfileAgain()
        #expect(conflict.enrollmentPhase == .conflictingManagement)
        conflict.reopenSystemSettings()
        #expect(conflict.enrollmentPhase == .systemSettingsOpen)
        await conflict.confirmProfileInstallation()
        #expect(conflict.enrollmentPhase == .conflictingManagement)

        let failed = preview(.enrollment, "enrollment-failed")
        #expect(failed.enrollmentPhase == .enrollmentFailed)
        #expect(!failed.canContinue)
    }

    @Test("Download failure is actionable and never presented as ready")
    func modelDownloadFailure() {
        let flow = preview(.preparation, "download-failed")
        #expect(flow.preparationPhase == .downloadFailed)
        #expect(flow.preparationProgress > 0)
        #expect(!flow.canContinue)
    }

    @Test("Model preparation is required and interrupted work remains resumable")
    func modelPreparationIsRequired() async {
        let restoredPreparation = draft(
            step: .preparation,
            account: .linked,
            enrollment: .profileDetected,
            preparation: .downloadFailed,
            progress: 0.43
        ).normalizedForResume
        #expect(restoredPreparation.step == .preparation)
        #expect(restoredPreparation.preparationPhase == .downloadFailed)
        #expect(restoredPreparation.verificationPhase == .profileDetected)
        #expect(restoredPreparation.progressLabel.contains("of 5"))

        let flow = OnboardingFlowModel(
            startingAt: .complete,
            freezesAutomaticProgress: true
        )
        flow.restore(
            from: draft(
                step: .complete,
                account: .linked,
                enrollment: .profileDetected,
                preparation: .downloadFailed,
                progress: 0.43,
                verification: .hardwareTrusted
            )
        )
        await flow.reconcileRestoredProgress()
        #expect(!flow.hasCompletedAllRequiredSteps)
        #expect(flow.preparationPhase == .downloadFailed)
    }

    @Test("Only hardware trust completes verification")
    func verificationAdvancesOnlyWhenTrusted() {
        for variant in ["profile-detected", "enrollment-pending", "trust-pending", "check-in-delayed", "trust-failed", "offline"] {
            let flow = preview(.verification, variant)
            flow.continueToNextStep()
            #expect(flow.step == .verification)
        }

        let trusted = preview(.verification, "ready")
        trusted.continueToNextStep()
        #expect(trusted.step == .complete)
    }

    @Test("Back navigation stops at the setup boundary")
    func backNavigationRespectsBoundary() {
        let firstStep = preview(.readiness, "working")
        #expect(!firstStep.goBack())

        let accountStep = preview(.account, "waiting")
        #expect(accountStep.goBack())
        #expect(accountStep.step == .readiness)
    }

    @Test("Transient checks resume at safe user-actionable states")
    func transientDraftStatesNormalizeForResume() {
        let confirmingAccount = draft(step: .account, account: .confirming).normalizedForResume
        #expect(confirmingAccount.accountPhase == .waitingForApproval)

        let detectingProfile = draft(
            step: .enrollment,
            account: .linked,
            enrollment: .detectingProfile
        ).normalizedForResume
        #expect(detectingProfile.enrollmentPhase == .systemSettingsOpen)

        let pendingTrust = draft(
            step: .verification,
            account: .linked,
            enrollment: .profileDetected,
            preparation: .ready,
            progress: 1,
            verification: .trustPending
        ).normalizedForResume
        #expect(pendingTrust.verificationPhase == .profileDetected)
    }

    @Test("Restored progress is blocked until reconciliation finishes")
    func restoredProgressRequiresReconciliation() async {
        let flow = preview(.readiness, "working")
        flow.restore(from: draft(step: .verification, verification: .hardwareTrusted))

        #expect(flow.resumeReconciliationState == .required)
        #expect(!flow.canContinue)

        let reconciliation = Task { await flow.reconcileRestoredProgress() }
        await Task.yield()
        #expect(flow.resumeReconciliationState == .rechecking)
        await reconciliation.value

        #expect(flow.resumeReconciliationState == .reconciled)
        #expect(flow.canContinue)
    }

    @Test("Reconciliation can rewind stale saved progress")
    func reconciliationCanRewind() async {
        let flow = OnboardingFlowModel(
            startingAt: .complete,
            freezesAutomaticProgress: true,
            reconciliationOutcome: .profileMissing
        )
        flow.restore(from: draft(step: .complete, verification: .hardwareTrusted))

        await flow.reconcileRestoredProgress()

        #expect(flow.resumeReconciliationState == .reconciled)
        #expect(flow.step == .enrollment)
        #expect(flow.enrollmentPhase == .profileMissing)
        #expect(!flow.canContinue)
    }

    @Test("Unavailable reconciliation keeps restored success blocked")
    func unavailableReconciliationBlocksProgress() async {
        let flow = OnboardingFlowModel(
            startingAt: .complete,
            freezesAutomaticProgress: true,
            reconciliationOutcome: .unavailable
        )
        flow.restore(from: draft(step: .complete, verification: .hardwareTrusted))

        await flow.reconcileRestoredProgress()

        #expect(flow.resumeReconciliationState == .unavailable)
        #expect(!flow.hasCompletedAllRequiredSteps)
    }

    @Test("Reset prevents a delayed approval task from mutating the new flow")
    func resetInvalidatesDelayedApproval() async {
        let flow = preview(.account, "waiting")
        let approval = Task { await flow.confirmAccountApproval() }
        try? await Task.sleep(for: .milliseconds(40))

        flow.resetForNewSetup()
        await approval.value

        #expect(flow.step == .readiness)
        #expect(flow.accountPhase == .introduction)
    }

    @Test("Version one drafts decode into explicit phase state")
    func legacyDraftMigration() throws {
        let json = """
        {"schemaVersion":1,"step":4,"readinessCompletedCount":5,"accountPhase":3,"enrollmentPhase":4,"preparationPhase":3,"preparationProgress":1,"verificationCompletedCount":2}
        """
        let decoded = try JSONDecoder().decode(OnboardingDraft.self, from: Data(json.utf8))
        let normalized = decoded.normalizedForResume

        #expect(decoded.isSupported)
        #expect(normalized.schemaVersion == OnboardingDraft.currentSchemaVersion)
        #expect(normalized.readinessPhase == .ready)
        #expect(normalized.enrollmentPhase == .profileDetected)
        #expect(normalized.verificationPhase == .profileDetected)
    }

    @Test("Reset returns to a clean first step")
    func restoredDraftCanResetCleanly() {
        let flow = preview(.verification, "ready")
        flow.restore(from: draft(step: .verification, verification: .hardwareTrusted))
        flow.resetForNewSetup()

        #expect(!flow.isRestoredFromDraft)
        #expect(flow.resumeReconciliationState == .notNeeded)
        #expect(flow.step == .readiness)
        #expect(flow.readinessCompletedCount == 0)
        #expect(flow.readinessPhase == .checking)
        #expect(flow.preparationProgress == 0.04)
    }

    private func preview(_ step: OnboardingStep, _ variant: String) -> OnboardingFlowModel {
        OnboardingFlowModel(
            startingAt: step,
            previewVariant: variant,
            freezesAutomaticProgress: true
        )
    }

    private func draft(
        step: OnboardingStep,
        account: AccountLinkPhase = .introduction,
        enrollment: EnrollmentPhase = .overview,
        preparation: PreparationPhase = .reservingSpace,
        progress: Double = 0.04,
        verification: VerificationPhase = .profileDetected
    ) -> OnboardingDraft {
        OnboardingDraft(
            step: step,
            readinessCompletedCount: step == .readiness ? 0 : OnboardingFlowModel.readinessItemCount,
            accountPhase: account,
            enrollmentPhase: enrollment,
            preparationPhase: preparation,
            preparationProgress: progress,
            verificationCompletedCount: verification.completedMilestoneCount,
            readinessPhase: step == .readiness ? .checking : .ready,
            verificationPhase: verification
        )
    }
}
