extension OnboardingFlowModel {
    /// Call synchronously when AppFlowStore.completeOnboarding returns false.
    /// Changing the step restarts OnboardingFlowView's reconciliation task and
    /// restores its Back control. This method never launches a provider.
    @discardableResult
    func recoverRejectedCompletion() -> Bool {
        guard step == .complete else { return false }
        let wasApplyingDraft = isApplyingDraft
        isApplyingDraft = true
        cancelPendingOperations()
        providerStartCompleted = false
        verificationPhase = .profileDetected
        requireResumeReconciliation()

        if let selectedModelID, providerEvidenceProvider().reportsStarted(modelID: selectedModelID) {
            step = .verification
        } else {
            preparationPhase = selectedModelID == nil ? .reservingSpace : .startFailed
            preparationFailureDetail = "The provider or local endpoint changed. Recheck setup before continuing."
            step = .preparation
        }
        isApplyingDraft = wasApplyingDraft
        publishDraft()
        return true
    }

    var hasCompletedAllRequiredSteps: Bool {
        step == .complete
            && readinessPhase.allowsContinuation
            && accountPhase == .linked
            && enrollmentPhase == .profileDetected
            && preparationPhase == .ready
            && (freezesAutomaticProgress || providerStartCompleted)
            && verificationPhase == .hardwareTrusted
            && (freezesAutomaticProgress || hasLiveVerifiedSelectedProvider())
            && !resumeReconciliationState.blocksProgress
    }
}
