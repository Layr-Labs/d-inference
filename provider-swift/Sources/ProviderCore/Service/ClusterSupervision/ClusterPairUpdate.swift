import Foundation

/// The coordinated update of a `darkbloom cluster` pair as each Mac's cluster service supervisor runs it
/// (`ClusterPairUpdateCycle`): when the other Mac lets this one go on.
///
/// Both Macs check for a release at the cluster's update slot (`ClusterMemberUpdateSlot`) and stage it while the pair
/// serves. Neither stops taking requests before the other has the same release on disk, and neither installs before
/// both have drained: the Mac whose part serves the pair finishes its accepted requests, and the other Mac's part
/// serves none of its own. A release one Mac cannot download, verify or stage is installed on neither, and a request
/// still running at the drain bound reopens the pair on both Macs; both retry at the next slot. Each Mac publishes its
/// progress (`ClusterPairUpdateProgress`) in its cluster service's status, which the other Mac reads over the link.
public enum ClusterPairUpdate {
    /// How long a Mac waits, from the start of its cycle, for the other Mac to have the release on disk too.
    public static let partnerStageWaitSeconds: Double = 900
    /// How long the part that serves the pair may take to finish its accepted requests once it stopped taking new
    /// ones: the single-Mac updater's drain allowance (`ProviderLoop.updateDrainTimeout`).
    public static let drainTimeoutSeconds: Double = 120
    /// From the start of its drain, how long a Mac waits for the other Mac to have drained too.
    public static let partnerDrainWaitSeconds: Double = drainTimeoutSeconds + 60
    /// How long a part that drained keeps refusing requests while neither its stop nor a release arrives (its
    /// supervisor went away): it then takes requests again.
    public static let drainedHoldSeconds: Double = 900
    /// A progress in a working phase not rewritten for this long is from a supervisor that stopped.
    public static let progressStaleSeconds: Double = 60
    /// How often a supervisor in a cycle rewrites its progress and reads the other Mac's.
    public static let pollSeconds: Double = 5
    /// How often a supervisor with no cycle running asks whether the other Mac rolled back the release this Mac runs
    /// (`ClusterPairUpdateCycle.followRollback`).
    public static let followCheckSeconds: Double = 60

    /// The other Mac as this Mac reads it.
    public enum Partner: Equatable, Sendable {
        case reported(ClusterPairUpdateProgress)
        /// It answered with a build that reports no update progress, so it cannot coordinate one.
        case silent
        /// No pairing, or its cluster service did not answer.
        case unreachable
    }

    /// What this Mac waits for: the release on the other Mac's disk, or the other Mac drained.
    public enum Step: Sendable {
        case staged
        case drained
    }

    public enum PartnerState: Equatable, Sendable {
        /// The other Mac is at `step` for this release, or runs it already.
        case ready
        case waiting
        /// The other Mac gave this release up (or will not take it); this Mac gives it up too.
        case gaveUp(String)
        /// The other Mac cannot be asked: this Mac goes on alone only when no pair runs on it.
        case cannotCoordinate
    }

    /// Whether `partner` lets this Mac's cycle for `target`, started at `cycleStartedAt`, go past `step`. `requested`:
    /// the cycle answers `darkbloom update`, which is run on the other Mac too.
    public static func partnerState(_ partner: Partner, target: String, step: Step, cycleStartedAt: Double,
                                    now: Double, requested: Bool = false) -> PartnerState {
        guard case .reported(let progress) = partner else { return .cannotCoordinate }
        if progress.running == target { return .ready }
        // The other Mac rolled this release back: it will not install it, so neither does this Mac. A cycle
        // `darkbloom update` asked for waits instead, while serving, for the other Mac's (`--override-quarantine`).
        if progress.quarantined == target {
            return requested && step == .staged ? .waiting : .gaveUp("the other Mac quarantined v\(target)")
        }
        switch progress.phase {
        case .disabled:
            // Its slot never comes, but its own `darkbloom update` may: a requested cycle waits for it while serving.
            if requested, step == .staged { return .waiting }
            return .gaveUp("automatic updates are off on the other Mac")
        case .idle:
            // Its cycle may not have started yet: the two Macs reach the slot seconds apart.
            return .waiting
        case .deferred, .failed:
            // An end written before this cycle started belongs to an earlier one.
            guard progress.writtenAt >= cycleStartedAt, progress.target == nil || progress.target == target else { return .waiting }
            return .gaveUp("the other Mac: " + progress.line)
        case .checking, .staged, .draining, .drained, .restarting:
            guard now - progress.writtenAt <= progressStaleSeconds else { return .cannotCoordinate }
            guard let theirs = progress.target else { return .waiting }
            guard theirs == target else { return .gaveUp("the other Mac installs v\(theirs), not v\(target)") }
            switch step {
            case .staged: return progress.phase == .checking ? .waiting : .ready
            case .drained: return progress.phase == .drained || progress.phase == .restarting ? .ready : .waiting
            }
        }
    }

    /// A single-Mac updater (the provider's background updater) installed a release on a Mac whose pair runs here
    /// (`ClusterService.pairServesHere`, the actual state, not the saved start): this Mac's cluster service supervisor is
    /// asked to restart into it together with the other Mac, as `darkbloom update` asks, and the other Mac's follow check
    /// sees this Mac updating and follows (`ClusterPairUpdateCycle.ahead`). A Mac whose pair doesn't run here (it serves
    /// alone, its pair gone) simply updates. True when asked.
    @discardableResult
    public static func askPairToFollow(pairServes: Bool, requestPath: URL?, now: Double) -> Bool {
        guard pairServes, let requestPath else { return false }
        return writeRequest(Request(createdAt: now), to: requestPath)
    }

    /// `darkbloom update` on a cluster Mac: restart into the release it installed, together with the other Mac.
    public struct Request: Codable, Equatable, Sendable {
        public var id: String
        public var createdAt: Double
        /// A request older than this is from a command that is long gone.
        public static let maximumAgeSeconds: Double = 3600

        public init(id: String = UUID().uuidString, createdAt: Double) {
            self.id = id
            self.createdAt = createdAt
        }

        public func isCurrent(now: Double) -> Bool {
            now - createdAt >= -5 && now - createdAt <= Self.maximumAgeSeconds
        }
    }

    public static func readProgress(from url: URL) -> ClusterPairUpdateProgress? {
        ClusterSupervisionFiles.read(ClusterPairUpdateProgress.self, from: url)
    }

    @discardableResult
    public static func writeProgress(_ progress: ClusterPairUpdateProgress, to url: URL) -> Bool {
        ClusterSupervisionFiles.write(progress, to: url)
    }

    @discardableResult
    public static func writeRequest(_ request: Request, to url: URL) -> Bool {
        ClusterSupervisionFiles.write(request, to: url)
    }

    /// The pending request, removed so it is answered once; nil when there is none or it is stale.
    public static func takeRequest(from url: URL, now: Double) -> Request? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request = ClusterSupervisionFiles.read(Request.self, from: url)
        try? FileManager.default.removeItem(at: url)
        return request.flatMap { $0.isCurrent(now: now) ? $0 : nil }
    }
}
