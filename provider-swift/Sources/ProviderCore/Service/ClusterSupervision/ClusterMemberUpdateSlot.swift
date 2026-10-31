import Foundation

/// Coordinated update for cluster members: drain both, update, re-form.
///
/// A solo provider updates itself on its own schedule. Two members of one pair
/// must not: mixed code across ranks shifts the message stream and desyncs the
/// collectives (the owner's ThunderMLX loop re-synced rank 1 before every
/// relaunch for exactly this reason), and two separate drains would cost the
/// pair two outages. So a member never updates from its serving loop or from
/// the watchdog. Its supervisor checks for a release only at the cluster's
/// update slot: a time derived from the cluster ID alone, the same on both
/// Macs (clocks are network-synchronized), so both members see the same
/// release at the same moment, drain together (the pair dissolves once),
/// install it, and start again; the coordinator re-forms the pair when both
/// have registered and its approval covers the new runtime. If one Mac fails
/// to update, the next slot retries, and until then the approval's pins keep a
/// mixed pair from forming.
public enum ClusterMemberUpdateSlot {
    /// Same cadence as the solo provider's update check.
    public static let periodSeconds: Double = 1800
    /// A pair with work in flight waits this long for it to finish before the
    /// slot is skipped for the next one (the solo updater's drain allowance).
    public static let busyDeferralSeconds: Double = 600

    /// Stable across processes, builds and Macs (Swift's `Hasher` is seeded
    /// per process, so it cannot be used here). FNV-1a, 64-bit.
    public static func stableOffset(clusterID: String, period: Double = periodSeconds) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in clusterID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let whole = UInt64(max(1, period.rounded(.down)))
        return Double(hash % whole)
    }

    /// The first slot strictly after `now`.
    public static func nextSlot(after now: Double, clusterID: String, period: Double = periodSeconds) -> Double {
        let offset = stableOffset(clusterID: clusterID, period: period)
        let index = ((now - offset) / period).rounded(.down)
        return offset + (index + 1) * period
    }

    public enum Decision: Equatable, Sendable {
        /// Nothing to do before `at`.
        case wait(until: Double)
        /// Check for a release now; drain and install if one is available.
        case check
        /// The pair is working on a request; look again shortly.
        case deferBusy(retryAt: Double)
        /// The pair stayed busy past the deferral allowance: skip this slot
        /// and wait for the next one rather than drain a busy pair.
        case skip
    }

    /// `slot` is the slot this supervisor is waiting for; `busy` whether the
    /// pair has a request in flight.
    public static func decide(now: Double, slot: Double, busy: Bool, recheckSeconds: Double = 15) -> Decision {
        guard now >= slot else { return .wait(until: slot) }
        guard busy else { return .check }
        // Past the deferral allowance the slot is abandoned: the caller moves
        // to the next slot instead of draining a busy pair.
        guard now - slot < busyDeferralSeconds else { return .skip }
        return .deferBusy(retryAt: now + recheckSeconds)
    }
}
