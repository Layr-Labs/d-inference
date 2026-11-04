import Foundation

/// An ordinary single-Mac provider serving on one Mac of the pair. It holds that Mac's provider instance lock
/// (`provider.pid.lock`), so neither Mac's part of the pair can start beside it, and it does not end by itself: a start
/// that waited for it would wait forever (a two-Mac pair on 0.10.8 looped "this Mac's part ended … and starts again by
/// itself" for exactly this).
public struct ClusterOnboardingSoloServing: Sendable, Equatable, Codable {
    /// The Mac as the screen names it: "this Mac", "the other Mac (Apple M4 Max, 128 GB)".
    public var mac: String
    /// The provider's process, nil when its lock record names none.
    public var pid: Int32?
    public init(mac: String, pid: Int32?) { self.mac = mac; self.pid = pid }

    /// "a single-Mac Darkbloom provider (process 9523) is serving on this Mac".
    public var clause: String {
        "a single-Mac Darkbloom provider (" + (pid.map { "process \($0)" } ?? "a process it doesn't name") + ") is serving on \(mac)"
    }

    /// The ✗ title for `serving` (one or both Macs): names each Mac and process, and that the pair can't start until it stops.
    public static func title(_ serving: [ClusterOnboardingSoloServing]) -> String {
        let clauses = serving.map(\.clause)
        let joined = clauses.count > 1 ? clauses.dropLast().joined(separator: ", ") + " and " + clauses.last! : clauses.first ?? ""
        return "The pair can't start: " + joined + ", and the pair can't share a Mac with it"
    }

    /// What to run, one line per Mac: `darkbloom stop --solo` stops single-Mac serving only (plain `darkbloom stop` on a
    /// paired Mac stops the pair, not single-Mac serving).
    public static func remedies(_ serving: [ClusterOnboardingSoloServing]) -> [String] {
        serving.map { "On \($0.mac): run `darkbloom stop --solo` to stop single-Mac serving there." }
            + ["Then run `darkbloom start` to start the pair. It won't start by itself while single-Mac serving runs."]
    }

    /// The choice that stops single-Mac serving (on each Mac named) and starts the pair, with the person's consent.
    public static func stopAndStartItem(_ serving: [ClusterOnboardingSoloServing]) -> String {
        Set(serving.map(\.mac)).count > 1 ? "Stop single-Mac serving on both Macs and start the pair"
            : "Stop single-Mac serving on \(serving.first?.mac ?? "this Mac") and start the pair"
    }
}

extension ClusterOnboardingFailure {
    /// The failure a start ends with when single-Mac serving blocks the pair: its title and what to run on each Mac.
    public static func soloServing(_ serving: [ClusterOnboardingSoloServing]) -> ClusterOnboardingFailure {
        var failure = ClusterOnboardingFailure([ClusterOnboardingSoloServing.title(serving) + "."]
            + ClusterOnboardingSoloServing.remedies(serving))
        failure.soloServing = serving
        return failure
    }
}
