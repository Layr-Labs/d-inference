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

    private func configuration(directory: URL, script: String, window: Int = 30) -> ClusterMemberSupervisor.Configuration {
        .init(executable: "/bin/sh", childArguments: ["-c", script],
              environment: ["PATH": "/usr/bin:/bin"],
              statePath: directory.appendingPathComponent("state.json"),
              healthPath: directory.appendingPathComponent("health.json"),
              setup: nil, coordinatorURL: "wss://example.invalid", autoUpdate: false,
              budgetLimits: .init(maxQuickFailures: 3, quickFailureWindowSeconds: Double(window),
                                  initialBackoffSeconds: 1, maxBackoffSeconds: 4),
              guardLimits: .production, recycleGraceSeconds: 5, reexecArguments: ["/bin/false"])
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
