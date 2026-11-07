import Foundation
import ProviderCore

/// The pair's local API beside Darkbloom (Both, me first), as one Mac sees it: whether its own part runs the pair's
/// slot, where that part's local API listens, and that part's me first.
struct ClusterPairLocalAPI: Sendable, Equatable {
    /// Where a local API listens: its address and port, never its key.
    struct Address: Sendable, Equatable {
        var host: String
        var port: UInt16
    }

    /// This Mac's part runs rank 0, the part that hosts the pair's slot and runs its local API.
    var runsRankZero: Bool
    /// Where this Mac's running part listens (its discovery record, written once the API is bound); nil while none.
    var listening: Address?
    /// The running part's me first (`DaemonState.meFirst`); nil when it is off or not known.
    var meFirst: MeFirstSnapshot?
}

extension ClusterPairSummary {
    func localAPILines(now: Date = Date(), timeZone: TimeZone = .current) -> [String] { [] }
}
