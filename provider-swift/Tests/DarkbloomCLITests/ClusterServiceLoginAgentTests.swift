import ArgumentParser
import Foundation
import ProviderCore
import Testing
@testable import darkbloom

/// Review finding 12: the cluster service's login agent from the command line
/// (`cluster service --supervise/--install`, `cluster stop`) and the service's
/// side of the supervision. No launchd, no network, no model.
@Suite("Cluster service login agent CLI", .serialized)
struct ClusterServiceLoginAgentTests {
    @Test func serviceFlagsParse() throws {
        #expect(try Cluster.Service.parse(["--supervise"]).supervise)
        #expect(try Cluster.Service.parse(["--install", "--config", "/fixture/provider.toml"]).install)
        let plain = try Cluster.Service.parse(["--worker", "/fixture/worker"])
        #expect(!plain.supervise && !plain.install)
        #expect(plain.serviceOptions == ["--worker", "/fixture/worker"])
        for values in [["--supervise", "--install"], ["--config", "relative.toml"], ["--worker", "worker"]] {
            #expect(throws: (any Error).self) { _ = try Cluster.Service.parse(values) }
        }
    }

    @Test func clusterStopIsRegistered() throws {
        #expect(try Darkbloom.parseAsRoot(["cluster", "stop"]) is Cluster.Stop)
        #expect(try Darkbloom.parseAsRoot(["cluster", "service", "--supervise"]) is Cluster.Service)
        #expect(throws: (any Error).self) { _ = try Cluster.Stop.parse(["--config", "relative.toml"]) }
        // The solo provider's stop is unchanged.
        #expect(try Darkbloom.parseAsRoot(["stop"]) is darkbloom.Stop)
    }

    @Test func failedPairStopKeepsLoginServiceAndReturnsAnError() throws {
        for reason in ["local part still releasing", "peer did not acknowledge stop"] {
            var removals = 0
            // A runtime failure with the pair's reason (exit 1), never a usage error (exit 64 and a banner).
            let failure = #expect(throws: Cluster.Stop.Failure.self) {
                _ = try Cluster.Stop.finishStop(.failure(.init(reason))) { removals += 1; return ["fixture"] }
            }
            #expect(failure?.description == reason)
            #expect(removals == 0, "failed drain must not destroy the supervisor or claim successful removal")
        }
    }

    @Test func successfulOrAlreadyIdleStopRemovesTheServiceOnce() throws {
        let outcomes: [Result<[String], ClusterOnboardingFailure>?] = [.success(["pair drained"]), nil]
        for stopped in outcomes {
            var removals = 0
            let lines = try Cluster.Stop.finishStop(stopped) { removals += 1; return ["fixture"] }
            #expect(removals == 1)
            #expect(lines.last?.contains("will not start at login") == true)
            if stopped != nil { #expect(lines.first == "pair drained") }
        }
        #expect(throws: ValidationError.self) {
            _ = try Cluster.Stop.finishStop(.success([])) { throw ValidationError("fixture uninstall failed") }
        }
    }

    /// Review finding (a): a leader whose member is gone for good can still
    /// stop locally: no pair stop is attempted, the login agent goes, and the
    /// output says the other Mac was not asked.
    @Test func localOnlyStopSkipsThePairAndSaysSo() throws {
        #expect(try Cluster.Stop.parse(["--local-only"]).localOnly)
        #expect(try !Cluster.Stop.parse([]).localOnly)
        var removals = 0
        let lines = try Cluster.Stop.finishStop(nil, localOnly: true) { removals += 1; return ["fixture"] }
        #expect(removals == 1)
        #expect(lines.contains { $0.contains("will not start at login") })
        #expect(lines.last == "The other Mac was not asked to stop. If it comes back, run `darkbloom cluster stop` there too.")
        let ordinary = try Cluster.Stop.finishStop(nil) { ["fixture"] }
        #expect(!ordinary.contains { $0.contains("not asked to stop") })
    }

    @Test func theSupervisedServiceBeatsUntilItFinishes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-service-beat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let health = directory.appendingPathComponent("service-health.json")
        #expect(ClusterServiceSupervision(environment: [:]) == nil, "unsupervised: no heartbeat, no parent watch")
        let supervision = try #require(ClusterServiceSupervision(environment: [ClusterSupervisionFiles.healthPathEnvironmentKey: health.path]))
        let stop = DispatchSemaphore(value: 0)
        supervision.start(stop: stop, running: { true })
        let deadline = Date().addingTimeInterval(5)
        while ClusterSupervisionFiles.read(ClusterMemberHealth.self, from: health) == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let beat = try #require(ClusterSupervisionFiles.read(ClusterMemberHealth.self, from: health))
        #expect(beat.pid == getpid() && beat.phase == .serving)
        // The test runner's parent stays: the service is not told to stop.
        #expect(stop.wait(timeout: .now() + 0.3) == .timedOut)
        supervision.finish()
        #expect(ClusterSupervisionFiles.read(ClusterMemberHealth.self, from: health)?.phase == .stopping)
    }

    @Test func theServiceSupervisorRestartsAKilledServiceAfterTheBackoffAndNamesItself() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-service-sup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("service-supervisor.json")
        // A shell stands in for `darkbloom cluster service`, as in the member supervisor's tests.
        let supervisor = ClusterMemberSupervisor(configuration: .init(
            executable: "/bin/sh", childArguments: ["-c", "exec sleep 60"], environment: ["PATH": "/usr/bin:/bin"],
            statePath: state, healthPath: directory.appendingPathComponent("service-health.json"),
            setup: nil, coordinatorURL: "", autoUpdate: false,
            budgetLimits: .init(maxQuickFailures: 3, quickFailureWindowSeconds: 30, initialBackoffSeconds: 1, maxBackoffSeconds: 4),
            guardLimits: .production, recycleGraceSeconds: 5, reexecArguments: ["/bin/false"],
            logName: "cluster service supervisor", restartHint: "`darkbloom cluster` is run again"))
        func read() -> ClusterMemberSupervisorState? { ClusterSupervisionFiles.read(ClusterMemberSupervisorState.self, from: state) }
        func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if condition() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
            return condition()
        }
        let run = Task { await supervisor.run() }
        #expect(await waitUntil(10) { read()?.phase == .running })
        let first = try #require(read()?.current?.pid)
        kill(first, SIGKILL)
        #expect(await waitUntil(10) { read()?.phase == .backoff })
        #expect(read()?.lastRun?.signal == SIGKILL)
        #expect(await waitUntil(10) { read()?.phase == .running && read()?.current?.pid != first })
        #expect(read()?.runs == 2)
        supervisor.requestStop()
        #expect(await run.value == 0)
        #expect(read()?.phase == .stopped)
    }
}
