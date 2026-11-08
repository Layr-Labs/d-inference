import ArgumentParser
import Foundation
import ProviderCore

extension Cluster {
    /// This Mac's cluster service (`darkbloom cluster` installs it as a login
    /// agent once the Mac is paired): answers the leader over the link control
    /// channel, applies the setup a member's leader syncs, and runs this Mac's
    /// part while the leader has the cluster serving. Runs until SIGTERM or SIGINT.
    ///
    /// launchd runs it as `--supervise`: the S18 supervisor, which runs the
    /// service as its child and restarts it with the restart budget and backoff,
    /// and updates the pair together with the other Mac's supervisor.
    struct Service: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "service",
            abstract: "Run this Mac's cluster service (started by `\(ClusterPairSummary.cli) cluster`).", shouldDisplay: false)
        @OptionGroup var configOptions: ConfigOptions
        @Option(help: "Absolute path of this Mac's cluster worker, when it is not the installed one (Darkbloom.app/Contents/Helpers).")
        var worker: String?
        @Flag(help: "Run the supervisor that keeps the service running (what the login agent runs).")
        var supervise = false
        @Flag(help: "Install the service as this Mac's login agent (what `\(ClusterPairSummary.cli) cluster` does) and exit.")
        var install = false

        func validate() throws {
            for path in [configOptions.config, worker].compactMap({ $0 }) where !path.hasPrefix("/") {
                throw ValidationError("The cluster service takes absolute paths.")
            }
            guard !(supervise && install) else { throw ValidationError("Choose at most one of --supervise and --install.") }
        }

        var serviceOptions: [String] { ClusterServiceAgentPlan.serviceOptions(config: configOptions.config, worker: worker) }

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            if install { return try installAgent() }
            if supervise { return try await runSupervisor() }
            let settings = try Cluster.Setup.serviceSettings(config: configOptions.config, modelDir: nil, worker: worker)
            let service = try ClusterService(settings: settings)
            let stop = DispatchSemaphore(value: 0)
            let signals = try DistributedStartSignals()
            defer { signals.close() }
            signals.attach { stop.signal() }
            // Under its supervisor: a heartbeat for the liveness guard, and an end
            // of its own when the supervisor is gone (a restarted supervisor
            // starts a new service, which needs this one's lock).
            let supervision = ClusterServiceSupervision(environment: ProcessInfo.processInfo.environment)
            supervision?.start(stop: stop, running: { ClusterService.published()?.child.running ?? false })
            defer { supervision?.finish() }
            let clean = try await Task.detached {
                try service.run(stop: stop) { text in
                    let stamp = ISO8601DateFormatter().string(from: Date())
                    FileHandle.standardOutput.write(Data("\(stamp) cluster service: \(text)\n".utf8))
                }
            }.value
            if !clean { throw ExitCode(3) }
        }

        private func installAgent() throws {
            let executable = URL(fileURLWithPath: Start.currentExecutablePath())
            let outcome = try ClusterService.installAtLogin(executable: executable, serviceOptions: serviceOptions)
            let job = try ClusterService.loginAgentJob(executable: executable, serviceOptions: serviceOptions)
            print("Cluster service login agent \(job.label): \(outcome.rawValue); it starts at login and its supervisor restarts it with backoff.")
        }

        /// `cluster service --supervise`: the S18 supervisor around `cluster service`.
        private func runSupervisor() async throws {
            let executable = Start.currentExecutablePath()
            let supervisor = ClusterMemberSupervisor(configuration: Self.supervisorConfiguration(
                executable: executable, serviceOptions: serviceOptions, configPath: configOptions.config,
                environment: ProcessInfo.processInfo.environment,
                serviceDirectory: try ClusterService.paths().lock.deletingLastPathComponent(),
                reexecArguments: [executable] + Array(CommandLine.arguments.dropFirst())))
            let signals = try DistributedStartSignals()
            defer { signals.close() }
            signals.attach { supervisor.requestStop() }
            // Exit 0 also when another supervisor already keeps the service, so launchd does not relaunch this one.
            _ = await supervisor.run()
        }

        /// The supervisor updates the pair as the single-Mac updater updates one Mac: the same `auto_update` and
        /// `DARKBLOOM_NO_UPDATE_CHECK` gate and the same coordinator (`Watchdog.settings`), at the update slot of the
        /// pairing's cluster ID, which both Macs share (`ClusterPairUpdateCycle`).
        static func supervisorConfiguration(
            executable: String, serviceOptions: [String], configPath: String?, environment: [String: String],
            serviceDirectory: URL, reexecArguments: [String],
            clusterID: @escaping @Sendable () -> String? = { try? ClusterSetupLinkExchange.pairing()?.clusterID }
        ) -> ClusterMemberSupervisor.Configuration {
            let settings = Watchdog.settings(configPath: configPath, environment: environment)
            let coordinatorURL = settings.coordinatorURL
            let followEnvironment = ClusterPairUpdateCycle.Environment.live(
                serviceDirectory: serviceDirectory, coordinatorURL: coordinatorURL, log: { _ in })
            return .init(
                executable: executable,
                childArguments: ClusterServiceAgentPlan.childArguments(serviceOptions: serviceOptions),
                environment: environment,
                statePath: ClusterServiceAgent.supervisorStatePath(serviceDirectory: serviceDirectory),
                healthPath: ClusterServiceAgent.healthPath(serviceDirectory: serviceDirectory),
                // The service waits for the cable itself (it answers once the link is up).
                setup: nil, coordinatorURL: coordinatorURL, autoUpdate: settings.autoUpdate,
                budgetLimits: .resolve(environment), guardLimits: .resolve(environment),
                recycleGraceSeconds: Double(ClusterServiceAgentPlan.partStopGraceSeconds),
                reexecArguments: reexecArguments,
                logName: "cluster service supervisor",
                restartHint: "`\(ClusterPairSummary.cli) cluster` is run again (or `\(ClusterPairSummary.cli) cluster stop`)",
                pairUpdate: .init(
                    clusterID: clusterID,
                    run: { request, log, restart in
                        let environment = ClusterPairUpdateCycle.Environment.live(
                            serviceDirectory: serviceDirectory, coordinatorURL: coordinatorURL, automatic: request == nil, log: log)
                        return await ClusterPairUpdateCycle(environment: environment).run(request: request, restart: restart)
                    },
                    requestPath: ClusterServiceAgent.updateRequestPath(serviceDirectory: serviceDirectory),
                    progressPath: ClusterServiceAgent.updateProgressPath(serviceDirectory: serviceDirectory),
                    recovery: ClusterCandidateRecovery(updater: SelfUpdater(coordinatorBaseURL: coordinatorURL)),
                    partServes: {
                        ClusterService.publishedLive().map { $0.serving && $0.child.running && $0.session?.ready != false } ?? false
                    },
                    // Built once: its peer address and network session are kept between the minute's checks.
                    follow: { [followEnvironment] log, restart in
                        var environment = followEnvironment
                        environment.log = log
                        return await ClusterPairUpdateCycle(environment: environment).followRollback(restart: restart)
                    },
                    quarantined: { SelfUpdater(coordinatorBaseURL: coordinatorURL).quarantinedVersion() }))
        }
    }

    /// `darkbloom cluster stop`: the same as `darkbloom stop` on a Mac in a cluster. The pair stops on both Macs and
    /// stays stopped; both cluster services stay up, idle. `--service` also stops this Mac's cluster service and keeps
    /// it stopped across restarts (its login agent is removed): the leader stops the cluster's serving first (the
    /// members stop their parts), and a member of a started cluster asks the leader to (`pairStop`). `--local-only`
    /// stops only this Mac's service, without asking the other Mac. `darkbloom cluster` starts it again.
    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stop",
            abstract: "Stop the cluster on both Macs, the same as `\(ClusterPairSummary.cli) stop` (`\(ClusterPairSummary.cli) start` starts it again).",
            discussion: "On either Mac: the leading Mac stops both Macs' parts, as Stop in `\(ClusterPairSummary.cli) cluster` does. Both Macs "
                + "stay stopped after a restart, and their cluster services stay up, idle, so `\(ClusterPairSummary.cli) start` on either Mac "
                + "starts the pair again. --service also stops this Mac's cluster service and keeps it from starting at login.")
        @OptionGroup var configOptions: ConfigOptions
        @Option(help: "Absolute path of this Mac's cluster worker, when it is not installed beside darkbloom.")
        var worker: String?
        @Flag(name: .customLong("local-only"),
              help: "Stop only this Mac's cluster service, without asking the other Mac (when it is gone for good). Run `\(ClusterPairSummary.cli) cluster stop --service` there too if it comes back.")
        var localOnly = false
        @Flag(help: "Also stop this Mac's cluster service and keep it from starting at login (`\(ClusterPairSummary.cli) cluster` starts it again).")
        var service = false

        func validate() throws {
            for path in [configOptions.config, worker].compactMap({ $0 }) where !path.hasPrefix("/") {
                throw ValidationError("\(ClusterPairSummary.cli) cluster stop takes absolute paths.")
            }
        }

        /// What `cluster stop` does: the pair stop `darkbloom stop` does, or the stop that also turns this Mac's cluster
        /// service off (`--service`, `--local-only`, or a Mac in no cluster, whose leftover service it removes).
        enum Mode: Equatable { case pair, refuse, serviceOff }

        static func mode(_ pair: ClusterPairSummary, localOnly: Bool, service: Bool) -> Mode {
            guard pair.paired, !localOnly, !service else { return .serviceOff }
            return pair.pairingUnreadable ? .refuse : .pair
        }

        /// `cluster stop` while this Mac's pairing record can't be read: nothing changes, and why.
        static func refusal(_ pair: ClusterPairSummary) -> [String] {
            [pair.pairSentence, "`\(ClusterPairSummary.cli) cluster stop` can't tell which pair to stop, so nothing was stopped.",
             "To stop this Mac's cluster service anyway: `\(ClusterPairSummary.cli) cluster stop --service`. " + ClusterPairSummary.checkPairingLine]
        }

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            let pair = ClusterPairSummary.local()
            switch Self.mode(pair, localOnly: localOnly, service: service) {
            case .pair:
                let actions = ClusterPairActions.live(config: configOptions.config, worker: worker)
                let teardown = ClusterPairCommands.teardownWait, progressAfter = ClusterPairCommands.progressDelay
                let code = await Task.detached {
                    ClusterPairCommands.stop(pair, actions: actions, teardown: teardown, progressAfter: progressAfter)
                }.value
                if code != 0 { throw ExitCode(code) }
                return
            case .refuse:
                for line in Self.refusal(pair) { print(line) }
                throw ExitCode.failure
            case .serviceOff:
                break
            }
            let config = configOptions.config, worker = worker, localOnly = localOnly
            let progressAfter = ClusterPairCommands.progressDelay
            let executable = URL(fileURLWithPath: Start.currentExecutablePath())
            let lines: [String] = try await Task.detached {
                var stopped: Result<[String], ClusterOnboardingFailure>?
                var forwarded = false
                // The leader stops serving first, so its members stop their parts too
                // (unless asked to stop only this Mac: the other one is gone).
                if !localOnly, let operations = try? ClusterOnboardingOperations.live(.clusterService(config: config, worker: worker)) {
                    let resume = operations.resume()
                    switch Self.pairStop(role: resume.role, serving: resume.serving) {
                    case .stopHere: break
                    case .leaderStopsBoth: stopped = Self.stopBothMacs(operations, progressAfter: progressAfter)
                    case .askLeader:
                        // The menu's Stop, sent to the leading Mac: both Macs stop, instead of the leader waiting
                        // for this one and then serving alone or nothing.
                        print(ClusterPairSummary.memberStopNote(
                            leader: ClusterOnboardingMacName.other(named: resume.leaderName ?? resume.peerName)))
                        fflush(stdout)
                        forwarded = true
                        stopped = Self.stopBothMacs(operations, progressAfter: progressAfter)
                    }
                }
                return try Self.finishStop(stopped, localOnly: localOnly, forwarded: forwarded) {
                    try ClusterService.removeFromLogin(executable: executable)
                }
            }.value
            for line in lines { print(line) }
        }

        /// The pair stop `--service` asks for first, saying what it waits for when it runs long.
        private static func stopBothMacs(_ operations: ClusterOnboardingOperations, progressAfter: Double)
            -> Result<[String], ClusterOnboardingFailure> {
            ClusterPairCommands.saying(ClusterPairCommands.stopWaitLine, after: progressAfter, say: ClusterPairCommands.printLine,
                                       operations.stop)
        }

        /// Who stops the cluster's serving when `cluster stop` runs here.
        enum PairStop: Equatable {
            /// Nothing serves that this Mac's stop would break: only this Mac's service stops.
            case stopHere
            /// This Mac leads: it stops both Macs.
            case leaderStopsBoth
            /// This Mac follows a started cluster: the leading Mac is asked to stop both Macs.
            case askLeader
        }

        static func pairStop(role: ClusterOnboardingRole?, serving: Bool) -> PairStop {
            switch role {
            // Even when not serving: a previous bounded failure already saved serving=false;
            // retry must still finish its drain/peer acknowledgement.
            case .leader: return .leaderStopsBoth
            case .member: return serving ? .askLeader : .stopHere
            case nil: return .stopHere
            }
        }

        /// A pair stop that could not finish: the pair's own reason lines, as a
        /// runtime failure (exit 1). It is not a usage mistake, so no usage banner.
        struct Failure: Error, CustomStringConvertible {
            let lines: [String]
            var description: String { lines.joined(separator: "\n") }
        }

        /// Keep the supervisor and its custody intact when the pair could not
        /// drain or the member did not acknowledge the saved stop request.
        static func finishStop(_ stopped: Result<[String], ClusterOnboardingFailure>?, localOnly: Bool = false,
                               forwarded: Bool = false, removeFromLogin: () throws -> [String]) throws -> [String] {
            var lines: [String] = []
            var otherMacNotAsked = false
            if let stopped {
                switch stopped {
                case .success(let said): lines = said
                case .failure(let failure) where !forwarded && failure.otherMacUnanswered != nil:
                    // R5-1: this Mac stopped serving and the other Mac did not answer (its service already off, or
                    // out of reach): this Mac's service still stops, and each Mac's state is said.
                    lines = ["This Mac stopped serving.",
                             failure.otherMacUnanswered! + ", so it was not asked to stop (its cluster service may already be off)."]
                    otherMacNotAsked = true
                case .failure(let failure):
                    throw Failure(lines: failure.lines + (forwarded ? ClusterPairSummary.memberStopFailureLines(failure.lines) : []))
                }
            }
            let removed = try removeFromLogin()
            lines.append(removed.isEmpty
                ? "This Mac's cluster service is stopped (it was not set to start at login)."
                : "This Mac's cluster service is stopped and will not start at login. Run `\(ClusterPairSummary.cli) cluster` to start it again.")
            if otherMacNotAsked {
                lines.append("If the other Mac's cluster service is still on, run `\(ClusterPairSummary.cli) cluster stop --service` there too.")
            }
            if localOnly {
                lines.append("The other Mac was not asked to stop. If it comes back, run `\(ClusterPairSummary.cli) cluster stop --service` there too.")
            }
            return lines
        }
    }
}

/// The supervised service's side of the S18 supervision: a heartbeat the
/// liveness guard reads (the service has no provider loop; a ticker of its
/// own proves the process alive), and an end of its own when its supervisor
/// is gone. Present only when a supervisor started this process.
final class ClusterServiceSupervision: @unchecked Sendable {
    private let healthPath: URL
    private let parent = getppid()
    private let lock = NSLock()
    private var finished = false

    init?(environment: [String: String]) {
        guard let path = environment[ClusterSupervisionFiles.healthPathEnvironmentKey], !path.isEmpty else { return nil }
        healthPath = URL(fileURLWithPath: path)
    }

    func start(stop: DispatchSemaphore, running: @escaping @Sendable () -> Bool) {
        Thread.detachNewThread { [self] in
            var stopped = false
            while !lock.withLock({ finished }) {
                beat(running() ? .serving : .registered)
                if !stopped, getppid() != parent {
                    // The supervisor ended without stopping this service (a crash or SIGKILL): stop
                    // this Mac's part and leave, so the supervisor launchd starts again takes over.
                    stopped = true
                    let stamp = ISO8601DateFormatter().string(from: Date())
                    FileHandle.standardOutput.write(Data("\(stamp) cluster service: its supervisor is gone; stopping\n".utf8))
                    stop.signal()
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    func finish() {
        lock.withLock { finished = true }
        beat(.stopping)
    }

    private func beat(_ phase: ClusterMemberHealth.Phase) {
        ClusterSupervisionFiles.write(ClusterMemberHealth(pid: getpid(), version: ProviderCore.version, phase: phase,
            writtenAt: Date().timeIntervalSince1970), to: healthPath)
    }
}
