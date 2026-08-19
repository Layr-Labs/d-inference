import Foundation
import ProviderCoreFoundation

/// How onboarding's verification step classifies the daemon's latest
/// coordinator trust status, read from `daemon-state.json`.
///
/// The vocabulary mirrors `DaemonSnapshotMapping.mapTrust` (which renders the
/// product's trust badge from the same file) so first-run gating and the
/// product surface always agree: `verified` when the coordinator grants
/// hardware trust (status "verified" or trustLevel "hardware"/"mda_verified"),
/// failing for the gating statuses ("untrusted", "offline", "denied",
/// "failed"), pending otherwise. Onboarding splits the failing set one step
/// finer because its recovery copy differs: "offline" means the
/// provider↔coordinator link is down (retry from here), the rest are trust
/// refusals (re-run the security check).
enum OnboardingTrustVerdict: Equatable, Sendable {
    case pending
    case verified
    case refused
    case offline
}

enum OnboardingTrustGating {
    /// Failing trust statuses, mirrored from `DaemonSnapshotMapping`.
    private static let failingStatuses: Set<String> = ["untrusted", "offline", "denied", "failed"]

    static func verdict(for trust: DaemonState.Trust) -> OnboardingTrustVerdict {
        let status = trust.status.lowercased()
        if status == "verified" || trust.trustLevel == "hardware" || trust.trustLevel == "mda_verified" {
            return .verified
        }
        if failingStatuses.contains(status) {
            return status == "offline" ? .offline : .refused
        }
        return .pending
    }
}
