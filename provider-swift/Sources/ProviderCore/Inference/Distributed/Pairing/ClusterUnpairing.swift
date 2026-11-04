import DarkbloomClusterSecurity
import Foundation

/// Unpairing this Mac from the Mac with `peerPin`, as `darkbloom cluster pair --forget` and the onboarding's Pair
/// again both do it, in this order: a leader tells its member first, while the pairing still keys the link (the member
/// reclaims the pair's prefix records and stops its part); then the pairing is removed (the trust anchor, then the link
/// key); with no pairing left, this Mac's cluster service no longer starts at login; then this Mac's pair prefix records
/// are reclaimed (a live rank's are kept).
public enum ClusterUnpairing {
    /// What followed the unpairing.
    public struct Outcome: Sendable {
        /// The cluster service was stopped and no longer starts at login.
        public var serviceRemoved = false
        /// Why the service could not be removed from login, when it could not.
        public var serviceProblem: String?
        /// The pair prefix records reclaimed here; nil when the provider configuration names no prefix tier.
        public var reclaim: ClusterPrefixSSDReclaim.Report?
    }

    /// The pairing was not removed; `memberLine` is what the member said before (a leader tells it first).
    public struct Failure: Error, CustomStringConvertible {
        public var memberLine: String?
        public var description: String
    }

    /// `unpaired` gets the removed pairing and the member's answer when this Mac led it
    /// (`ClusterService.tellMemberOfUnpair`) as soon as the pairing is removed: removing the service from login next can
    /// wait minutes while this Mac's part releases its model.
    public static func run(peerPin: String, executable: URL, providerConfiguration: URL?,
                           unpaired: (_ removed: ClusterPairingRecord, _ memberLine: String?) -> Void = { _, _ in }) throws -> Outcome {
        let store = ClusterPairingStore.default()
        let memberLine = ClusterService.tellMemberOfUnpair(peerPin: peerPin)
        let removed: ClusterPairingRecord
        do { removed = try store.forget(peerPin: peerPin) } catch { throw Failure(memberLine: memberLine, description: "\(error)") }
        unpaired(removed, memberLine)
        var outcome = Outcome()
        if ClusterService.holdsNoPairing(store: store) {
            do { outcome.serviceRemoved = !(try ClusterService.removeFromLogin(executable: executable)).isEmpty }
            catch { outcome.serviceProblem = "\(error)" }
        }
        if let providerConfiguration, let settings = try? ClusterPrefixCacheSettings.resolved(providerConfiguration: providerConfiguration) {
            outcome.reclaim = ClusterPrefixSSDReclaim.reclaim(root: settings.root)
        }
        return outcome
    }
}
