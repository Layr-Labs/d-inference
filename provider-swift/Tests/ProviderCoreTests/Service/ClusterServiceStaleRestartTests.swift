import Foundation
import Testing

@testable import ProviderCore

/// 0.10.12 W1-D2 (pair-2, DevNet): after `darkbloom update` on both Macs, a pair that serves only on its local API kept
/// both cluster services on the earlier release. Their supervisors' update cycle does not drain such a pair, so it never
/// restarted them; `restart` restarted only the parts, which ran the installed release. A part of the installed release
/// restarts its service's launchd job once. No launchd: the job's `launchctl print` and the kickstart are stand-ins.
@Suite("Cluster service left on an earlier release")
struct ClusterServiceStaleRestartTests {
    private final class Launchd: @unchecked Sendable {
        private let lock = NSLock()
        private var printedLabels: [String] = []
        private var kickedTargets: [String] = []
        private var saidLines: [String] = []
        private var recordsAtKick: [ClusterServiceStaleRestart.Asked?] = []
        /// The pid `launchctl print` reports for the job; nil: the job is not loaded.
        let jobPID: Int32?
        /// The service folder whose ask record each kick reads, as launchd would find it.
        let directory: URL?

        init(jobPID: Int32?, directory: URL? = nil) { self.jobPID = jobPID; self.directory = directory }

        var printed: [String] { lock.withLock { printedLabels } }
        var kicked: [String] { lock.withLock { kickedTargets } }
        var said: [String] { lock.withLock { saidLines } }
        var recordedAtKick: [ClusterServiceStaleRestart.Asked?] { lock.withLock { recordsAtKick } }

        func print(_ label: String) -> LaunchctlControl.Output {
            lock.withLock { printedLabels.append(label) }
            guard let jobPID else { return .init(status: 113, stdout: "", stderr: "Could not find service") }
            return .init(status: 0, stdout: "gui/501/\(label) = {\n\tactive count = 4\n\tstate = running\n\n\tprogram = \(release)\n"
                + "\tpid = \(jobPID)\n\timmediate reason = speculative\n\tlast exit code = (never exited)\n}\n", stderr: "")
        }

        func kick(_ target: String) {
            let record = directory.flatMap {
                ClusterSupervisionFiles.read(ClusterServiceStaleRestart.Asked.self,
                                             from: $0.appendingPathComponent(ClusterServiceStaleRestart.fileName))
            }
            lock.withLock { kickedTargets.append(target); recordsAtKick.append(record) }
        }
        func say(_ line: String) { lock.withLock { saidLines.append(line) } }
    }

    private static let supervisorPID: Int32 = 4242
    private static let servicePID: Int32 = 777

    private func serviceDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-cluster-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The supervisor's state file as the supervisor of `version` writes it while its service runs (`service`), or
    /// between a run that ended and the next (nil, as before a re-exec).
    private func supervisor(_ directory: URL, version: String, service: Int32? = ClusterServiceStaleRestartTests.servicePID) {
        let state = ClusterMemberSupervisorState(supervisorPID: Self.supervisorPID, version: version, bootTime: 0,
            phase: service == nil ? .updating : .running, budget: ClusterMemberRestartBudget(),
            current: service.map { .init(pid: $0, startedAt: 10) }, runs: 1, updatedAt: 10)
        #expect(ClusterSupervisionFiles.write(state, to: ClusterServiceAgent.supervisorStatePath(serviceDirectory: directory)))
    }

    /// The environment a part gets from its supervised service (`ClusterService.partEnvironment`).
    private func partEnvironment(_ directory: URL) -> [String: String] {
        [ClusterSupervisionFiles.healthPathEnvironmentKey: ClusterServiceAgent.partHealthPath(serviceDirectory: directory).path]
    }

    private func start(_ directory: URL, environment: [String: String]? = nil, thisVersion: String,
                       parentPID: Int32 = ClusterServiceStaleRestartTests.servicePID, now: Double = 1_000, launchd: Launchd)
        -> ClusterServiceStaleRestart.Decision {
        ClusterServiceStaleRestart.restartIfStale(environment: environment ?? partEnvironment(directory),
            executablePath: release, thisVersion: thisVersion, parentPID: parentPID, now: now,
            printJob: { launchd.print($0) }, kick: { target, _ in launchd.kick(target) }, say: { launchd.say($0) })
    }

    private var jobTarget: String { LaunchctlControl.target(label: ClusterServiceAgentPlan.label(executablePath: release)) }

    @Test func aPartOfTheInstalledReleaseRestartsAServiceLeftOnTheEarlierOneOnce() throws {
        let directory = try serviceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        supervisor(directory, version: "0.10.11")
        let launchd = Launchd(jobPID: Self.supervisorPID)

        #expect(start(directory, thisVersion: "0.10.12", launchd: launchd) == .restart(from: "0.10.11", to: "0.10.12"))
        #expect(launchd.kicked == [jobTarget])
        #expect(launchd.said.count == 1)
        #expect(launchd.said.first?.contains("still runs v0.10.11 while v0.10.12 is installed") == true)
        let asked = ClusterSupervisionFiles.read(ClusterServiceStaleRestart.Asked.self,
                                                 from: directory.appendingPathComponent(ClusterServiceStaleRestart.fileName))
        #expect(asked == .init(from: "0.10.11", to: "0.10.12", supervisorPID: Self.supervisorPID, at: 1_000))

        // The next part's start (the restarted service's, or one before the restart lands) asks nothing more.
        #expect(start(directory, thisVersion: "0.10.12", now: 1_060, launchd: launchd) == .nothing)
        #expect(launchd.kicked.count == 1)
    }

    @Test func devNetBuildsCompareTheirBuildNumbers() throws {
        let directory = try serviceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // W1's update: the services stayed on .175 while their parts ran .176.
        supervisor(directory, version: "0.10.10-dev.branch.175")
        let launchd = Launchd(jobPID: Self.supervisorPID)
        #expect(start(directory, thisVersion: "0.10.12-dev.branch.176", launchd: launchd)
                == .restart(from: "0.10.10-dev.branch.175", to: "0.10.12-dev.branch.176"))
        #expect(launchd.kicked == [jobTarget])

        let current = try serviceDirectory()
        defer { try? FileManager.default.removeItem(at: current) }
        supervisor(current, version: "0.10.12-dev.branch.176")
        let quiet = Launchd(jobPID: Self.supervisorPID)
        #expect(start(current, thisVersion: "0.10.12-dev.branch.176", launchd: quiet) == .nothing)
        #expect(quiet.kicked.isEmpty)
    }

    @Test func aServiceOnThisReleaseOrANewerOneIsLeftAloneWithoutAskingLaunchd() throws {
        for version in ["0.10.12", "0.10.13", "not-a-release"] {
            let directory = try serviceDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            supervisor(directory, version: version)
            let launchd = Launchd(jobPID: Self.supervisorPID)
            #expect(start(directory, thisVersion: "0.10.12", launchd: launchd) == .nothing, "supervisor \(version)")
            #expect(launchd.printed.isEmpty && launchd.kicked.isEmpty, "supervisor \(version)")
        }
    }

    @Test func onlyAPartOfTheSupervisedServiceAsks() throws {
        let directory = try serviceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        supervisor(directory, version: "0.10.11")
        let launchd = Launchd(jobPID: Self.supervisorPID)
        // Another process: not the service's part (its parent is another process), no supervisor at all, or the service
        // itself, whose heartbeat is the supervisor's file.
        #expect(start(directory, thisVersion: "0.10.12", parentPID: 778, launchd: launchd) == .nothing)
        #expect(start(directory, environment: [:], thisVersion: "0.10.12", launchd: launchd) == .nothing)
        let service = [ClusterSupervisionFiles.healthPathEnvironmentKey: ClusterServiceAgent.healthPath(serviceDirectory: directory).path]
        #expect(start(directory, environment: service, thisVersion: "0.10.12", launchd: launchd) == .nothing)
        #expect(launchd.kicked.isEmpty)
    }

    @Test func aSupervisorThatIsNotTheLaunchdJobIsLeftAlone() throws {
        let directory = try serviceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        supervisor(directory, version: "0.10.11")
        // A supervisor started from a terminal beside a job of another process, or no job loaded.
        for launchd in [Launchd(jobPID: 5_000), Launchd(jobPID: nil)] {
            #expect(start(directory, thisVersion: "0.10.12", launchd: launchd) == .nothing)
            #expect(launchd.kicked.isEmpty)
        }
    }

    @Test func theSameReleaseIsAskedForAtMostOnceInSixHours() {
        let state = ClusterMemberSupervisorState(supervisorPID: Self.supervisorPID, version: "0.10.11", bootTime: 0,
            phase: .running, budget: ClusterMemberRestartBudget(), current: .init(pid: Self.servicePID, startedAt: 10),
            updatedAt: 10)
        func decide(_ asked: ClusterServiceStaleRestart.Asked?, now: Double) -> ClusterServiceStaleRestart.Decision {
            ClusterServiceStaleRestart.decide(thisVersion: "0.10.12", parentPID: Self.servicePID, supervisor: state,
                                              jobPID: Self.supervisorPID, asked: asked, now: now)
        }
        let restart = ClusterServiceStaleRestart.Decision.restart(from: "0.10.11", to: "0.10.12")
        let once = ClusterServiceStaleRestart.Asked(from: "0.10.11", to: "0.10.12", supervisorPID: 1, at: 100_000)
        #expect(decide(nil, now: 100_000) == restart)
        #expect(decide(once, now: 100_000 + 3_600) == .nothing)
        #expect(decide(once, now: 100_000 + ClusterServiceStaleRestart.onceEverySeconds + 1) == restart)
        // An ask for an earlier release says nothing about this one.
        #expect(decide(.init(from: "0.10.10", to: "0.10.11", supervisorPID: 1, at: 100_000), now: 100_060) == restart)
    }

    /// The order is the releases' (`SemanticVersion`), never the text's: as text, 0.10.9 sorts after 0.10.10 and 0.10.12,
    /// and DevNet's build 99 after 100. W1's morning run is the first case: a supervisor on .176, the folded build's part.
    @Test(arguments: [("0.10.12-dev.branch.176", "0.10.12-dev.branch.177", true),
                      ("0.10.12-dev.branch.177", "0.10.12-dev.branch.176", false),
                      ("0.10.12-dev.branch.99", "0.10.12-dev.branch.100", true),
                      ("0.10.12-dev.branch.100", "0.10.12-dev.branch.99", false),
                      ("0.10.9-dev.branch.80", "0.10.12-dev.branch.176", true),
                      ("0.10.9", "0.10.10", true),
                      ("0.10.10", "0.10.9", false),
                      ("0.10.9", "0.10.12", true),
                      ("0.10.12", "0.10.9", false),
                      ("0.10.12-dev.branch.176", "0.10.12-dev.branch.176", false),
                      ("0.10.12", "0.10.12", false)])
    func theReleasesOrderDecides(supervisorVersion: String, partVersion: String, restarts: Bool) throws {
        let directory = try serviceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        supervisor(directory, version: supervisorVersion)
        let launchd = Launchd(jobPID: Self.supervisorPID)
        let decision = start(directory, thisVersion: partVersion, launchd: launchd)
        #expect(decision == (restarts ? .restart(from: supervisorVersion, to: partVersion) : .nothing),
                "\(supervisorVersion) -> \(partVersion)")
        #expect(launchd.kicked.count == (restarts ? 1 : 0), "\(supervisorVersion) -> \(partVersion)")
    }

    @Test func aNewerInstalledReleaseAsksAgainWithinSixHours() throws {
        let directory = try serviceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        supervisor(directory, version: "0.10.11")
        let launchd = Launchd(jobPID: Self.supervisorPID)
        // The record is the installed release's: a service still on 0.10.11 when 0.10.13 is installed is asked again.
        #expect(start(directory, thisVersion: "0.10.12", launchd: launchd) == .restart(from: "0.10.11", to: "0.10.12"))
        #expect(start(directory, thisVersion: "0.10.13", now: 1_060, launchd: launchd) == .restart(from: "0.10.11", to: "0.10.13"))
        #expect(start(directory, thisVersion: "0.10.13", now: 1_120, launchd: launchd) == .nothing)
        #expect(launchd.kicked.count == 2)
    }

    @Test func itReadsItsOwnJobAndAsksOnlyOnceTheRecordIsOnDisk() throws {
        let directory = try serviceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        supervisor(directory, version: "0.10.11")
        let launchd = Launchd(jobPID: Self.supervisorPID, directory: directory)
        #expect(start(directory, thisVersion: "0.10.12", launchd: launchd) == .restart(from: "0.10.11", to: "0.10.12"))
        #expect(launchd.printed == [ClusterServiceAgentPlan.label(executablePath: release)])
        #expect(launchd.kicked == [jobTarget])
        #expect(launchd.recordedAtKick == [.init(from: "0.10.11", to: "0.10.12", supervisorPID: Self.supervisorPID, at: 1_000)])
    }

    /// The record keeps the next part's start from asking again; a restart it can't record is not asked for.
    @Test func anAskThatCannotBeRecordedIsNotMade() throws {
        let directory = try serviceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        supervisor(directory, version: "0.10.11")
        // A folder where the record goes: the write's rename fails, as on a full or read-only disk.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(ClusterServiceStaleRestart.fileName),
                                                withIntermediateDirectories: false)
        let launchd = Launchd(jobPID: Self.supervisorPID)
        #expect(start(directory, thisVersion: "0.10.12", launchd: launchd) == .nothing)
        #expect(launchd.kicked.isEmpty)
        #expect(launchd.said.count == 1)
        #expect(launchd.said.first?.contains("could not record the restart") == true)
    }

    /// Between a service run that ended and the next (the supervisor's last write before a re-exec) there is no service.
    @Test func aSupervisorWithNoServiceRunningIsLeftAlone() throws {
        let directory = try serviceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        supervisor(directory, version: "0.10.11", service: nil)
        let launchd = Launchd(jobPID: Self.supervisorPID)
        #expect(start(directory, thisVersion: "0.10.12", launchd: launchd) == .nothing)
        #expect(launchd.kicked.isEmpty)
    }

    /// `kickstart -k`: a plain `kickstart` does nothing to a job that runs.
    @Test func theAskKillsTheRunningJobAndSaysWhenLaunchctlRefuses() async {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var arguments: [[String]] = []
            var lines: [String] = []
        }
        let seen = Seen()
        let target = "gui/501/io.darkbloom.cluster-service.0123456789ab"
        ClusterServiceStaleRestart.kickInBackground(target, say: { line in seen.lock.withLock { seen.lines.append(line) } },
            run: { arguments in
                seen.lock.withLock { seen.arguments.append(arguments) }
                return .init(status: 113, stdout: "", stderr: "Could not find service in domain for user gui: 501\n")
            })
        let deadline = Date().addingTimeInterval(10)
        while seen.lock.withLock({ seen.lines.isEmpty }), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(seen.lock.withLock { seen.arguments } == [["kickstart", "-k", target]])
        #expect(seen.lock.withLock { seen.lines }
                == ["could not restart this Mac's cluster service (Could not find service in domain for user gui: 501); "
                    + "it runs the installed release after the next login"])
    }

    /// A `start` part runs under the AppKit host, which has taken SIGTERM and SIGINT for its own drain before
    /// `Start.run()` (`ProviderSignalHandler`: ignored, read by dispatch sources). During the wait after the ask, the
    /// service's stop must still end the part at once. Signals change process-wide state, so this runs in a child.
    @Test func theServicesStopEndsAPartDuringTheWaitAlsoUnderTheHostsHandler() async {
        await #expect(processExitsWith: .signal(SIGTERM)) {
            var sources: [DispatchSourceSignal] = []
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler {}
                source.resume()
                sources.append(source)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { _ = kill(getpid(), SIGTERM) }
            ClusterServiceStaleRestart.waitForStop(seconds: 5)
            withExtendedLifetime(sources) {}
            exit(0)  // The wait ended and the stop never took.
        }
    }

    /// A part that nothing stopped starts as before, with its own handlers back.
    @Test func afterTheWaitThePartsOwnHandlersAreBack() async {
        await #expect(processExitsWith: .success) {
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            ClusterServiceStaleRestart.waitForStop(seconds: 0.1)
            _ = kill(getpid(), SIGTERM)
            _ = kill(getpid(), SIGINT)
            usleep(300_000)
            exit(0)
        }
    }

    @Test func theJobsPidIsReadFromLaunchctlPrint() {
        let output = "gui/501/io.darkbloom.cluster-service.dd20eb6e4828 = {\n\tactive count = 3\n\tstate = running\n"
            + "\tpid = 31357\n\tlast exit code = (never exited)\n}\n"
        #expect(ClusterServiceStaleRestart.jobPID(launchctlPrint: output) == 31357)
        #expect(ClusterServiceStaleRestart.jobPID(launchctlPrint: "gui/501/x = {\n\tstate = not running\n}\n") == nil)
    }
}

private let release = "/Applications/Darkbloom.app/Contents/MacOS/darkbloom"
