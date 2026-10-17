import Foundation

/// The guided link flow's reading of one link report: the same lines
/// `darkbloom cluster setup` prints, and what that flow would do next.
public struct ClusterConsoleLinkSetup: Encodable, Sendable, Equatable {
    public enum Next: String, Encodable, Sendable {
        case ready
        case awaitConnection
        /// The system job that keeps the port's address is running and is
        /// about to put the address back; the flow waits for it once before
        /// it asks for anything.
        case awaitKeeper
        case fix
        case stopped
    }
    public let lines: [String]
    public let next: Next
    /// The device the flow would fix: now when `next` is `fix`, and once the
    /// wait is over without the address when it is `awaitKeeper`.
    public let fixDevice: String?

    /// How many unchanged link readings the flow allows the keeper before it
    /// asks for the fix after all: the wait `darkbloom cluster setup` makes.
    static let keeperReadings = max(1, ClusterLinkSetupFlow.keeperWaitSeconds / ClusterLinkWatch.pollIntervalSeconds)

    /// `mayPrompt` is the flow's own switch: with it the flow waits for a
    /// cable and plans the approval-gated fix; without it the flow only says
    /// what it found and what to run. `temporary` and `dryRun` are the
    /// flow's too, and word what a fix would do.
    static func make(report: ClusterLinkReadinessReport, mayPrompt: Bool, temporary: Bool = false,
                     dryRun: Bool = false) -> ClusterConsoleLinkSetup {
        var flow = ClusterLinkSetupFlow(mayPrompt: mayPrompt, temporary: temporary, dryRun: dryRun)
        let step = flow.observed(report)
        switch step.action {
        case .awaitConnection: return .init(lines: step.lines, next: .awaitConnection, fixDevice: nil)
        case .awaitKeeper:
            // The same flow, shown the same link again, says what follows the wait.
            var after: String?
            if case .fix(let device) = flow.observed(report).action { after = device }
            return .init(lines: step.lines, next: .awaitKeeper, fixDevice: after)
        case .fix(let device): return .init(lines: step.lines, next: .fix, fixDevice: device)
        case .finish(let exitCode): return .init(lines: step.lines, next: exitCode == 0 ? .ready : .stopped, fixDevice: nil)
        case .inspect: return .init(lines: step.lines, next: .stopped, fixDevice: nil)
        }
    }
}

/// One run of the link fix, as the console asks for it.
public struct ClusterConsoleLinkFix: Sendable, Equatable {
    /// Nil lets the fix choose the one port that qualifies.
    public let device: String?
    /// The address alone, without the system job that keeps it.
    public let temporary: Bool
    /// Work out what an approval would run, and ask for nothing.
    public let dryRun: Bool

    public init(device: String?, temporary: Bool, dryRun: Bool) {
        self.device = device; self.temporary = temporary; self.dryRun = dryRun
    }
}
