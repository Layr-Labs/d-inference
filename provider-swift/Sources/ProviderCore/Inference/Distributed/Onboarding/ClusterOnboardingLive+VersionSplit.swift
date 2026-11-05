import Foundation

/// The two Macs of the pair on different Darkbloom versions (`ClusterOnboardingVersionSplit`): read before the parts
/// start, while the start waits (both windows), before a Retry, and for the status line.
extension OnboardingLive {
    /// This Mac's version against the other Mac's, which its cluster service publishes (`pairUpdate.running`, from a
    /// supervisor of 0.10.7 or later); nil when they match, or the other Mac doesn't answer or say. Answering the other
    /// Mac's screen, the split is said from that screen's side.
    func versionSplit() -> ClusterOnboardingVersionSplit? {
        guard let data = try? command(.init(op: .status), seconds: 10),
              let status = try? JSONDecoder().decode(ClusterServiceStatus.self, from: data) else { return nil }
        let theirs = status.pairUpdate?.running
        // Answering the other Mac's screen, "the other Mac" there is this one (`there` says this Mac then).
        if there == ClusterOnboardingMacName.this {
            return ClusterOnboardingVersionSplit.detect(thisVersion: theirs, otherVersion: ProviderCore.version,
                                                        other: ClusterOnboardingMacName.other)
        }
        return ClusterOnboardingVersionSplit.detect(thisVersion: ProviderCore.version, otherVersion: theirs,
                                                    other: there)
    }
}
