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

    /// Tests give the commands actions of their own.
    @TaskLocal static var forTesting: ClusterPairActions?

    /// This Mac's cluster, nil when it can't be reached from here. Never this Mac's real cluster while a test gives the
    /// pair (`ClusterPairSummary.readsThisMacsCluster`).
    static func live(config: String?, worker: String? = nil) -> ClusterPairActions? {
        if let actions = forTesting { return actions }
        guard ClusterPairSummary.readsThisMacsCluster,
              let settings = try? Cluster.Setup.serviceSettings(config: config, modelDir: nil, worker: worker),
              let operations = try? ClusterOnboardingOperations.live(.init(service: settings,
                  serviceArguments: ClusterServiceAgentPlan.childArguments(
                      serviceOptions: ClusterServiceAgentPlan.serviceOptions(config: config, worker: worker)))) else { return nil }
        return ClusterPairActions(resume: operations.resume, ensureService: operations.ensureService, serve: operations.serve,
                                  stop: operations.stop, verifyTeardown: operations.verifyTeardown)
    }
}

/// `darkbloom start`, `stop`, `restart` and `status` on a Mac in a two-Mac cluster control the pair, as the same
/// commands control single-Mac serving on one Mac (owner, 2026-11-04); `--solo` keeps single-Mac serving on this Mac.
enum ClusterPairCommands {
    typealias Say = @Sendable (String) -> Void
    static let printLine: Say = { line in print(line); fflush(stdout) }

    /// How long a start without a terminal waits for the pair to serve, and how often it looks.
    struct Wait: Sendable {
        var seconds: Double
        var interval: Double
        static let standard = Wait(seconds: 600, interval: 5)
    }

    /// Tests see the call instead of the screen, choose whether a terminal is attached, and how long a start waits.
    @TaskLocal static var screenForTesting: (@Sendable (_ config: String?) async throws -> Void)?
    @TaskLocal static var terminalForTesting: Bool?
    @TaskLocal static var waitForTesting: Wait?

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
    static func stop(_ pair: ClusterPairSummary, actions: ClusterPairActions?, say: Say = printLine) -> Int32 {
        say(pair.actingLine("stopping both Macs"))
        guard let actions else { say(ClusterPairSummary.unreachableLine); return 1 }
        let resume = actions.resume()
        if resume.role == .member, !resume.serving {
            say(ClusterPairSummary.alreadyStoppedLine)
            return 0
        }
        if case .failure(let failure) = actions.stop() {
            for line in failure.lines { say("  " + line) }
            if resume.role == .member { say(ClusterPairSummary.memberStopFailedLine) }
            return 1
        }
        say(ClusterPairSummary.stoppedLine)
        if case .success(let lines) = actions.verifyTeardown() {
            for line in ClusterPairSummary.memoryLines(lines) { say(line) }
        }
        return 0
    }

    /// `darkbloom start` without a terminal (scripts): the pair starts with its saved model on both Macs; then the command
    /// waits until it serves, or says why not, and ends with a result block like single-Mac start's. The exit status is
    /// `darkbloom cluster status`'s.
    static func start(_ pair: ClusterPairSummary, actions: ClusterPairActions?, config: String?, wait: Wait = .standard,
                      say: Say = printLine) async -> Int32 {
        say(pair.actingLine("starting the pair"))
        return await serve(pair, actions: actions, config: config, wait: wait, say: say)
    }

    /// `darkbloom restart`: the pair stops serving on both Macs, then starts again with its current model.
    static func restart(_ pair: ClusterPairSummary, actions: ClusterPairActions?, config: String?, wait: Wait = .standard,
                        say: Say = printLine) async -> Int32 {
        say(pair.actingLine("restarting both Macs"))
        guard let actions else { say(ClusterPairSummary.unreachableLine); return 1 }
        guard pair.model != nil else { say(ClusterPairSummary.noModelLine); return 1 }
        let role = actions.resume().role
        if case .failure(let failure) = await Task.detached(operation: { actions.stop() }).value {
            for line in failure.lines { say("  " + line) }
            if role == .member { say(ClusterPairSummary.memberStopFailedLine) }
            return 1
        }
        say("  Stopped on both Macs; starting it again.")
        return await serve(pair, actions: actions, config: config, wait: wait, say: say)
    }

    private enum Started: Sendable { case asked, serviceFailed([String]), notEverywhere([String]) }

    private static func serve(_ pair: ClusterPairSummary, actions: ClusterPairActions?, config: String?, wait: Wait,
                              say: Say) async -> Int32 {
        guard let actions else { say(ClusterPairSummary.unreachableLine); return 1 }
        guard pair.model != nil else { say(ClusterPairSummary.noModelLine); return 1 }
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
        let summary = await waitUntilServing(config: config, wait: wait, say: say)
        for line in summary.resultLines { say(line) }
        return summary.exitCode
    }

    /// Asks the status `darkbloom cluster status` reads until the pair serves, says why it doesn't, or `wait` runs out;
    /// each new status line is said once. A stop that has not reached the status yet is waited out briefly.
    static func waitUntilServing(config: String?, wait: Wait, say: Say) async -> ClusterPairSummary {
        let wait = waitForTesting ?? wait
        let deadline = Date().addingTimeInterval(wait.seconds)
        var said: String?
        var stoppedLooks = 0
        while true {
            let summary = await ClusterPairSummary.live(config: config)
            switch summary.state {
            case .serving, .notServing, .notPaired, .pairingUnreadable: return summary
            case .stopped:
                stoppedLooks += 1
                if stoppedLooks > 3 { return summary }
            case .loading, .unknown, .otherMacAway:
                if let line = summary.lines.first, line != said { say("  " + line); said = line }
            }
            if Date() >= deadline { return summary }
            try? await Task.sleep(nanoseconds: UInt64(wait.interval * 1_000_000_000))
        }
    }
}
