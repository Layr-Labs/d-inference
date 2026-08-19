import Foundation

extension OnboardingFlowModel {
    func reconcileRestoredProgress() async {
        guard resumeReconciliationState == .required || resumeReconciliationState == .rechecking else {
            return
        }
        if freezesAutomaticProgress {
            await reconcilePreviewProgress()
            return
        }
        await reconcileLiveProgress()
    }

    private func reconcilePreviewProgress() async {
        let revision = operationRevision
        resumeReconciliationState = .rechecking
        guard await pause(.milliseconds(760)) else {
            if revision == operationRevision { resumeReconciliationState = .required }
            return
        }
        guard revision == operationRevision else { return }
        applyPreviewReconciliationOutcome()
    }

    private func reconcileLiveProgress() async {
        guard let diagnosticsRunner, let preparationService else {
            resumeReconciliationState = .unavailable
            return
        }
        let revision = operationRevision
        resumeReconciliationState = .rechecking
        do {
            let doctor = try await diagnosticsRunner.runDoctorJSON()
            guard revision == operationRevision, !Task.isCancelled else { return }

            let readiness = ReadinessEvaluator.evaluate(
                report: doctor,
                facts: readinessFactsProvider()
            )
            applyReadiness(readiness)
            guard readiness.phase.allowsContinuation else {
                step = .readiness
                resumeReconciliationState = .reconciled
                return
            }

            guard doctor.reportsLinkedAccount else {
                accountPhase = .introduction
                step = .account
                resumeReconciliationState = .reconciled
                return
            }
            accountPhase = .linked

            let providerEvidence = providerEvidenceProvider()
            switch EnrollmentEvidence.evaluate(
                report: doctor,
                providerEvidence: providerEvidence
            ) {
            case .enrolled:
                enrollmentPhase = .profileDetected
            case .missing(let detail):
                enrollmentFailureDetail = detail
                enrollmentPhase = .profileMissing
                step = .enrollment
                resumeReconciliationState = .reconciled
                return
            case .conflicting(let detail):
                enrollmentFailureDetail = detail
                conflictingManagementPersists = true
                enrollmentPhase = .conflictingManagement
                step = .enrollment
                resumeReconciliationState = .reconciled
                return
            }

            let restoredModelID = selectedModelID
            let plan = try await preparationService.fetchPlan()
            guard revision == operationRevision, !Task.isCancelled else { return }
            applyPreparationPlan(plan)
            let preparationEvidence = providerEvidenceProvider()
            if restoredModelID == nil {
                let liveModelIDs = [preparationEvidence.daemonState?.currentModel]
                    + (preparationEvidence.daemonState?.warmModels ?? []).map(Optional.some)
                if let liveModelID = liveModelIDs.compactMap({ $0 }).first(where: { candidate in
                    plan.choices.contains { $0.id == candidate && $0.isInstalled }
                }) {
                    selectedModelID = liveModelID
                }
            }
            guard let choice = selectedPreparationChoice else {
                preparationPhase = .noCompatibleModel
                preparationFailureDetail = OnboardingPreparationServiceError.noCompatibleModel.localizedDescription
                step = .preparation
                resumeReconciliationState = .reconciled
                return
            }

            guard choice.isInstalled else {
                downloadCompletedModelID = nil
                providerStartCompleted = false
                preparationPhase = preparationProgress > 0.04 ? .downloadFailed : .choosingModel
                preparationFailureDetail = preparationProgress > 0.04
                    ? "Resume the verified download for \(choice.displayName)."
                    : nil
                step = .preparation
                resumeReconciliationState = .reconciled
                return
            }

            guard preparationEvidence.reportsStarted(modelID: choice.id) else {
                providerStartCompleted = false
                preparationProgress = 1
                preparationPhase = .startFailed
                preparationFailureDetail = "The model is installed, but the provider and local endpoint are not both running. Start them again."
                step = .preparation
                resumeReconciliationState = .reconciled
                return
            }

            providerStartCompleted = true
            downloadCompletedModelID = choice.id
            preparationProgress = 1
            preparationPhase = .ready
            let trust = preparationEvidence.daemonState?.trust
            if let trust {
                switch OnboardingTrustGating.verdict(for: trust) {
                case .verified:
                    verificationPhase = .hardwareTrusted
                    step = .complete
                case .pending:
                    verificationPhase = .trustPending
                    step = .verification
                case .refused:
                    verificationPhase = .trustFailed
                    step = .verification
                case .offline:
                    verificationPhase = .offline
                    step = .verification
                }
            } else {
                verificationPhase = .enrollmentPending
                step = .verification
            }
            resumeReconciliationState = .reconciled
        } catch is CancellationError {
            if revision == operationRevision { resumeReconciliationState = .required }
        } catch OnboardingPreparationServiceError.noCompatibleModel {
            guard revision == operationRevision else { return }
            preparationChoices = []
            selectedModelID = nil
            preparationFailureDetail = OnboardingPreparationServiceError.noCompatibleModel.localizedDescription
            preparationPhase = .noCompatibleModel
            step = .preparation
            resumeReconciliationState = .reconciled
        } catch {
            guard revision == operationRevision else { return }
            preparationFailureDetail = error.localizedDescription
            resumeReconciliationState = .unavailable
        }
    }

    private func applyPreviewReconciliationOutcome() {
        switch reconciliationOutcome {
        case .matched:
            resumeReconciliationState = .reconciled
        case .accountLinkRequired:
            step = .account
            accountPhase = .introduction
            resumeReconciliationState = .reconciled
        case .profileMissing:
            step = .enrollment
            conflictingManagementPersists = false
            enrollmentPhase = .profileMissing
            resumeReconciliationState = .reconciled
        case .trustRequired:
            step = .verification
            verificationPhase = .trustFailed
            resumeReconciliationState = .reconciled
        case .unavailable:
            resumeReconciliationState = .unavailable
        }
    }
}
