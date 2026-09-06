extension OnboardingFlowModel {
    func isCurrentOperation(_ revision: Int) -> Bool {
        revision == operationRevision && !Task.isCancelled
    }

    func cancelPendingOperations() {
        operationRevision &+= 1
        accountLinkTask?.cancel()
        accountLinkTask = nil
        accountLinkRequestInFlight = false
        enrollmentPollTask?.cancel()
        enrollmentPollTask = nil
        enrollmentPollSession = nil
        preparationTask?.cancel()
        preparationTask = nil

        guard !freezesAutomaticProgress else { return }
        // Update the current model as well as its persisted projection. A Back
        // followed by Continue reuses this instance without restoring a draft.
        let previousDraft = draft
        let wasApplyingDraft = isApplyingDraft
        isApplyingDraft = true

        if accountPhase == .waitingForApproval || accountPhase == .confirming {
            accountPhase = .introduction
            accountLinkFailureDetail = nil
        }
        if enrollmentPhase == .requestingProfile {
            enrollmentPhase = .overview
        } else if enrollmentPhase == .detectingProfile {
            enrollmentPhase = .systemSettingsOpen
        }

        switch preparationPhase {
        case .downloading, .verifying:
            if let selectedModelID, downloadCompletedModelID == selectedModelID {
                preparationPhase = .startFailed
                preparationFailureDetail = "The download finished. Start the provider when you’re ready."
            } else {
                preparationPhase = .downloadFailed
                preparationFailureDetail = "The download was paused. Resume it to keep your verified partial files."
            }
        case .startingProvider:
            preparationPhase = .startFailed
            preparationFailureDetail = "Startup was interrupted. Try starting the provider again."
            providerStartCompleted = false
        case .loadingCatalog:
            preparationPhase = .reservingSpace
        default:
            break
        }

        if verificationPhase == .enrollmentPending || verificationPhase == .trustPending {
            verificationPhase = .profileDetected
        }
        if resumeReconciliationState == .rechecking {
            resumeReconciliationState = .required
        }

        isApplyingDraft = wasApplyingDraft
        // Explore on a fresh welcome screen must not create a setup draft.
        if draft != previousDraft { publishDraft() }
    }
}
