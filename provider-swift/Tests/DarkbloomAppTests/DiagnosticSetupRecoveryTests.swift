import Testing
@testable import DarkbloomApp

@Suite("Diagnostic setup recovery after completed onboarding")
@MainActor
struct DiagnosticSetupRecoveryTests {
    @Test("Finish Setup rechecks a completed walkthrough and finds a removed profile")
    func removedProfileAfterCompletion() async throws {
        let model = OnboardingOperationTestFixture.model(installed: true)
        let service = OnboardingOperationTestPreparation(model: model)
        let evidence = OnboardingOperationTestEvidence(OnboardingOperationTestEvidence.running(modelID: model.id))
        let flow = OnboardingOperationTestFixture.flow(
            step: .complete, service: service, evidence: evidence,
            diagnostics: .init(enrolled: false)
        )
        flow.preparationChoices = [model]
        flow.selectedModelID = model.id
        flow.downloadCompletedModelID = model.id
        flow.preparationProgress = 1
        flow.preparationPhase = .ready
        flow.providerStartCompleted = true
        flow.verificationPhase = .hardwareTrusted
        let preferences = InMemoryAppFlowPreferences()
        let app = AppFlowStore(preferences: preferences, launchOverride: nil, onboardingFlow: flow)
        app.startOnboarding()
        #expect(app.completeOnboarding())
        #expect(flow.step == .complete)
        #expect(app.resumableOnboardingDraft == nil)

        let (diagnostics, _) = try await scannedDiagnosticActionStore(
            checkID: "mdm-enrollment", section: "trust", advice: "Run darkbloom enroll."
        )
        let fix = try #require(diagnostics.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let callbacks = DiagnosticActionCallbacks(
            isPreview: false, restartUnavailableReason: nil,
            onContinueSetup: { _ = app.requestNetworkSetup(localSessionIsActive: false) },
            requestProviderAction: { _ in Issue.record("Unexpected provider action") },
            openModelLibrary: { _ in Issue.record("Unexpected Library navigation") },
            openNetworkSettings: { Issue.record("Unexpected Settings launch") }
        )
        var dismissed = false
        _ = dispatcher.open(fix, in: diagnostics, callbacks: callbacks, dismiss: { dismissed = true })
        #expect(dismissed)
        #expect(app.phase == .product)
        try dispatcher.didDismiss(store: diagnostics, callbacks: callbacks)
        #expect(app.phase == .onboarding)
        #expect(flow.step != .complete)
        #expect(flow.resumeReconciliationState == .required)
        #expect(!flow.canContinue)
        #expect(flow.selectedModelID == model.id)

        // The same work is driven by OnboardingFlowView.task when it opens.
        await flow.reconcileRestoredProgress()
        #expect(flow.step == .enrollment)
        #expect(flow.enrollmentPhase == .profileMissing)
        #expect(flow.resumeReconciliationState == .reconciled)
        #expect(!flow.hasCompletedAllRequiredSteps)
        #expect(await service.startedModelIDs.isEmpty)
        #expect(await service.downloadedModelIDs.isEmpty)
        app.leaveOnboarding()
        #expect(app.phase == .product)
    }

    @Test("A previously completed app rechecks setup after relaunch")
    func completedPreferenceRequiresCurrentEvidence() async {
        let model = OnboardingOperationTestFixture.model(installed: true)
        let service = OnboardingOperationTestPreparation(model: model)
        let flow = OnboardingOperationTestFixture.flow(
            step: .readiness, service: service, diagnostics: .init(enrolled: false)
        )
        let app = AppFlowStore(
            preferences: InMemoryAppFlowPreferences(hasCompletedNetworkOnboarding: true),
            launchOverride: nil, onboardingFlow: flow
        )
        #expect(app.requestNetworkSetup(localSessionIsActive: false))
        #expect(flow.resumeReconciliationState == .required)
        await flow.reconcileRestoredProgress()
        #expect(flow.step == .enrollment)
        #expect(flow.enrollmentPhase == .profileMissing)
        #expect(await service.startedModelIDs.isEmpty)
    }
}
