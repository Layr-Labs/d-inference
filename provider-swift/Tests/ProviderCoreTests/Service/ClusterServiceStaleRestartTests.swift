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
        /// The pid `launchctl print` reports for the job; nil: the job is not loaded.
        let jobPID: Int32?

        init(jobPID: Int32?) { self.jobPID = jobPID }

        var printed: [String] { lock.withLock { printedLabels } }
        var kicked: [String] { lock.withLock { kickedTargets } }
        var said: [String] { lock.withLock { saidLines } }

        func print(_ label: String) -> LaunchctlControl.Output {
            lock.withLock { printedLabels.append(label) }
            guard let jobPID else { return .init(status: 113, stdout: "", stderr: "Could not find service") }
            return .init(status: 0, stdout: "gui/501/\(label) = {\n\tactive count = 4\n\tstate = running\n\n\tprogram = \(release)\n"
                + "\tpid = \(jobPID)\n\timmediate reason = speculative\n\tlast exit code = (never exited)\n}\n", stderr: "")
        }

        func kick(_ target: String) { lock.withLock { kickedTargets.append(target) } }
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

    /// The supervisor's state file as the supervisor of `version` writes it while its service runs.
    private func supervisor(_ directory: URL, version: String) {
        let state = ClusterMemberSupervisorState(supervisorPID: Self.supervisorPID, version: version, bootTime: 0,
            phase: .running, budget: ClusterMemberRestartBudget(), current: .init(pid: Self.servicePID, startedAt: 10),
            runs: 1, updatedAt: 10)
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

    @Test func theJobsPidIsReadFromLaunchctlPrint() {
        let output = "gui/501/io.darkbloom.cluster-service.dd20eb6e4828 = {\n\tactive count = 3\n\tstate = running\n"
            + "\tpid = 31357\n\tlast exit code = (never exited)\n}\n"
        #expect(ClusterServiceStaleRestart.jobPID(launchctlPrint: output) == 31357)
        #expect(ClusterServiceStaleRestart.jobPID(launchctlPrint: "gui/501/x = {\n\tstate = not running\n}\n") == nil)
    }
}

private let release = "/Applications/Darkbloom.app/Contents/MacOS/darkbloom"
