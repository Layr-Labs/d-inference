import ArgumentParser
import Foundation
import ProviderCore
import Testing
@testable import darkbloom

/// S18: the always-on member flags and the supervisor loop against real child
/// processes (a shell standing in for the member; no model, no network, no
/// launchd). Hardware proof of restart and re-formation is separate.
@Suite("Cluster member supervisor", .serialized)
struct ClusterMemberSupervisorTests {
    @Test func alwaysOnAndSuperviseParseOnlyWithClusterMember() throws {
        let service = try Start.parse(["--cluster-member", "--always-on", "--coordinator-url", "wss://example.invalid"])
        #expect(service.clusterMember && service.alwaysOn && !service.supervise)
        let supervised = try Start.parse(["--foreground", "--cluster-member", "--supervise", "--config", "/fixture/provider.toml"])
        #expect(supervised.supervise && !supervised.alwaysOn)
        for values in [["--always-on"], ["--supervise"], ["--cluster-member", "--always-on", "--supervise"],
                       ["--local", "--distributed", "--always-on"]] {
            #expect(throws: (any Error).self) { _ = try Start.parse(values) }
        }
    }

    private func configuration(directory: URL, script: String, window: Int = 30,
                               guardLimits: ClusterMemberLivenessGuard.Limits = .production) -> ClusterMemberSupervisor.Configuration {
        .init(executable: "/bin/sh", childArguments: ["-c", script],
              environment: ["PATH": "/usr/bin:/bin"],
              statePath: directory.appendingPathComponent("state.json"),
              healthPath: directory.appendingPathComponent("health.json"),
              setup: nil, coordinatorURL: "wss://example.invalid", autoUpdate: false,
              budgetLimits: .init(maxQuickFailures: 3, quickFailureWindowSeconds: Double(window),
                                  initialBackoffSeconds: 1, maxBackoffSeconds: 4),
              guardLimits: guardLimits, recycleGraceSeconds: 5, reexecArguments: ["/bin/false"],
              childPollSeconds: 0.05)
    }

    private func state(_ directory: URL) -> ClusterMemberSupervisorState? {
        ClusterSupervisionFiles.read(ClusterMemberSupervisorState.self, from: directory.appendingPathComponent("state.json"))
    }

    private func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    @Test func aCrashLoopStopsAtTheBudgetAndParksUntilStopped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("s18-loop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: "exit 3"))
        let run = Task { await supervisor.run() }
        let parked = await waitUntil(seconds: 20) { state(directory)?.phase == .exhausted }
        #expect(parked, "three quick failures (1 s then 2 s backoff) must exhaust the budget")
        let snapshot = state(directory)
        #expect(snapshot?.runs == 3)
        #expect(snapshot?.budget.quickFailures == 3)
        #expect(snapshot?.lastRun?.exitCode == 3)
        #expect(snapshot?.detail?.contains("3 quick failures") == true)
        // Parked: nothing is restarted while it waits for the operator.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(state(directory)?.runs == 3)
        supervisor.requestStop()
        #expect(await run.value == 0)
        #expect(state(directory)?.phase == .stopped)
    }

    @Test func aKilledMemberIsRestartedAfterTheBackoff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("s18-kill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // A member that runs until something kills it.
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: "exec sleep 60"))
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 10) { state(directory)?.phase == .running })
        let first = try #require(state(directory)?.current?.pid)
        kill(first, SIGTERM)  // not the supervisor's own stop: a crash to it
        #expect(await waitUntil(seconds: 10) { state(directory)?.phase == .backoff })
        #expect(state(directory)?.lastRun?.signal == SIGTERM)
        #expect(await waitUntil(seconds: 10) {
            guard let current = state(directory), current.phase == .running, let pid = current.current?.pid else { return false }
            return pid != first
        }, "restarted after the 1 s backoff")
        #expect(state(directory)?.runs == 2)
        // An operator stop forwards SIGTERM to the member and never restarts it.
        let second = try #require(state(directory)?.current?.pid)
        supervisor.requestStop()
        #expect(await run.value == 0)
        #expect(kill(second, 0) != 0, "the member is gone after an operator stop")
        #expect(state(directory)?.phase == .stopped)
        #expect(state(directory)?.runs == 2)
    }

    /// A member that stays alive but stops beating (a wedged loop) is
    /// recycled by the liveness guard and restarted through the budget.
    @Test func aMemberWhoseHeartbeatStopsIsRecycledAndRestarted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("s18-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var limits = ClusterMemberLivenessGuard.Limits()
        limits.intervalSeconds = 0.25
        limits.startGraceSeconds = 1
        limits.downSeconds = 2
        // One heartbeat, then silence while the process lives on.
        let script = #"printf '{"pid":%d,"version":"t","phase":"registered","writtenAt":%s}' $$ "$(date +%s)" "#
            + #"> "$DARKBLOOM_CLUSTER_MEMBER_HEALTH_FILE"; exec sleep 60"#
        let supervisor = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: script,
                                                                              guardLimits: limits))
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 10) { state(directory)?.phase == .running })
        let first = try #require(state(directory)?.current?.pid)
        // The guard needs at most about 2 s (1 s grace, 2 s down from a
        // whole-second heartbeat stamp, 0.25 s probes); the wider window only
        // absorbs a slow test host.
        let started = Date()
        #expect(await waitUntil(seconds: 60) {
            guard let current = state(directory), current.runs >= 2, current.phase == .running else { return false }
            return current.current?.pid != first
        }, "recycled after the heartbeat went stale, then restarted (state: \(String(describing: state(directory))))")
        print("s18-guard-test: restarted \(String(format: "%.1f", Date().timeIntervalSince(started))) s after the first run started")
        let recycled = try #require(state(directory)?.lastRun)
        #expect(recycled.pid == first)
        let end = recycled.end ?? ""
        #expect(end.contains("recycled by the liveness guard"), "\(end)")
        #expect(kill(first, 0) != 0, "the stalled member is gone")
        supervisor.requestStop()
        #expect(await run.value == 0)
    }

    /// Final review of #1846: a member refused because another Darkbloom build holds this Mac's GPU exits with its own
    /// code. The supervisor waits for that hold to end without spending its budget, then starts the member at once.
    @Test func aMemberRefusedForTheGPUWaitsForTheHoldAndStartsOnceItEnds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("s18-gpu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = directory.appendingPathComponent("held").path
        FileManager.default.createFile(atPath: held, contents: nil)
        var settings = configuration(directory: directory,
            script: "if [ -e '\(held)' ]; then exit \(ClusterMemberRunEnd.gpuHeldExitCode); fi; exec sleep 60")
        settings.gpuHold = { FileManager.default.fileExists(atPath: held) ? "Darkbloom Dev on this Mac holds this Mac's GPU." : nil }
        settings.gpuHoldPollSeconds = 0.1
        settings.sweepsOrphans = false
        let supervisor = ClusterMemberSupervisor(configuration: settings)
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(seconds: 10) { state(directory)?.lastRun?.exitCode == ClusterMemberRunEnd.gpuHeldExitCode })
        // Held: the member waits, nothing more runs and nothing counts (three quick failures would have parked it in
        // 3 s, its backoff being 1 s then 2 s).
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let waiting = try #require(state(directory))
        #expect(waiting.runs == 1, "the member was started again into the held GPU")
        #expect(waiting.phase == .backoff && waiting.detail?.contains("holds this Mac's GPU") == true,
                "\(waiting.phase): \(String(describing: waiting.detail))")
        #expect(waiting.budget.quickFailures == 0)
        // The hold ends: the member starts again at once.
        try FileManager.default.removeItem(atPath: held)
        #expect(await waitUntil(seconds: 5) { state(directory)?.phase == .running && state(directory)?.runs == 2 })
        supervisor.requestStop()
        #expect(await run.value == 0)
    }

    @Test func aSecondSupervisorForTheSameStateRefusesToStart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("s18-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: "exec sleep 60"))
        let run = Task { await first.run() }
        #expect(await waitUntil(seconds: 10) { state(directory)?.phase == .running })
        let second = ClusterMemberSupervisor(configuration: configuration(directory: directory, script: "exit 0"))
        #expect(await second.run() == 1)
        first.requestStop()
        #expect(await run.value == 0)
    }
}
