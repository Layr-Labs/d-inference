import ArgumentParser
import Foundation
import ProviderCore

/// What `darkbloom start`, `stop` and `restart` ask of a two-Mac cluster. On the Mac that follows, each request goes to
/// the leading Mac over the cable (`ClusterOnboardingOperations` routes it), as the menu's Stop does.
struct ClusterPairActions: Sendable {
    var resume: @Sendable () -> ClusterOnboardingResume
    var ensureService: @Sendable () -> Result<Void, ClusterOnboardingFailure>
    var serve: @Sendable () -> Result<[String], ClusterOnboardingFailure>
    var stop: @Sendable () -> Result<[String], ClusterOnboardingFailure>
    var verifyTeardown: @Sendable () -> Result<[String], ClusterOnboardingFailure>
    /// Single-Mac serving on either Mac, and its stop with consent (`stop --solo` on the wrong Mac).
    var soloServing: @Sendable () -> [ClusterOnboardingSoloServing] = { [] }
    var stopSoloServing: @Sendable () -> Result<[String], ClusterOnboardingFailure> = { .failure(.init("not available")) }

    /// Tests give the commands actions of their own.
    @TaskLocal static var forTesting: ClusterPairActions?

    /// This Mac's cluster, nil when it can't be reached from here. Never this Mac's real cluster while a test gives the
    /// pair (`ClusterPairSummary.readsThisMacsCluster`).
    static func live(config: String?, worker: String? = nil) -> ClusterPairActions? {
        if let actions = forTesting { return actions }
        guard ClusterPairSummary.readsThisMacsCluster,
              let operations = try? ClusterOnboardingOperations.live(.clusterService(config: config, worker: worker)) else { return nil }
        var actions = ClusterPairActions(resume: operations.resume, ensureService: operations.ensureService, serve: operations.serve,
                                         stop: operations.stop, verifyTeardown: operations.verifyTeardown)
        actions.soloServing = operations.soloServing
        actions.stopSoloServing = operations.stopSoloServing
        return actions
    }
}

extension ClusterOnboardingOperations.LiveSettings {
    /// This Mac's cluster as its cluster service runs it (`darkbloom cluster service`, without an onboarding request):
    /// what the paired-Mac commands act on or ask (`darkbloom stop`, `start`, `restart` and `status`, `cluster stop`
    /// and `cluster status`).
    static func clusterService(config: String?, worker: String?) throws -> Self {
        .init(service: try Cluster.Setup.serviceSettings(config: config, modelDir: nil, worker: worker),
              serviceArguments: ClusterServiceAgentPlan.childArguments(
                  serviceOptions: ClusterServiceAgentPlan.serviceOptions(config: config, worker: worker)))
    }
}

/// `darkbloom start`, `stop`, `restart` and `status` on a Mac in a two-Mac cluster control the pair, as the same
/// commands control single-Mac serving on one Mac; `--solo` keeps single-Mac serving on this Mac.
enum ClusterPairCommands {
    typealias Say = @Sendable (String) -> Void
    static let printLine: Say = { line in print(line); fflush(stdout) }

    /// How long a start without a terminal waits for the pair to serve, and how often it looks.
    struct Wait: Sendable {
        var seconds: Double
        var interval: Double
        /// How long the same status may stay unchanged before the wait says it again.
        var heartbeat: Double = 60
        static let standard = Wait(seconds: 600, interval: 5)
        /// How long `stop` waits for both parts to end (the member stops its part after acknowledging).
        static let teardown = Wait(seconds: 60, interval: 3)
        /// How long `restart` waits for both parts to release their memory, as the screen's model change does.
        static let restartTeardown = Wait(seconds: 300, interval: 3)
    }

    /// Tests see the call instead of the screen, choose whether a terminal is attached, and how long a start waits.
    @TaskLocal static var screenForTesting: (@Sendable (_ config: String?) async throws -> Void)?
    @TaskLocal static var terminalForTesting: Bool?
    @TaskLocal static var waitForTesting: Wait?
    /// How long a blocking request may run before the command says what it waits for (tests make it short).
    @TaskLocal static var progressAfterForTesting: Double?
    /// How long a blocking request runs before the command says what it waits for: 3 s, or the test's, read where a
    /// test binds it (detached tasks don't inherit it).
    static var progressDelay: Double { progressAfterForTesting ?? 3 }

    /// Whether a person is at a terminal (standard input and output): `darkbloom start` then opens the screen.
    static func isTerminal() -> Bool {
        terminalForTesting ?? (isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1)
    }

    /// `darkbloom start` in a terminal: exactly what `darkbloom cluster` runs on this Mac (the setup command's run path).
    static func openScreen(config: String?) async throws {
        if let screen = screenForTesting { return try await screen(config) }
        var setup = try Cluster.Setup.parse(config.map { ["--config", $0] } ?? [])
        try await setup.run()
    }

    /// `darkbloom stop` (and `darkbloom cluster stop`): the pair stops on both Macs and is saved as stopped, so neither
    /// Mac serves it again at login or after a restart. Both cluster services stay up, idle with nothing loaded, so
    /// `darkbloom start` on either Mac brings the pair back.
    /// The Mac that follows always asks the leading Mac (its own record may lag; the stop is idempotent). "Stopped on both
    /// Macs" is said only once both report nothing left running (the member stops its part after acknowledging), else
    /// "Asked both Macs to stop" with what is left, exit 1.
    static func stop(_ pair: ClusterPairSummary, actions: ClusterPairActions?, teardown: Wait = .teardown,
                     progressAfter: Double = progressDelay, say: @escaping Say = printLine) -> Int32 {
        say(pair.actingLine("stopping both Macs"))
        guard let actions else { say(ClusterPairSummary.unreachableLine); return 1 }
        let role = actions.resume().role
        if case .failure(let failure) = saying(stopWaitLine, after: progressAfter, say: say, actions.stop) {
            sayStopFailed(failure, role: role, say: say)
            return 1
        }
        switch awaitTeardown(actions, wait: teardown, say: say) {
        case .success(let lines) where ClusterPairSummary.bothFreed(lines):
            say(ClusterPairSummary.stoppedLine)
            say(ClusterPairSummary.memoryFreedLine)
            return 0
        case .success(let lines):
            say(ClusterPairSummary.stopAskedLine)
            for line in ClusterPairSummary.memoryLines(lines) { say(line) }
            return 1
        case .failure(let failure):
            say(ClusterPairSummary.stopAskedLine)
            say(ClusterPairSummary.memoryNotCheckedLine(failure.lines))
            return 1
        }
    }

    /// Asks each Mac what it has left running (`cluster verify-teardown`) until both have ended or `seconds` pass; a wait
    /// past the first answer says so, with its bound.
    private static func awaitTeardown(_ actions: ClusterPairActions, wait: Wait, say: Say) -> Result<[String], ClusterOnboardingFailure> {
        let deadline = Date().addingTimeInterval(wait.seconds)
        var said = false
        while true {
            let result = actions.verifyTeardown()
            if case .success(let lines) = result, ClusterPairSummary.bothFreed(lines) { return result }
            if Date().timeIntervalSince(deadline) >= 0 { return result }
            if !said { say("  Waiting for both Macs' parts to end (\(upTo(wait.seconds)))."); said = true }
            Thread.sleep(forTimeInterval: wait.interval)
        }
    }

    /// Said when the stop request has not answered after `progressDelay`: the leading Mac answers once both Macs have
    /// stopped, after their accepted requests (the routed stop gives up after 330 s, `ClusterOnboardingLive.stop`).
    static let stopWaitLine = "  Waiting for both Macs to stop; accepted requests finish first (up to about 6 min)."

    /// A wait's bound in words: "up to 30 s" under a minute, else in minutes ("up to 10 min").
    static func upTo(_ seconds: Double) -> String {
        "up to " + (seconds < 60 ? "\(Int(seconds.rounded())) s" : "\(Int((seconds / 60).rounded())) min")
    }

    /// `request`, a blocking call to the pair, with `line` said once if it has not answered after `seconds`, so a long
    /// wait is never silent. The line is never said after the answer.
    static func saying<T>(_ line: String, after seconds: Double, say: @escaping Say, _ request: () -> T) -> T {
        let pending = Pending()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { pending.unlessAnswered { say(line) } }
        defer { pending.answered() }
        return request()
    }

    private final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func unlessAnswered(_ body: () -> Void) { lock.withLock { if !done { body() } } }
        func answered() { lock.withLock { done = true } }
    }

    /// `stop`'s wait for both parts to end, read where a test's wait is bound (detached tasks don't inherit it).
    static var teardownWait: Wait { waitForTesting ?? .teardown }

    /// `darkbloom start` without a terminal (scripts): the pair starts with its saved model on both Macs; then the command
    /// waits until it serves, or says why not, and ends with a result block like single-Mac start's. The exit status is
    /// `darkbloom cluster status`'s. A pair that already serves is kept as it is, and said so (`servingLook`).
    static func start(_ pair: ClusterPairSummary, actions: ClusterPairActions?, config: String?,
                      say: Say = printLine) async -> Int32 {
        if actions != nil, let serving = await servingLook(pair, config: config) {
            say(pair.actingLine("the pair already serves"))
            for line in serving.resultLines { say(line) }
            return serving.exitCode
        }
        say(pair.actingLine("starting the pair"))
        guard let actions = startable(pair, actions: actions, say: say) else { return 1 }
        return await serve(actions, config: config, say: say)
    }

    /// The pair's own look, nil unless it serves: a start then asks nothing of either Mac (journey 2a on pair-2, J2-b: a
    /// script's start on a serving pair said "starting the pair"). Asked only while this Mac's own view says the pair
    /// runs here and the other Mac answers, so a start whose other Mac is away goes on at once, as before. Like the
    /// wait's looks (`waitUntilServing`), it waits for the answer as long as it takes, never cut short.
    private static func servingLook(_ pair: ClusterPairSummary, config: String?) async -> ClusterPairSummary? {
        guard pair.started, pair.partServes, pair.otherMacReachable else { return nil }
        let look = await ClusterPairSummary.live(config: config)
        return look.state == .serving ? look : nil
    }

    /// `darkbloom restart`: the pair stops serving on both Macs, then starts again with its current model. What a start
    /// needs is checked before the stop, so a pair that couldn't start again is not stopped.
    static func restart(_ pair: ClusterPairSummary, actions: ClusterPairActions?, config: String?,
                        say: @escaping Say = printLine) async -> Int32 {
        say(pair.actingLine("restarting both Macs"))
        guard let actions = startable(pair, actions: actions, say: say) else { return 1 }
        let role = actions.resume().role
        let progressAfter = progressDelay
        if case .failure(let failure) = await Task.detached(operation: {
            saying(stopWaitLine, after: progressAfter, say: say, actions.stop)
        }).value {
            sayStopFailed(failure, role: role, say: say)
            return 1
        }
        // As the screen's model change: both parts release their memory before the pair starts again.
        let wait = waitForTesting ?? .restartTeardown
        let teardown = await Task.detached { awaitTeardown(actions, wait: wait, say: say) }.value
        guard case .success(let left) = teardown, ClusterPairSummary.bothFreed(left) else {
            switch teardown {
            case .success(let lines): for line in ClusterPairSummary.memoryLines(lines) { say("  " + line) }
            case .failure(let failure): say("  " + ClusterPairSummary.memoryNotCheckedLine(failure.lines))
            }
            say(ClusterPairSummary.restartNotStartedLine)
            return 1
        }
        say("  Stopped on both Macs; starting it again.")
        return await serve(actions, config: config, say: say)
    }

    /// The actions when the pair can start: nil, after saying why, when this Mac's cluster can't be reached or no model
    /// was ever chosen.
    private static func startable(_ pair: ClusterPairSummary, actions: ClusterPairActions?, say: Say) -> ClusterPairActions? {
        guard let actions else { say(ClusterPairSummary.unreachableLine); return nil }
        guard pair.model != nil else { say(ClusterPairSummary.noModelLine); return nil }
        return actions
    }

    /// A pair stop that failed: its reasons and, on the Mac that follows, how to stop this Mac alone.
    private static func sayStopFailed(_ failure: ClusterOnboardingFailure, role: ClusterOnboardingRole?, say: Say) {
        for line in failure.lines { say("  " + line) }
        if role == .member { for line in ClusterPairSummary.memberStopFailureLines(failure.lines) { say(line) } }
    }

    private enum Started: Sendable { case asked, serviceFailed([String]), notEverywhere([String]) }

    private static func serve(_ actions: ClusterPairActions, config: String?, say: Say) async -> Int32 {
        // Says what the service step does before it does it (the pair-2 run, P2-3: a start with no terminal stopped the
        // session service and installed its login agent without a word).
        if ClusterService.running(), !ClusterServiceAgent.installedLabels().contains(where: { ClusterServiceAgent.isLoaded(label: $0) }) {
            say("  This Mac's cluster service runs from a terminal session: replacing it with its login agent, which starts at "
                + "login (this Mac's part restarts).")
        }
        let started = await Task.detached { () -> Started in
            if case .failure(let failure) = actions.ensureService() { return .serviceFailed(failure.lines) }
            if case .failure(let failure) = actions.serve() { return .notEverywhere(failure.lines) }
            return .asked
        }.value
        switch started {
        case .serviceFailed(let lines):
            for line in lines { say("  " + line) }
            return 1
        case .notEverywhere(let lines):
            // Not started on the other Mac yet (it isn't answering): the status below says where the pair stands.
            for line in lines { say("  " + line) }
        case .asked: break
        }
        let summary = await waitUntilServing(config: config, say: say)
        // macOS keeps this Mac's follower off the local network: final until someone turns it on (P2-1, P2-3), so the
        // instruction instead of the pair's loading lines.
        if ClusterLocalNetworkAccess.serviceState() == .blocked {
            for line in ClusterOnboardingDriver.localNetworkBlockedLines(app: ClusterService.appName,
                                                                         then: "then run `\(BuildEnvironment.current.cliName) start` again") {
                say("  " + line)
            }
            return 1
        }
        for line in summary.resultLines { say(line) }
        return summary.exitCode
    }

    /// Asks the status `darkbloom cluster status` reads until the pair serves, says why it doesn't, or the wait runs out
    /// (`Wait.standard`); each new status line is said once, and again with the bound when it stays the same for
    /// `Wait.heartbeat`. A wait past the first look says so, with its bound. A stop that has not reached the status yet
    /// is waited out briefly.
    private static func waitUntilServing(config: String?, say: Say) async -> ClusterPairSummary {
        let wait = waitForTesting ?? .standard
        let deadline = Date().addingTimeInterval(wait.seconds)
        var said: String?
        var saidAt = Date()
        var waiting = false
        var stoppedLooks = 0
        while true {
            let summary = await ClusterPairSummary.live(config: config)
            if ClusterLocalNetworkAccess.serviceState() == .blocked { return summary }
            var status: String?
            switch summary.state {
            case .serving, .notPaired, .pairingUnreadable: return summary
            case .notServing:
                // A reason the Macs mend by themselves (an Apple verification retry, memory freeing, the coordinator
                // retrying) is waited through, as the setup screen does; a final one ends the wait.
                if summary.localNetworkRefused != nil || ClusterPairSummary.isFinalReason(summary.reason) { return summary }
                status = summary.lines.first
            case .stopped:
                stoppedLooks += 1
                if stoppedLooks > 3 { return summary }
            case .loading, .unknown, .otherMacAway:
                status = summary.lines.first
            }
            if let status, status != said {
                say("  " + status); said = status; saidAt = Date()
            } else if let status, Date().timeIntervalSince(saidAt) >= wait.heartbeat {
                say("  Still waiting (\(upTo(wait.seconds)) in all): " + status); saidAt = Date()
            }
            if Date().timeIntervalSince(deadline) >= 0 { return summary }
            if !waiting { say("  Waiting until the pair serves (\(upTo(wait.seconds)))."); waiting = true }
            try? await Task.sleep(nanoseconds: UInt64(wait.interval * 1_000_000_000))
        }
    }
}
