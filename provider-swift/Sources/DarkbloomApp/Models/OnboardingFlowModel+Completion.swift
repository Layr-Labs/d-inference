extension OnboardingFlowModel {
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
