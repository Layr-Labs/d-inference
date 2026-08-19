import Foundation
import ProviderCoreFoundation

extension OnboardingFlowModel {
    func retryVerification() async {
        verificationPhase = .profileDetected
        await runVerification()
    }

    func runVerification() async {
        guard verificationPhase == .profileDetected
            || verificationPhase == .enrollmentPending
            || verificationPhase == .trustPending
        else { return }
        let revision = operationRevision
        if verificationPhase == .profileDetected {
            verificationPhase = .enrollmentPending
        }
        let checkInDelayedAt = ContinuousClock.now + verificationCheckInGrace
        while revision == operationRevision, !Task.isCancelled {
            let evidence = providerEvidenceProvider()
            if let trust = liveSelectedProviderTrust(from: evidence) {
                switch OnboardingTrustGating.verdict(for: trust) {
                case .verified:
                    verificationPhase = .hardwareTrusted
                    return
                case .refused:
                    verificationPhase = .trustFailed
                    return
                case .offline:
                    verificationPhase = .offline
                    return
                case .pending:
                    if verificationPhase != .trustPending {
                        verificationPhase = .trustPending
                    }
                }
            } else if verificationPhase == .enrollmentPending,
                      ContinuousClock.now >= checkInDelayedAt {
                verificationPhase = .checkInDelayed
            }
            guard await pause(verificationPollInterval), revision == operationRevision else { return }
        }
    }

    func hasLiveVerifiedSelectedProvider() -> Bool {
        guard let trust = liveSelectedProviderTrust(from: providerEvidenceProvider()) else {
            return false
        }
        return OnboardingTrustGating.verdict(for: trust) == .verified
    }

    private func liveSelectedProviderTrust(
        from evidence: OnboardingProviderEvidence
    ) -> DaemonState.Trust? {
        guard let selectedModelID,
              evidence.reportsStarted(modelID: selectedModelID)
        else { return nil }
        return evidence.daemonState?.trust
    }
}
