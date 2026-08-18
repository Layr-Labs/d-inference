extension OnboardingFlowModel {
    var hasCompletedAllRequiredSteps: Bool {
        step == .complete
            && readinessPhase.allowsContinuation
            && accountPhase == .linked
            && enrollmentPhase == .profileDetected
            && verificationPhase == .hardwareTrusted
            && !resumeReconciliationState.blocksProgress
    }
}
