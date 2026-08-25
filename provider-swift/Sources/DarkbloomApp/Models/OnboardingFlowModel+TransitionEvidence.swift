import Foundation

extension OnboardingFlowModel {
    /// Advances only after re-sampling the machine evidence that authorizes the
    /// current transition. Rendered success phases are not authority: a profile
    /// can be removed, a daemon can exit, and trust can be revoked while the
    /// user is looking at a completed step.
    func continueToNextStep() async {
        guard canContinue else { return }
        if freezesAutomaticProgress {
            advanceToNextStep()
            return
        }

        let revision = operationRevision
        transitionEvidenceCheckInFlight = true
        defer { transitionEvidenceCheckInFlight = false }

        let evidenceIsCurrent: Bool
        switch step {
        case .readiness:
            evidenceIsCurrent = await refreshReadinessTransitionEvidence(
                revision: revision
            )
        case .account:
            evidenceIsCurrent = await refreshAccountTransitionEvidence(
                revision: revision
            )
        case .enrollment:
            evidenceIsCurrent = await checkEnrollmentEvidence(markMissing: true)
                && enrollmentPhase == .profileDetected
        case .preparation:
            evidenceIsCurrent = refreshPreparationTransitionEvidence()
        case .verification:
            evidenceIsCurrent = await refreshCompletionTransitionEvidence(
                revision: revision
            )
        case .complete:
            evidenceIsCurrent = false
        }

        guard evidenceIsCurrent,
              revision == operationRevision,
              !Task.isCancelled
        else { return }
        advanceToNextStep()
    }

    private func refreshReadinessTransitionEvidence(
        revision: Int
    ) async -> Bool {
        guard let diagnosticsRunner else {
            applyReadiness(.unavailable("The system-check service is unavailable."))
            return false
        }
        do {
            let report = try await diagnosticsRunner.runDoctorJSON()
            guard revision == operationRevision, !Task.isCancelled else {
                return false
            }
            let evaluation = ReadinessEvaluator.evaluate(
                report: report,
                facts: readinessFactsProvider()
            )
            applyReadiness(evaluation)
            return evaluation.phase.allowsContinuation
        } catch is CancellationError {
            return false
        } catch {
            guard revision == operationRevision else { return false }
            applyReadiness(.unavailable(error.localizedDescription))
            return false
        }
    }

    private func refreshAccountTransitionEvidence(
        revision: Int
    ) async -> Bool {
        guard let diagnosticsRunner else {
            accountLinkFailureDetail =
                "The system-check service is unavailable, so account linkage could not be rechecked."
            return false
        }
        do {
            let report = try await diagnosticsRunner.runDoctorJSON()
            guard revision == operationRevision, !Task.isCancelled else {
                return false
            }
            guard report.reportsLinkedAccount else {
                accountLinkFailureDetail =
                    "This Mac no longer reports a linked provider account. Link it again to continue."
                accountPhase = .introduction
                return false
            }
            accountLinkFailureDetail = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard revision == operationRevision else { return false }
            accountLinkFailureDetail = error.localizedDescription
            return false
        }
    }

    private func refreshPreparationTransitionEvidence() -> Bool {
        guard let selectedModelID,
              providerEvidenceProvider().reportsStarted(modelID: selectedModelID)
        else {
            providerStartCompleted = false
            preparationPhase = .startFailed
            preparationFailureDetail =
                "The provider or local endpoint stopped before setup continued. Start it again."
            return false
        }
        return true
    }

    private func refreshCompletionTransitionEvidence(
        revision: Int
    ) async -> Bool {
        guard let diagnosticsRunner else {
            verificationPhase = .trustFailed
            return false
        }
        do {
            let report = try await diagnosticsRunner.runDoctorJSON()
            guard revision == operationRevision, !Task.isCancelled else {
                return false
            }

            let readiness = ReadinessEvaluator.evaluate(
                report: report,
                facts: readinessFactsProvider()
            )
            applyReadiness(readiness)
            guard readiness.phase.allowsContinuation else {
                step = .readiness
                return false
            }
            guard report.reportsLinkedAccount else {
                accountLinkFailureDetail =
                    "This Mac no longer reports a linked provider account. Link it again to continue."
                accountPhase = .introduction
                step = .account
                return false
            }

            switch EnrollmentEvidence.evaluate(report: report) {
            case .enrolled:
                enrollmentFailureDetail = nil
                enrollmentPhase = .profileDetected
            case .conflicting(let detail):
                enrollmentFailureDetail = detail
                conflictingManagementPersists = true
                enrollmentPhase = .conflictingManagement
                step = .enrollment
                return false
            case .missing(let detail):
                enrollmentFailureDetail = detail
                enrollmentPhase = .profileMissing
                step = .enrollment
                return false
            }

            return hasLiveVerifiedSelectedProvider()
        } catch is CancellationError {
            return false
        } catch {
            guard revision == operationRevision else { return false }
            verificationPhase = .trustFailed
            return false
        }
    }
}
