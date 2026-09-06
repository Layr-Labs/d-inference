import Testing
@testable import DarkbloomApp

@Suite("Rejected onboarding completion recovery")
@MainActor
struct OnboardingCompletionRecoveryTests {
    @Test("Lost provider evidence returns to preparation and rechecks without redownloading")
    func lostProviderEvidence() async throws {
        let model = OnboardingOperationTestFixture.model(installed: true)
        let evidence = OnboardingOperationTestEvidence(OnboardingOperationTestEvidence.running(modelID: model.id))
        let service = OnboardingOperationTestPreparation(model: model)
        let flow = OnboardingOperationTestFixture.flow(step: .complete, service: service, evidence: evidence)
        seedComplete(flow, model: model)
        #expect(flow.hasCompletedAllRequiredSteps)

        evidence.set(OnboardingOperationTestEvidence.missing)
        #expect(!flow.hasCompletedAllRequiredSteps)
        var drafts: [OnboardingDraft] = []
        flow.setDraftChangeHandler { drafts.append($0) }
        #expect(flow.recoverRejectedCompletion())
        #expect(flow.step == .preparation)
        #expect(flow.preparationPhase == .startFailed)
        #expect(flow.resumeReconciliationState == .required)
        #expect(flow.selectedModelID == model.id)
        #expect(flow.downloadCompletedModelID == model.id)
        #expect(flow.preparationProgress == 1)
        #expect(!flow.providerStartCompleted)
        #expect(!flow.canContinue)
        #expect(drafts.count == 1)
        #expect(drafts.first?.step == .preparation)

        // Model the view's task after the synchronous step transition.
        await flow.reconcileRestoredProgress()
        #expect(flow.resumeReconciliationState == .reconciled)
        #expect(flow.preparationPhase == .startFailed)
        #expect(await service.startedModelIDs.isEmpty)
        #expect(await service.downloadedModelIDs.isEmpty)

        evidence.set(OnboardingOperationTestEvidence.running(modelID: model.id))
        flow.requireResumeReconciliation()
        await flow.reconcileRestoredProgress()
        #expect(flow.hasCompletedAllRequiredSteps)
        #expect(await service.startedModelIDs.isEmpty)
        #expect(await service.downloadedModelIDs.isEmpty)
    }

    @Test("Lost hardware trust returns to verification instead of persisting stale completion")
    func lostTrustEvidence() async {
        let model = OnboardingOperationTestFixture.model(installed: true)
        let evidence = OnboardingOperationTestEvidence(OnboardingOperationTestEvidence.running(modelID: model.id))
        let service = OnboardingOperationTestPreparation(model: model)
        let flow = OnboardingOperationTestFixture.flow(step: .complete, service: service, evidence: evidence)
        seedComplete(flow, model: model)
        evidence.set(OnboardingOperationTestEvidence.running(modelID: model.id, trusted: false))

        #expect(!flow.hasCompletedAllRequiredSteps)
        #expect(flow.recoverRejectedCompletion())
        #expect(flow.step == .verification)
        #expect(flow.verificationPhase == .profileDetected)
        await flow.reconcileRestoredProgress()
        #expect(flow.step == .verification)
        #expect(flow.verificationPhase == .trustPending)
        #expect(!flow.canContinue)
        #expect(flow.downloadCompletedModelID == model.id)
        #expect(await service.startedModelIDs.isEmpty)
    }

    @Test("Failed reconciliation of a completed draft has a Back path and preserves the selected model")
    func unavailableReconciliationCanExit() async {
        let model = OnboardingOperationTestFixture.model(installed: true)
        let service = OnboardingOperationTestPreparation(model: model)
        let flow = OnboardingOperationTestFixture.flow(
            step: .complete, service: service, diagnostics: .init(fails: true)
        )
        seedComplete(flow, model: model)
        flow.requireResumeReconciliation()
        await flow.reconcileRestoredProgress()
        #expect(flow.resumeReconciliationState == .unavailable)
        #expect(flow.recoverRejectedCompletion())
        #expect(flow.step == .preparation)
        #expect(flow.resumeReconciliationState == .required)
        await flow.reconcileRestoredProgress()
        #expect(flow.resumeReconciliationState == .unavailable)
        #expect(flow.goBack())
        #expect(flow.step == .enrollment)
        #expect(flow.selectedModelID == model.id)
        #expect(flow.downloadCompletedModelID == model.id)
        #expect(await service.startedModelIDs.isEmpty)
    }

    private func seedComplete(_ flow: OnboardingFlowModel, model: OnboardingModelChoice) {
        flow.preparationChoices = [model]
        flow.selectedModelID = model.id
        flow.downloadCompletedModelID = model.id
        flow.preparationProgress = 1
        flow.preparationPhase = .ready
        flow.providerStartCompleted = true
        flow.verificationPhase = .hardwareTrusted
    }
}
