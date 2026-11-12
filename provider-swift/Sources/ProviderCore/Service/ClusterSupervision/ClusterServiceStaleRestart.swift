import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A cluster service left on an earlier release after an update, restarted once from its part (0.10.12 W1-D2).
///
/// `darkbloom update` installs a release and asks the cluster service's supervisor to restart into it together with
/// the other Mac (`ClusterPairUpdateCycle`). A pair that serves only on its local API, or a Mac whose service serves
/// alone, does not drain for an update (`ClusterPairUpdateCycle.livePart`), so that restart never comes: the supervisor
/// and the service keep running the release they started with, while every part they start runs the installed one.
/// Only a login, a crash of the supervisor or a `launchctl kickstart -k` replaced them. The release that decides an
/// update is the one being updated from, so the installed release can't change that refusal for its own update.
///
/// The part is the first process of the installed release such a Mac runs. At its start, before it holds a request, it
/// compares the release its supervisor runs (`service-supervisor.json`) with its own. When the supervisor's is older,
/// it asks launchd to restart the service's job (`launchctl kickstart -k`): the service stops its part as at a logout,
/// keeping the pair's saved start, and the supervisor starts again from the installed binary. It asks once per
/// installed release within `onceEverySeconds`, and only once that is recorded in the service's folder (`fileName`), so
/// a supervisor that still reported an older release afterwards would never be restarted in a loop.
public enum ClusterServiceStaleRestart {
    /// The restart a part asked for, kept in the service's folder.
    public struct Asked: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public var supervisorPID: Int32
        public var at: Double

        public init(from: String, to: String, supervisorPID: Int32, at: Double) {
            self.from = from; self.to = to; self.supervisorPID = supervisorPID; self.at = at
        }
    }

    public enum Decision: Equatable, Sendable {
        case nothing
        /// The supervisor runs `from`, older than this part's `to`: its job is restarted.
        case restart(from: String, to: String)
    }

    public static let fileName = "service-restart-asked.json"
    /// The same release is asked for at most once in this long.
    public static let onceEverySeconds: Double = 6 * 3600

    /// - `parentPID`: this part's parent, which must be the service the supervisor runs now (`supervisor.current`).
    /// - `jobPID`: the process launchd's job for this build's cluster service runs, which must be the supervisor: a
    ///   supervisor started from a terminal has no job to restart.
    /// - `asked`: the last restart a part asked for.
    public static func decide(thisVersion: String, parentPID: Int32, supervisor: ClusterMemberSupervisorState?,
                              jobPID: Int32?, asked: Asked?, now: Double) -> Decision {
        guard let supervisor, olderSupervisor(supervisor, than: thisVersion),
              let service = supervisor.current?.pid, service == parentPID,
              let jobPID, jobPID == supervisor.supervisorPID else { return .nothing }
        if let asked, asked.to == thisVersion, now - asked.at < onceEverySeconds { return .nothing }
        return .restart(from: supervisor.version, to: thisVersion)
    }

    /// Whether the supervisor runs a release older than `thisVersion` (both read as releases; any other text is not).
    static func olderSupervisor(_ supervisor: ClusterMemberSupervisorState, than thisVersion: String) -> Bool {
        guard let running = SemanticVersion(supervisor.version), let installed = SemanticVersion(thisVersion) else { return false }
        return running < installed
    }

    /// The service folder of a part that a supervised cluster service started: the folder of its heartbeat file
    /// (`ClusterService.partEnvironment`). Nil for any other process, the service itself included.
    public static func partServiceDirectory(environment: [String: String]) -> URL? {
        guard let path = environment[ClusterSupervisionFiles.healthPathEnvironmentKey], !path.isEmpty else { return nil }
        let file = URL(fileURLWithPath: path)
        let directory = file.deletingLastPathComponent()
        guard file.lastPathComponent == ClusterServiceAgent.partHealthPath(serviceDirectory: directory).lastPathComponent else { return nil }
        return directory
    }

    /// How long a part that asked waits for the restart to stop it before it starts as it would have.
    public static let waitForStopSeconds: Double = 20

    /// At the start of a cluster part: the check, and the restart when it is due. `say` gets a line when it asks, and
    /// one more if launchctl refuses. After asking, the part starts nothing for `waitForStopSeconds` (`waitForStop`),
    /// so the restart's stop of the service, which stops this part with SIGTERM, ends it before it loads a model only to
    /// release it again. A part that is still running after the wait starts as before.
    @discardableResult
    public static func restartIfStale(say: @escaping @Sendable (String) -> Void) -> Decision {
        let decision = restartIfStale(environment: ProcessInfo.processInfo.environment,
                                      executablePath: LaunchctlControl.currentExecutablePath(),
                                      thisVersion: ProviderCore.version, parentPID: getppid(),
                                      now: Date().timeIntervalSince1970, say: say)
        if case .restart = decision { waitForStop(seconds: waitForStopSeconds) }
        return decision
    }

    /// Sleeps `seconds` with SIGTERM and SIGINT at their default action, then gives them back what they had. A `start`
    /// part runs under the AppKit host, which has already taken both for the provider's own drain before `Start.run()`
    /// (`ProviderSignalHandler`: ignored, read by dispatch sources); a SIGTERM would only be noted there, and the part
    /// would sleep the whole wait and carry on starting. With their default action the stop ends it at once, as it ends
    /// `cluster link-follower`, which has set no handler yet.
    static func waitForStop(seconds: Double) {
        var saved: [(number: Int32, action: sigaction)] = []
        for number in [SIGTERM, SIGINT] {
            var standard = sigaction()
            standard.__sigaction_u.__sa_handler = SIG_DFL
            var previous = sigaction()
            if sigaction(number, &standard, &previous) == 0 { saved.append((number, previous)) }
        }
        Thread.sleep(forTimeInterval: seconds)
        for entry in saved {
            var action = entry.action
            sigaction(entry.number, &action, nil)
        }
    }

    static func restartIfStale(environment: [String: String], executablePath: String, thisVersion: String,
                               parentPID: Int32, now: Double,
                               printJob: (String) -> LaunchctlControl.Output = { LaunchctlControl.printOutput(label: $0) },
                               kick: (String, @escaping @Sendable (String) -> Void) -> Void = { kickInBackground($0, say: $1) },
                               say: @escaping @Sendable (String) -> Void) -> Decision {
        guard let directory = partServiceDirectory(environment: environment),
              let supervisor = ClusterSupervisionFiles.read(ClusterMemberSupervisorState.self,
                  from: ClusterServiceAgent.supervisorStatePath(serviceDirectory: directory)),
              olderSupervisor(supervisor, than: thisVersion) else { return .nothing }
        // Only past the version check: reading the job asks launchctl.
        let label = ClusterServiceAgentPlan.label(executablePath: executablePath)
        let printed = printJob(label)
        let askedPath = directory.appendingPathComponent(fileName)
        let decision = decide(thisVersion: thisVersion, parentPID: parentPID, supervisor: supervisor,
                              jobPID: printed.succeeded ? jobPID(launchctlPrint: printed.stdout) : nil,
                              asked: ClusterSupervisionFiles.read(Asked.self, from: askedPath), now: now)
        guard case .restart(let from, let to) = decision else { return decision }
        // Recorded before the ask, and asked only once recorded: the restart ends this process too, and the record is
        // what keeps the next part's start from asking again.
        guard ClusterSupervisionFiles.write(Asked(from: from, to: to, supervisorPID: supervisor.supervisorPID, at: now),
                                            to: askedPath) else {
            say("could not record the restart in \(askedPath.path), so this Mac's cluster service is not restarted: "
                + "it still runs v\(from), and runs v\(to) after the next login")
            return .nothing
        }
        say("this Mac's cluster service still runs v\(from) while v\(to) is installed (its update did not restart it): "
            + "restarting it once (launchctl kickstart -k \(label)); it starts the pair again on v\(to)")
        kick(LaunchctlControl.target(label: label), say)
        return decision
    }

    /// Not waited for: launchd stops this part with the service, and nothing that stop waits for may wait on launchctl.
    static func kickInBackground(_ target: String, say: @escaping @Sendable (String) -> Void,
                                 run: @escaping @Sendable ([String]) -> LaunchctlControl.Output
                                     = { LaunchctlControl.run($0, captureStderr: true) }) {
        Thread.detachNewThread {
            let result = run(["kickstart", "-k", target])
            guard !result.succeeded else { return }
            say("could not restart this Mac's cluster service (\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))); "
                + "it runs the installed release after the next login")
        }
    }

    /// The `pid = N` line of `launchctl print` for a running job.
    static func jobPID(launchctlPrint output: String) -> Int32? {
        guard let expression = try? NSRegularExpression(pattern: #"(?m)^\s*pid\s*=\s*([1-9][0-9]*)\s*$"#),
              let match = expression.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return Int32(output[range])
    }
}
