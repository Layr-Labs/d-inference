import Foundation

extension OnboardingFlowModel {
    func retryReadinessChecks() async {
        readinessCompletedCount = 0
        readinessPhase = .checking
        readinessItems = Self.previewReadinessItems(completedCount: 0, phase: .checking)

        if freezesAutomaticProgress, let immutableReadinessFailure {
            let revision = operationRevision
            guard await pause(.milliseconds(240)), revision == operationRevision else { return }
            readinessCompletedCount = immutableReadinessFailure.issueItemIndex ?? 0
            readinessPhase = immutableReadinessFailure
            readinessItems = Self.previewReadinessItems(
                completedCount: readinessCompletedCount,
                phase: immutableReadinessFailure
            )
            return
        }
        await runReadinessChecks()
    }

    func returnToReadinessForSystemCheck() {
        cancelPendingOperations()
        readinessCompletedCount = 0
        readinessPhase = .checking
        readinessItems = Self.previewReadinessItems(completedCount: 0, phase: .checking)
        step = .readiness
    }

    func runReadinessChecks() async {
        guard readinessPhase == .checking else { return }
        if freezesAutomaticProgress {
            let revision = operationRevision
            while readinessCompletedCount < Self.readinessItemCount {
                guard await pause(.milliseconds(240)), revision == operationRevision else { return }
                readinessCompletedCount += 1
                readinessItems = Self.previewReadinessItems(
                    completedCount: readinessCompletedCount,
                    phase: .checking
                )
            }
            readinessPhase = .ready
            readinessItems = Self.previewReadinessItems(
                completedCount: readinessCompletedCount,
                phase: .ready
            )
            return
        }

        guard let diagnosticsRunner else {
            let evaluation = ReadinessEvaluator.unavailable("The system-check service is unavailable.")
            applyReadiness(evaluation)
            return
        }
        let revision = operationRevision
        do {
            let report = try await diagnosticsRunner.runDoctorJSON()
            guard revision == operationRevision, !Task.isCancelled else { return }
            applyReadiness(ReadinessEvaluator.evaluate(
                report: report,
                facts: readinessFactsProvider()
            ))
        } catch is CancellationError {
            return
        } catch {
            guard revision == operationRevision else { return }
            applyReadiness(ReadinessEvaluator.unavailable(error.localizedDescription))
        }
    }

    func applyReadiness(_ evaluation: ReadinessEvaluation) {
        readinessItems = evaluation.items
        readinessCompletedCount = evaluation.completedCount
        readinessPhase = evaluation.phase
    }
}
