import Foundation
import ProviderCoreFoundation

enum EnrollmentEvidence: Equatable, Sendable {
    case enrolled
    case missing(detail: String)
    case conflicting(detail: String)

    static func evaluate(
        report: DoctorJSONReport,
        providerEvidence: OnboardingProviderEvidence
    ) -> Self {
        if let check = report.check(id: "mdm-enrollment") {
            if check.detail.localizedCaseInsensitiveContains("another MDM") {
                return .conflicting(detail: check.detail)
            }
            return check.status == "pass"
                ? .enrolled
                : .missing(detail: check.detail)
        }

        guard let daemonState = providerEvidence.daemonState,
              providerEvidence.processIsAlive,
              !daemonState.isStale(now: providerEvidence.sampledAt.timeIntervalSince1970),
              let trust = daemonState.trust,
              OnboardingTrustGating.verdict(for: trust) == .verified
        else {
            return .missing(detail: "The system check did not report local MDM enrollment evidence.")
        }
        return .enrolled
    }
}
