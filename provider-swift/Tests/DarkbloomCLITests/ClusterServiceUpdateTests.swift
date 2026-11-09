import CryptoKit
import Foundation
import ProviderCore
import Testing
@testable import darkbloom
@testable import ProviderCore

/// The cluster service supervisor's update (`darkbloom cluster`): its wiring to the single-Mac gate, the pair's update
/// slot and `darkbloom update`'s request, around a real supervisor with a shell standing in for the cluster service
/// (no model, network, launchd or re-exec: the re-exec is observed). The start check before a restart runs the
/// temporary install's `darkbloom`, a script. The cycle itself is covered with real installs in `ClusterPairUpdateTests`.
@Suite("Cluster service update", .serialized)
struct ClusterServiceUpdateTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.withLock { values.append(value) } }
        var all: [String] { lock.withLock { values } }
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func state(_ directory: URL) -> ClusterMemberSupervisorState? {
        ClusterSupervisionFiles.read(ClusterMemberSupervisorState.self, from: ClusterServiceAgent.supervisorStatePath(serviceDirectory: directory))
    }

    private func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    /// A cluster ID whose update slot falls `2...4` s from now, so the real slot schedule fires during the test.
    private func imminentClusterID() -> String {
        let now = Date().timeIntervalSince1970
        for index in 0..<100_000 {
            let id = "slot-check-\(index)"
            let wait = ClusterMemberUpdateSlot.nextSlot(after: now, clusterID: id) - now
            if (2...4).contains(wait) { return id }
        }
        return "slot-check-none"
    }

    /// `service` stands in for the cluster service (a shell running `script` unless a test install's binary serves);
    /// `installed` is the binary the supervisor restarts into, start-checked within `startCheckSeconds`.
    private func configuration(directory: URL, script: String = "", service: String = "/bin/sh",
                               installed: String = "/installed/darkbloom", startCheckSeconds: Double = 5,
                               guardSeconds: Double = 600, autoUpdate: Bool, clusterID: String,
                               recovery: ClusterCandidateRecovery? = nil, reexecs: Recorder,
                               follow: @escaping @Sendable (@escaping @Sendable (String) -> Void,
                                                            @escaping @Sendable (String) async throws -> Void) async
                                   -> ClusterPairUpdateCycle.FollowOutcome = { _, _ in .nothingToFollow },
                               quarantined: @escaping @Sendable () -> String? = { nil },
                               run: @escaping @Sendable (String?, @escaping @Sendable (String) -> Void,
                                                         @escaping @Sendable (String) async throws -> Void) async -> AutoUpdateController.Outcome)
        -> ClusterMemberSupervisor.Configuration {
        var limits = ClusterMemberLivenessGuard.Limits()
        limits.intervalSeconds = 0.2
        limits.startGraceSeconds = guardSeconds
        limits.downSeconds = guardSeconds
        return .init(executable: service, childArguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
            statePath: ClusterServiceAgent.supervisorStatePath(serviceDirectory: directory),
            healthPath: ClusterServiceAgent.healthPath(serviceDirectory: directory),
            setup: nil, coordinatorURL: "http://127.0.0.1:9", autoUpdate: autoUpdate,
            budgetLimits: .init(maxQuickFailures: 5, quickFailureWindowSeconds: 30, initialBackoffSeconds: 1, maxBackoffSeconds: 1),
            guardLimits: limits, recycleGraceSeconds: 5, reexecArguments: [installed, "cluster", "service", "--supervise"],
            logName: "cluster service supervisor", childPollSeconds: 0.05,
            pairUpdate: .init(clusterID: { clusterID }, run: run,
                requestPath: ClusterServiceAgent.updateRequestPath(serviceDirectory: directory),
                progressPath: ClusterServiceAgent.updateProgressPath(serviceDirectory: directory),
                recovery: recovery, follow: follow, quarantined: quarantined),
            reexec: { reexecs.add($0.joined(separator: " ")) }, startCheckTimeoutSeconds: startCheckSeconds,
            sweepsOrphans: false)
    }

    // MARK: - Wiring

    /// `darkbloom cluster`'s supervisor takes the single-Mac gate: `auto_update`, `DARKBLOOM_NO_UPDATE_CHECK` and the
    /// configured coordinator, and keys the slot on the pairing's cluster ID.
    @Test(arguments: [(true, false, true), (false, false, false), (true, true, false)])
    func supervisorTakesTheSingleMacGate(autoUpdate: Bool, noUpdateCheck: Bool, expected: Bool) throws {
        let directory = try temporaryDirectory("cluster-update-gate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.toml")
        var config = ProviderConfig(provider: ProviderSettings(name: "pair"))
        config.provider.autoUpdate = autoUpdate
        config.coordinator.url = "wss://coordinator.example.invalid/ws/provider"
        try ConfigManager.save(config, to: path)
        let environment = noUpdateCheck ? ["DARKBLOOM_NO_UPDATE_CHECK": "1"] : [:]
        let configured = Cluster.Service.supervisorConfiguration(executable: "/A/darkbloom", serviceOptions: ["--config", path.path],
            configPath: path.path, environment: environment, serviceDirectory: directory,
            reexecArguments: ["/A/darkbloom", "cluster", "service", "--supervise"], clusterID: { "pair-7f3a" })
        #expect(configured.autoUpdate == expected)
        #expect(configured.coordinatorURL == "wss://coordinator.example.invalid/ws/provider")
        #expect(configured.setup == nil, "the service waits for the cable itself")
        let pair = try #require(configured.pairUpdate)
        #expect(pair.clusterID() == "pair-7f3a")
        #expect(pair.requestPath == directory.appendingPathComponent("service-update-request.json"))
        #expect(pair.progressPath == directory.appendingPathComponent("service-update.json"))
        #expect(pair.recovery != nil, "a release the pair installs is promoted or rolled back by its service's health")
        #expect(configured.childArguments == ["cluster", "service", "--config", path.path])
    }

    /// A cycle at the slot or catching up with the other Mac (no request) asks a second round when the first gets no
    /// answer; a cycle that `darkbloom update` asked for doesn't (`ReleaseCheck.pairCycle`). Through the supervisor's
    /// own `run`, with a stand-in for the cycle that reads the release check of the environment it was given.
    @Test func onlyTheAutomaticCyclesOfTheServiceAskASecondRound() async throws {
        let directory = try temporaryDirectory("cluster-update-rounds")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.toml")
        var config = ProviderConfig(provider: ProviderSettings(name: "pair"))
        config.coordinator.url = "wss://coordinator.example.invalid/ws/provider"
        try ConfigManager.save(config, to: path)
        let cycles = Recorder()
        let configured = Cluster.Service.supervisorConfiguration(executable: "/A/darkbloom", serviceOptions: ["--config", path.path],
            configPath: path.path, environment: [:], serviceDirectory: directory,
            reexecArguments: ["/A/darkbloom", "cluster", "service", "--supervise"], clusterID: { "pair-7f3a" },
            runCycle: { environment, request, _ in
                cycles.add("\(request ?? "slot"): rounds \(environment.updater.releaseCheck.rounds)")
                return .upToDate
            })
        let pair = try #require(configured.pairUpdate)

        #expect(await pair.run(nil, { _ in }, { _ in }) == .upToDate)
        #expect(await pair.run("update-request-1", { _ in }, { _ in }) == .upToDate)

        #expect(cycles.all == ["slot: rounds 2", "update-request-1: rounds 1"])
    }

    // MARK: - Following the other Mac's rollback

    /// While no cycle runs (here with automatic updates off, which do not stop it), the supervisor checks at once whether
    /// the other Mac rolled back the release this Mac runs; following it ends in the same restart as an update, into
    /// the restored release. Its progress reports this Mac's quarantine to the other Mac.
    @Test func supervisorFollowsTheOtherMacsRollbackAndRestartsIntoTheRestoredRelease() async throws {
        let directory = try temporaryDirectory("cluster-follow-rollback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Recorder(), follows = Recorder(), reexecs = Recorder()
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: "exec sleep 60",
            autoUpdate: false, clusterID: imminentClusterID(), reexecs: reexecs,
            follow: { log, restart in
                follows.add("follow")
                log("cluster update: test follow")
                try? await restart("1.0.0")
                return .followed(.restarted(from: "2.0.0", to: "1.0.0", drained: true))
            },
            quarantined: { "2.0.0" }) { request, _, _ in
                calls.add(request ?? "slot")
                return .upToDate
            })
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 2) {
            ClusterPairUpdate.readProgress(from: ClusterServiceAgent.updateProgressPath(serviceDirectory: directory))?.quarantined == "2.0.0"
        }, "the other Mac reads this Mac's quarantine")
        #expect(await waitUntil(seconds: 15) { !reexecs.all.isEmpty }, "the follow restarted the service and the supervisor re-executed")
        #expect(follows.all == ["follow"])
        #expect(reexecs.all == ["/installed/darkbloom cluster service --supervise"])
        #expect(state(directory)?.lastRun?.end == "stopped to restart into v1.0.0")
        #expect(calls.all.isEmpty, "automatic updates are off: no slot cycle ran")
        #expect(await waitUntil(seconds: 10) { state(directory)?.runs == 2 && state(directory)?.phase == .running })
        supervisor.requestStop()
        #expect(await run.value == 0)
        #expect(follows.all == ["follow"], "the next check is a minute later")
    }

    /// A cluster ID whose update slot is at least ten minutes away, so no slot fires during the test.
    private func distantClusterID() -> String {
        let now = Date().timeIntervalSince1970
        for index in 0..<100_000 {
            let id = "slot-far-\(index)"
            if ClusterMemberUpdateSlot.nextSlot(after: now, clusterID: id) - now > 600 { return id }
        }
        return "slot-far-none"
    }

    /// The other Mac runs a newer release: with automatic updates on, the supervisor runs the pair's cycle at once, long
    /// before its slot, so this Mac catches up within the follow check's minute. With them off it runs none.
    @Test(arguments: [true, false])
    func supervisorFollowsAnOtherMacOnANewerReleaseAtOnce(autoUpdate: Bool) async throws {
        let directory = try temporaryDirectory("cluster-follow-forward")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Recorder(), follows = Recorder(), reexecs = Recorder()
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: "exec sleep 60",
            autoUpdate: autoUpdate, clusterID: distantClusterID(), reexecs: reexecs,
            follow: { _, _ in
                follows.add("follow")
                return .otherMacNewer("2.0.0")
            }) { request, log, restart in
                calls.add(request ?? "cycle")
                log("cluster update: test cycle")
                try? await restart("2.0.0")
                return .restarted(from: "1.0.0", to: "2.0.0", drained: true)
            })
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 5) { !follows.all.isEmpty })
        if autoUpdate {
            #expect(await waitUntil(seconds: 15) { !reexecs.all.isEmpty }, "the cycle ran before the slot and restarted the service")
            #expect(calls.all == ["cycle"])
            #expect(state(directory)?.lastRun?.end == "stopped to restart into v2.0.0")
        } else {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            #expect(calls.all.isEmpty && reexecs.all.isEmpty, "automatic updates are off: `darkbloom update` is the operator's")
        }
        supervisor.requestStop()
        #expect(await run.value == 0)
    }

    // MARK: - The slot

    /// At the pair's slot the cycle runs beside the serving service; its restart stops the service and the supervisor
    /// starts again from the installed binary (re-exec), with the progress idle beforehand for the other Mac.
    @Test func slotRunsTheCycleBesideTheServiceAndRestartsIntoTheRelease() async throws {
        let directory = try temporaryDirectory("cluster-update-slot")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Recorder(), reexecs = Recorder()
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: "exec sleep 60",
            autoUpdate: true, clusterID: imminentClusterID(), reexecs: reexecs) { request, log, restart in
                calls.add(request ?? "slot")
                log("cluster update: test cycle")
                try? await restart("2.0.0")
                return .restarted(from: "1.0.0", to: "2.0.0", drained: true)
            })
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 2) {
            ClusterPairUpdate.readProgress(from: ClusterServiceAgent.updateProgressPath(serviceDirectory: directory))?.phase == .idle
        }, "the other Mac never waits for a cycle of an earlier run")
        #expect(await waitUntil(seconds: 15) { !reexecs.all.isEmpty }, "the slot fired, the service stopped and the supervisor re-executed")
        #expect(calls.all == ["slot"])
        #expect(reexecs.all == ["/installed/darkbloom cluster service --supervise"])
        #expect(state(directory)?.lastRun?.end == "stopped to restart into v2.0.0")
        // In a test the re-exec returns: the supervisor keeps going and starts the service again.
        #expect(await waitUntil(seconds: 10) { state(directory)?.runs == 2 && state(directory)?.phase == .running })
        supervisor.requestStop()
        #expect(await run.value == 0)
        #expect(calls.all == ["slot"], "the next slot is a period later")
    }

    /// With automatic updates off the slot never runs a cycle, and the other Mac reads `disabled`: from the start, and
    /// again a minute after a cycle `darkbloom update` asked for ended, so the other Mac's slot downloads nothing.
    @Test func autoUpdateOffRunsNoSlotCycle() async throws {
        let directory = try temporaryDirectory("cluster-update-off")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Recorder(), reexecs = Recorder()
        let progressPath = ClusterServiceAgent.updateProgressPath(serviceDirectory: directory)
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: "exec sleep 60",
            autoUpdate: false, clusterID: imminentClusterID(), reexecs: reexecs) { request, _, _ in
                calls.add(request ?? "slot")
                return .upToDate
            })
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 2) { ClusterPairUpdate.readProgress(from: progressPath)?.phase == .disabled })
        try await Task.sleep(nanoseconds: 6_000_000_000)
        #expect(calls.all.isEmpty && reexecs.all.isEmpty, "the slot passed without a cycle")

        let now = Date().timeIntervalSince1970
        ClusterPairUpdate.writeProgress(.init(phase: .failed, target: "2.0.0", running: "1.0.0", request: "update-1",
                                              writtenAt: now, detail: "hashMismatch"), to: progressPath)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(ClusterPairUpdate.readProgress(from: progressPath)?.phase == .failed, "a fresh end is still the other Mac's answer")
        ClusterPairUpdate.writeProgress(.init(phase: .idle, running: "1.0.0", request: "update-1",
            writtenAt: now - ClusterPairUpdate.progressStaleSeconds - 1, detail: "up to date"), to: progressPath)
        #expect(await waitUntil(seconds: 5) { ClusterPairUpdate.readProgress(from: progressPath)?.phase == .disabled },
                "an end older than a minute gives way to disabled again")
        #expect(calls.all.isEmpty)
        supervisor.requestStop()
        #expect(await run.value == 0)
    }

    // MARK: - `darkbloom update`

    /// `darkbloom update` on a cluster Mac asks the supervisor for the pair's restart now (automatic updates off or on)
    /// and follows its progress: the cluster service restarts without a log-out.
    @Test func darkbloomUpdateRestartsTheClusterService() async throws {
        let directory = try temporaryDirectory("cluster-update-manual")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Recorder(), reexecs = Recorder()
        let progressPath = ClusterServiceAgent.updateProgressPath(serviceDirectory: directory)
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: "exec sleep 60",
            autoUpdate: false, clusterID: "pair-far-from-its-slot", reexecs: reexecs) { request, _, restart in
                calls.add(request ?? "slot")
                for phase in [ClusterPairUpdateProgress.Phase.staged, .drained, .restarting] {
                    ClusterPairUpdate.writeProgress(.init(phase: phase, target: "2.0.0", running: "1.0.0", cycleStartedAt: 1,
                        request: request, writtenAt: Date().timeIntervalSince1970), to: progressPath)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                try? await restart("2.0.0")
                return .restarted(from: "1.0.0", to: "2.0.0", drained: true)
            })
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 5) { state(directory)?.phase == .running })
        let request = ClusterPairUpdate.Request(createdAt: Date().timeIntervalSince1970)
        let said = Recorder()
        let outcome = try await ClusterServiceUpdateRequest.restart(into: "2.0.0", request: request, serviceDirectory: directory,
                                                                   timeoutSeconds: 20, pollSeconds: 0.1, say: { said.add($0) })
        #expect(outcome == .restarting, "\(said.all)")
        #expect(said.all.contains { $0.contains("drained for v2.0.0") }, "\(said.all)")
        #expect(calls.all == [request.id], "the request ran one cycle now, not at the slot")
        #expect(await waitUntil(seconds: 10) { reexecs.all.count == 1 })
        #expect(!FileManager.default.fileExists(atPath: ClusterServiceAgent.updateRequestPath(serviceDirectory: directory).path),
                "the request is answered once")
        supervisor.requestStop()
        #expect(await run.value == 0)
    }

    /// R5-3 (M5 Ultra pair, 0.10.7 → 0.10.8): the restarted service published `idle` running the new release before
    /// the command saw its own request reach `restarting`, and the command waited out its whole timeout. This Mac
    /// running the release it asked for is the restart done, and the command says so.
    @Test func darkbloomUpdateEndsOnceThisMacRunsTheRelease() async throws {
        let directory = try temporaryDirectory("cluster-update-restarted")
        defer { try? FileManager.default.removeItem(at: directory) }
        let progressPath = ClusterServiceAgent.updateProgressPath(serviceDirectory: directory)
        ClusterPairUpdate.writeProgress(.init(phase: .idle, running: "1.0.0", writtenAt: Date().timeIntervalSince1970 - 30),
                                        to: progressPath)
        let request = ClusterPairUpdate.Request(createdAt: Date().timeIntervalSince1970)
        let restarted = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            ClusterPairUpdate.writeProgress(.init(phase: .drained, target: "2.0.0", running: "1.0.0", cycleStartedAt: 1,
                request: request.id, writtenAt: Date().timeIntervalSince1970), to: progressPath)
            try? await Task.sleep(nanoseconds: 300_000_000)
            // The new service's first word: no cycle, no request, the new release.
            ClusterPairUpdate.writeProgress(.init(phase: .idle, running: "2.0.0", writtenAt: Date().timeIntervalSince1970,
                                                  detail: "up to date"), to: progressPath)
        }
        let said = Recorder(), started = Date()
        let outcome = try await ClusterServiceUpdateRequest.restart(into: "2.0.0", request: request, serviceDirectory: directory,
                                                                   timeoutSeconds: 10, pollSeconds: 0.1, say: { said.add($0) })
        await restarted.value
        #expect(outcome == .restarted, "\(said.all)")
        #expect(Date().timeIntervalSince(started) < 5, "ended once the new release ran, not at the timeout")
        #expect(said.all.last == "This Mac's cluster service now runs v2.0.0; the cluster sets itself up again once both Macs run it.",
                "\(said.all)")
        #expect(!said.all.contains { $0.contains("Still waiting") }, "\(said.all)")
    }

    /// The old service still running the old release, with no word on the request, is no restart: the command waits.
    @Test func darkbloomUpdateKeepsWaitingWhileThisMacRunsTheOldRelease() async throws {
        let directory = try temporaryDirectory("cluster-update-old")
        defer { try? FileManager.default.removeItem(at: directory) }
        ClusterPairUpdate.writeProgress(.init(phase: .idle, running: "1.0.0", writtenAt: Date().timeIntervalSince1970),
                                        to: ClusterServiceAgent.updateProgressPath(serviceDirectory: directory))
        let said = Recorder()
        let outcome = try await ClusterServiceUpdateRequest.restart(into: "2.0.0", request: .init(createdAt: Date().timeIntervalSince1970),
            serviceDirectory: directory, timeoutSeconds: 1, pollSeconds: 0.1, say: { said.add($0) })
        #expect(outcome == .waiting)
        #expect(said.all.last?.hasPrefix("Still waiting after 1 s") == true, "\(said.all)")
    }

    /// A supervisor of an earlier build publishes no progress: the command says how to restart instead of waiting.
    @Test func darkbloomUpdateWithAnEarlierServiceSaysToLogOutAndIn() async throws {
        let directory = try temporaryDirectory("cluster-update-earlier")
        defer { try? FileManager.default.removeItem(at: directory) }
        let said = Recorder()
        let outcome = try await ClusterServiceUpdateRequest.restart(into: "2.0.0", request: .init(createdAt: Date().timeIntervalSince1970),
            serviceDirectory: directory, timeoutSeconds: 1, say: { said.add($0) })
        #expect(outcome == .waiting)
        #expect(said.all.first?.contains("Log out and back in on both Macs") == true, "\(said.all)")
    }

    // MARK: - Candidate promotion and rollback

    /// The release a cycle installed is a candidate: three starts of its service that end on their own restore the
    /// verified predecessor, quarantine the release and start again from the restored binary, once it passes its
    /// start check.
    @Test func failingCandidateIsRolledBackAndTheSupervisorRestartsFromThePredecessor() async throws {
        let install = try CandidateInstall()
        defer { install.cleanUp() }
        let directory = try temporaryDirectory("cluster-update-rollback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reexecs = Recorder()
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: "exit 1",
            installed: install.binary, autoUpdate: false, clusterID: "pair-far-from-its-slot",
            recovery: ClusterCandidateRecovery(updater: install.updater), reexecs: reexecs) { _, _, _ in .upToDate })
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 20) { !reexecs.all.isEmpty }, "three failed starts roll the candidate back")
        #expect(reexecs.all == ["\(install.binary) cluster service --supervise"])
        #expect(try install.liveRelease() == "1.0.0")
        let recovery = try UpdateRecoveryStore(installRoot: install.installRoot, verifyCodeSignatures: false).loadState()
        #expect(recovery.quarantine?.version == "2.0.0" && recovery.candidate == nil)
        #expect((state(directory)?.runs ?? 0) >= 3, "rolled back at the third failed start")
        supervisor.requestStop()
        #expect(await run.value == 0)
    }

    /// The predecessor a rollback restored is start-checked too: one that cannot start is not restarted into, and the
    /// supervisor starts the cluster service again itself.
    @Test func restoredPredecessorThatCannotStartIsNotRestartedInto() async throws {
        let install = try CandidateInstall(predecessor: .exitsNonZero)
        defer { install.cleanUp() }
        let directory = try temporaryDirectory("cluster-update-rollback-check")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reexecs = Recorder()
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: "exit 1",
            installed: install.binary, autoUpdate: false, clusterID: "pair-far-from-its-slot",
            recovery: ClusterCandidateRecovery(updater: install.updater), reexecs: reexecs) { _, _, _ in .upToDate })
        let run = Task { await supervisor.run() }
        let store = UpdateRecoveryStore(installRoot: install.installRoot, verifyCodeSignatures: false)
        #expect(await waitUntil(seconds: 20) { (try? store.loadState())?.quarantine?.version == "2.0.0" },
                "three failed starts roll the candidate back")
        #expect(await waitUntil(seconds: 10) { (state(directory)?.runs ?? 0) >= 4 }, "the service starts again under this supervisor")
        #expect(reexecs.all.isEmpty, "a restored binary that cannot start is not restarted into")
        #expect(try install.liveRelease() == "1.0.0")
        supervisor.requestStop()
        #expect(await run.value == 0)
    }

    /// Release 2.0.0's cluster service as a shell: it beats as the release's service does (when `beats`) and, as the real
    /// one does (`Cluster.Service.run`), stops in order and exits 0 when SIGTERM asks it to.
    private static func candidateService(beats: Bool) -> String {
        "trap 'exit 0' TERM; while :; do "
            + (beats ? #"printf '{"pid":%d,"version":"2.0.0","phase":"serving","writtenAt":%s}' $$ "$(date +%s)" "#
                + #"> "$DARKBLOOM_CLUSTER_MEMBER_HEALTH_FILE"; "# : "")
            + "sleep 0.2; done"
    }

    private func recoveryState(_ install: CandidateInstall) throws -> UpdateRecoveryState {
        try UpdateRecoveryStore(installRoot: install.installRoot, verifyCodeSignatures: false).loadState()
    }

    /// A clean stop of the candidate's cluster service that its supervisor did not ask for: `darkbloom cluster`
    /// replacing a service started from a terminal (`ClusterService.stopDetached`), Ctrl-C there, or a `kill`. The
    /// service stops in order and exits 0, and the supervisor starts it again. Each was counted as a failed start, and
    /// the third quarantined a release nothing was wrong with.
    @Test func aCleanStopTheSupervisorDidNotAskForIsNotAFailedStart() async throws {
        let install = try CandidateInstall()
        defer { install.cleanUp() }
        let directory = try temporaryDirectory("cluster-update-clean-stop")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reexecs = Recorder()
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory,
            script: Self.candidateService(beats: true), installed: install.binary, autoUpdate: false,
            clusterID: "pair-far-from-its-slot", recovery: ClusterCandidateRecovery(updater: install.updater),
            reexecs: reexecs) { _, _, _ in .upToDate })
        let run = Task { await supervisor.run() }
        let healthPath = ClusterServiceAgent.healthPath(serviceDirectory: directory)
        for stop in 1...3 {
            // Once it beats, its SIGTERM trap is set: the stop is the clean one.
            #expect(await waitUntil(seconds: 10) {
                guard let current = state(directory)?.current, state(directory)?.runs == stop else { return false }
                return ClusterSupervisionFiles.read(ClusterMemberHealth.self, from: healthPath)?.pid == current.pid
            }, "run \(stop) beats")
            let pid = try #require(state(directory)?.current?.pid)
            kill(pid, SIGTERM)
            #expect(await waitUntil(seconds: 10) { state(directory)?.lastRun?.pid == pid }, "run \(stop) stopped")
        }
        #expect(await waitUntil(seconds: 10) { (state(directory)?.runs ?? 0) >= 4 }, "started again after each stop")
        let recovery = try recoveryState(install)
        #expect(recovery.candidate?.release.version == "2.0.0" && recovery.candidate?.failureCount == 0)
        #expect(recovery.quarantine == nil && reexecs.all.isEmpty)
        #expect(try install.liveRelease() == "2.0.0")
        supervisor.requestStop()
        #expect(await run.value == 0)
    }

    /// A crash of the candidate's cluster service is still a failed start: the third restores the predecessor.
    @Test func aCrashOfTheCandidateServiceIsStillAFailedStart() async throws {
        let install = try CandidateInstall()
        defer { install.cleanUp() }
        let directory = try temporaryDirectory("cluster-update-crash")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reexecs = Recorder()
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: "kill -KILL $$",
            installed: install.binary, autoUpdate: false, clusterID: "pair-far-from-its-slot",
            recovery: ClusterCandidateRecovery(updater: install.updater), reexecs: reexecs) { _, _, _ in .upToDate })
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 20) { !reexecs.all.isEmpty }, "three crashes roll the candidate back")
        let recovery = try recoveryState(install)
        #expect(recovery.quarantine?.version == "2.0.0" && recovery.quarantine?.failureCount == 3)
        #expect(try install.liveRelease() == "1.0.0")
        supervisor.requestStop()
        #expect(await run.value == 0)
    }

    /// A service that never beats is stopped by its supervisor's liveness guard; it stops in order (exit 0), and that is
    /// still a failed start, as a start that never reaches its first heartbeat is on a single Mac.
    @Test func aServiceTheLivenessGuardStopsIsStillAFailedStart() async throws {
        let install = try CandidateInstall()
        defer { install.cleanUp() }
        let directory = try temporaryDirectory("cluster-update-guard")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reexecs = Recorder()
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory,
            script: Self.candidateService(beats: false), installed: install.binary, guardSeconds: 1, autoUpdate: false,
            clusterID: "pair-far-from-its-slot", recovery: ClusterCandidateRecovery(updater: install.updater),
            reexecs: reexecs) { _, _, _ in .upToDate })
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 40) { !reexecs.all.isEmpty }, "three stops by the guard roll the candidate back")
        #expect(state(directory)?.lastRun?.end?.hasPrefix("recycled by the liveness guard") == true,
                "\(String(describing: state(directory)?.lastRun))")
        let recovery = try recoveryState(install)
        #expect(recovery.quarantine?.version == "2.0.0" && recovery.quarantine?.failureCount == 3)
        supervisor.requestStop()
        #expect(await run.value == 0)
    }

    // MARK: - The start check before a restart

    /// The pair's cycle as the supervisor sees it: 2.0.0 is installed and its launch prepared, the progress says the
    /// service restarts, and the cycle asks for the restart.
    private func cycleInstalling(_ install: CandidateInstall, directory: URL)
        -> @Sendable (String?, @escaping @Sendable (String) -> Void, @escaping @Sendable (String) async throws -> Void) async
        -> AutoUpdateController.Outcome {
        { request, _, restart in
            do { try install.install() } catch { return .commitFailed("\(error)") }
            ClusterPairUpdate.writeProgress(.init(phase: .restarting, target: "2.0.0", running: "1.0.0", cycleStartedAt: 1,
                request: request, writtenAt: Date().timeIntervalSince1970), to: ClusterServiceAgent.updateProgressPath(serviceDirectory: directory))
            try? await restart("2.0.0")
            return .restarted(from: "1.0.0", to: "2.0.0", drained: true)
        }
    }

    /// A supervisor whose cluster service is the test install's `darkbloom`, and the `darkbloom update` request that
    /// runs the cycle installing 2.0.0 at once.
    private func superviseUpdate(_ install: CandidateInstall, directory: URL, reexecs: Recorder)
        async -> (ClusterMemberSupervisor, Task<Int32, Never>) {
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, service: install.binary,
            installed: install.binary, startCheckSeconds: 1, autoUpdate: false, clusterID: "pair-far-from-its-slot",
            recovery: ClusterCandidateRecovery(updater: install.updater), reexecs: reexecs,
            run: cycleInstalling(install, directory: directory)))
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 5) { state(directory)?.phase == .running })
        #expect(ClusterPairUpdate.writeRequest(.init(createdAt: Date().timeIntervalSince1970),
                                               to: ClusterServiceAgent.updateRequestPath(serviceDirectory: directory)))
        return (supervisor, run)
    }

    /// Before the supervisor restarts into the release its cycle installed, the release's `darkbloom` runs once with
    /// `--version`. One that exits non-zero, outlasts the bound or reports another version is never restarted into:
    /// the supervisor stays, restores the predecessor and quarantines the release at once, and starts the cluster
    /// service again from the restored binary.
    @Test(arguments: [StartAnswer.exitsNonZero, .hangs, .reportsAnotherVersion])
    func releaseThatCannotStartIsRolledBackInsteadOfRestartedInto(_ answer: StartAnswer) async throws {
        let install = try CandidateInstall(candidate: answer, installed: false)
        defer { install.cleanUp() }
        let directory = try temporaryDirectory("cluster-update-start-check")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reexecs = Recorder()
        let (supervisor, run) = await superviseUpdate(install, directory: directory, reexecs: reexecs)
        let store = UpdateRecoveryStore(installRoot: install.installRoot, verifyCodeSignatures: false)
        #expect(await waitUntil(seconds: 20) { (try? store.loadState())?.quarantine?.version == "2.0.0" },
                "rolled back at its first failed start check")
        #expect(await waitUntil(seconds: 10) {
            guard let current = state(directory)?.current, state(directory)?.runs == 2 else { return false }
            let health = ClusterSupervisionFiles.read(ClusterMemberHealth.self, from: ClusterServiceAgent.healthPath(serviceDirectory: directory))
            return health?.pid == current.pid && health?.version == "1.0.0"
        }, "this supervisor runs the cluster service again, from the restored binary")
        #expect(reexecs.all.isEmpty, "never restarted into a release that cannot start")
        #expect(try install.liveRelease() == "1.0.0")
        let recovery = try store.loadState()
        #expect(recovery.candidate == nil && recovery.current?.version == "1.0.0")
        #expect(recovery.quarantine?.failureCount == 1 && recovery.quarantine?.reason.contains("start check") == true)
        #expect(ClusterPairUpdate.readProgress(from: ClusterServiceAgent.updateProgressPath(serviceDirectory: directory))?.phase == .disabled,
                "the cycle is over: this Mac rests on its release")
        supervisor.requestStop()
        #expect(await run.value == 0)
    }

    /// A release whose `darkbloom` starts and reports its version is restarted into as before, and stays the candidate.
    @Test func releaseThatStartsIsRestartedInto() async throws {
        let install = try CandidateInstall(installed: false)
        defer { install.cleanUp() }
        let directory = try temporaryDirectory("cluster-update-start-check-passes")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reexecs = Recorder()
        let (supervisor, run) = await superviseUpdate(install, directory: directory, reexecs: reexecs)
        #expect(await waitUntil(seconds: 20) { !reexecs.all.isEmpty }, "restarted into the release")
        #expect(reexecs.all == ["\(install.binary) cluster service --supervise"])
        #expect(state(directory)?.lastRun?.end == "stopped to restart into v2.0.0")
        #expect(try install.liveRelease() == "2.0.0")
        let recovery = try UpdateRecoveryStore(installRoot: install.installRoot, verifyCodeSignatures: false).loadState()
        #expect(recovery.candidate?.release.version == "2.0.0" && recovery.quarantine == nil)
        supervisor.requestStop()
        #expect(await run.value == 0)
    }

    /// A candidate whose service keeps beating with the new version through the stabilization window is promoted.
    @Test func healthyCandidateIsPromoted() async throws {
        let install = try CandidateInstall()
        defer { install.cleanUp() }
        let directory = try temporaryDirectory("cluster-update-promote")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reexecs = Recorder()
        let beating = #"while :; do printf '{"pid":%d,"version":"2.0.0","phase":"serving","writtenAt":%s}' $$ "$(date +%s)" "#
            + #"> "$DARKBLOOM_CLUSTER_MEMBER_HEALTH_FILE"; sleep 0.2; done"#
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: beating,
            autoUpdate: false, clusterID: "pair-far-from-its-slot",
            recovery: ClusterCandidateRecovery(updater: install.updater, stabilizationSeconds: 1), reexecs: reexecs) { _, _, _ in .upToDate })
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 15) {
            (try? UpdateRecoveryStore(installRoot: install.installRoot, verifyCodeSignatures: false).loadState().current?.version) == "2.0.0"
        }, "promoted after the window")
        let recovery = try UpdateRecoveryStore(installRoot: install.installRoot, verifyCodeSignatures: false).loadState()
        #expect(recovery.candidate == nil && recovery.quarantine == nil)
        #expect(try install.liveRelease() == "2.0.0" && reexecs.all.isEmpty)
        supervisor.requestStop()
        #expect(await run.value == 0)
    }
}

/// How a test release's `darkbloom --version` answers.
enum StartAnswer: String, Sendable {
    case reportsItsVersion, exitsNonZero, hangs, reportsAnotherVersion

    func command(version: String) -> String {
        switch self {
        case .reportsItsVersion: return "echo \(version)"
        case .exitsNonZero: return "exit 1"
        case .hangs: return "exec sleep 30"
        case .reportsAnotherVersion: return "echo 1.9.9"
        }
    }
}

/// A temporary install with release 2.0.0 installed over 1.0.0 and not yet promoted (no network, unsigned fixtures).
/// Each release's `darkbloom` is a script: `--version` answers as the test says, and otherwise it beats as that
/// release's cluster service would.
private struct CandidateInstall {
    let root: URL
    let installRoot: URL
    let updater: SelfUpdater
    private let tarball: URL
    private let release: ReleaseInfo

    /// `installed`: 2.0.0 is installed already; otherwise `install()` installs it, as the test's cycle does.
    init(predecessor: StartAnswer = .reportsItsVersion, candidate: StartAnswer = .reportsItsVersion, installed: Bool = true) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("cluster-candidate-\(UUID().uuidString)", isDirectory: true)
        installRoot = root.appendingPathComponent("install", isDirectory: true)
        try Self.writeApp(version: "1.0.0", answer: predecessor, root: installRoot)
        let bin = installRoot.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try fm.createSymbolicLink(atPath: bin.appendingPathComponent(name).path,
                                      withDestinationPath: "../Darkbloom.app/Contents/MacOS/\(name)")
        }
        let source = root.appendingPathComponent("release", isDirectory: true)
        try Self.writeApp(version: "2.0.0", answer: candidate, root: source)
        let flat = source.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: flat, withIntermediateDirectories: true)
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try fm.copyItem(at: source.appendingPathComponent("Darkbloom.app/Contents/MacOS/\(name)"), to: flat.appendingPathComponent(name))
        }
        tarball = root.appendingPathComponent("release.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["czf", tarball.path, "-C", source.path, "."]
        try tar.run()
        tar.waitUntilExit()
        let digest = SHA256.hash(data: try Data(contentsOf: tarball)).map { String(format: "%02x", $0) }.joined()
        updater = SelfUpdater(coordinatorBaseURL: "http://127.0.0.1:9", installRoot: installRoot, verifyCodeSignatures: false,
                              currentVersion: "1.0.0")
        release = ReleaseInfo(version: "2.0.0", platform: "macos-arm64", url: "file:///unused", bundleHash: digest)
        if installed { try commit() }
    }

    /// The installed `darkbloom`, which the supervisor restarts into.
    var binary: String { installRoot.appendingPathComponent("Darkbloom.app/Contents/MacOS/darkbloom").path }

    /// Installs 2.0.0 and prepares its launch, as the pair's cycle does before it asks for the restart.
    func install() throws {
        try commit()
        try updater.prepareCandidateLaunch(operation: "test-cluster-restart", baseline: nil)
    }

    /// The release whose `darkbloom` is installed.
    func liveRelease() throws -> String? {
        try String(contentsOfFile: binary, encoding: .utf8).split(separator: "\n")
            .first { $0.hasPrefix("# release ") }.map { String($0.dropFirst("# release ".count)) }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    private func commit() throws {
        guard case .success = updater.installBundleForTesting(from: tarball, release: release, installDir: installRoot) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func writeApp(version: String, answer: StartAnswer, root: URL) throws {
        let contents = root.appendingPathComponent("Darkbloom.app/Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        let darkbloom = macOS.appendingPathComponent("darkbloom")
        try Data("""
            #!/bin/sh
            # release \(version)
            if [ "$1" = --version ]; then \(answer.command(version: version)); exit; fi
            while :; do printf '{"pid":%d,"version":"\(version)","phase":"serving","writtenAt":%s}' $$ "$(date +%s)" \
            > "$DARKBLOOM_CLUSTER_MEMBER_HEALTH_FILE"; sleep 0.2; done

            """.utf8).write(to: darkbloom)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: darkbloom.path)
        try Data("\(version)-enclave".utf8).write(to: macOS.appendingPathComponent("darkbloom-enclave"))
        try Data("\(version)-metallib".utf8).write(to: macOS.appendingPathComponent("mlx.metallib"))
    }
}
