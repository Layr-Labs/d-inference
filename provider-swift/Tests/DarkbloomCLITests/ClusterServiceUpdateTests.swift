import CryptoKit
import Foundation
import ProviderCore
import Testing
@testable import darkbloom
@testable import ProviderCore

/// The cluster service supervisor's update (`darkbloom cluster`): its wiring to the single-Mac gate, the pair's update
/// slot and `darkbloom update`'s request, around a real supervisor with a shell standing in for the cluster service
/// (no model, network, launchd or re-exec: the re-exec is observed). The cycle itself is covered with real installs in
/// `ClusterPairUpdateTests`.
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

    private func configuration(directory: URL, script: String, autoUpdate: Bool, clusterID: String,
                               recovery: ClusterCandidateRecovery? = nil, reexecs: Recorder,
                               run: @escaping @Sendable (String?, @escaping @Sendable (String) -> Void,
                                                         @escaping @Sendable (String) async throws -> Void) async -> AutoUpdateController.Outcome)
        -> ClusterMemberSupervisor.Configuration {
        var limits = ClusterMemberLivenessGuard.Limits()
        limits.intervalSeconds = 0.2
        limits.startGraceSeconds = 600
        limits.downSeconds = 600
        return .init(executable: "/bin/sh", childArguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
            statePath: ClusterServiceAgent.supervisorStatePath(serviceDirectory: directory),
            healthPath: ClusterServiceAgent.healthPath(serviceDirectory: directory),
            setup: nil, coordinatorURL: "http://127.0.0.1:9", autoUpdate: autoUpdate,
            budgetLimits: .init(maxQuickFailures: 5, quickFailureWindowSeconds: 30, initialBackoffSeconds: 1, maxBackoffSeconds: 1),
            guardLimits: limits, recycleGraceSeconds: 5, reexecArguments: ["/installed/darkbloom", "cluster", "service", "--supervise"],
            logName: "cluster service supervisor", childPollSeconds: 0.05,
            pairUpdate: .init(clusterID: { clusterID }, run: run,
                requestPath: ClusterServiceAgent.updateRequestPath(serviceDirectory: directory),
                progressPath: ClusterServiceAgent.updateProgressPath(serviceDirectory: directory),
                recovery: recovery),
            reexec: { reexecs.add($0.joined(separator: " ")) }, sweepsOrphans: false)
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
    /// verified predecessor, quarantine the release and start again from the restored binary.
    @Test func failingCandidateIsRolledBackAndTheSupervisorRestartsFromThePredecessor() async throws {
        let install = try CandidateInstall()
        defer { install.cleanUp() }
        let directory = try temporaryDirectory("cluster-update-rollback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reexecs = Recorder()
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: "exit 1",
            autoUpdate: false, clusterID: "pair-far-from-its-slot", recovery: ClusterCandidateRecovery(updater: install.updater),
            reexecs: reexecs) { _, _, _ in .upToDate })
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 20) { !reexecs.all.isEmpty }, "three failed starts roll the candidate back")
        #expect(try install.liveBinary() == "1.0.0-darkbloom")
        let recovery = try UpdateRecoveryStore(installRoot: install.installRoot, verifyCodeSignatures: false).loadState()
        #expect(recovery.quarantine?.version == "2.0.0" && recovery.candidate == nil)
        #expect((state(directory)?.runs ?? 0) >= 3, "rolled back at the third failed start")
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
        #expect(try install.liveBinary() == "2.0.0-darkbloom" && reexecs.all.isEmpty)
        supervisor.requestStop()
        #expect(await run.value == 0)
    }
}

/// A temporary install with release 2.0.0 installed over 1.0.0 and not yet promoted (no network, unsigned fixtures).
private struct CandidateInstall {
    let root: URL
    let installRoot: URL
    let updater: SelfUpdater

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("cluster-candidate-\(UUID().uuidString)", isDirectory: true)
        installRoot = root.appendingPathComponent("install", isDirectory: true)
        try Self.writeApp(version: "1.0.0", root: installRoot)
        let bin = installRoot.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try fm.createSymbolicLink(atPath: bin.appendingPathComponent(name).path,
                                      withDestinationPath: "../Darkbloom.app/Contents/MacOS/\(name)")
        }
        let source = root.appendingPathComponent("release", isDirectory: true)
        try Self.writeApp(version: "2.0.0", root: source)
        let flat = source.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: flat, withIntermediateDirectories: true)
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try fm.copyItem(at: source.appendingPathComponent("Darkbloom.app/Contents/MacOS/\(name)"), to: flat.appendingPathComponent(name))
        }
        let tarball = root.appendingPathComponent("release.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["czf", tarball.path, "-C", source.path, "."]
        try tar.run()
        tar.waitUntilExit()
        let digest = SHA256.hash(data: try Data(contentsOf: tarball)).map { String(format: "%02x", $0) }.joined()
        updater = SelfUpdater(coordinatorBaseURL: "http://127.0.0.1:9", installRoot: installRoot, verifyCodeSignatures: false,
                              currentVersion: "1.0.0")
        let release = ReleaseInfo(version: "2.0.0", platform: "macos-arm64", url: "file:///unused", bundleHash: digest)
        guard case .success = updater.installBundleForTesting(from: tarball, release: release, installDir: installRoot) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func liveBinary() throws -> String {
        try String(contentsOf: installRoot.appendingPathComponent("Darkbloom.app/Contents/MacOS/darkbloom"), encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    private static func writeApp(version: String, root: URL) throws {
        let contents = root.appendingPathComponent("Darkbloom.app/Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("\(version)-darkbloom".utf8).write(to: macOS.appendingPathComponent("darkbloom"))
        try Data("\(version)-enclave".utf8).write(to: macOS.appendingPathComponent("darkbloom-enclave"))
        try Data("\(version)-metallib".utf8).write(to: macOS.appendingPathComponent("mlx.metallib"))
    }
}
