import Foundation
import Testing
@testable import DarkbloomApp
import ProviderCoreFoundation


private func testRunningState(pid: Int32 = 4001) -> DaemonState {
    let now = Date().timeIntervalSince1970
    return DaemonState(
        pid: pid, version: "0.8.5", writtenAt: now, startedAt: now - 60,
        currentModel: "gpt-oss-20b", warmModels: ["gpt-oss-20b"])
}

@Suite("Daemon runtime service reads the state file and drives the CLI")
struct DaemonRuntimeServiceTests {
    // MARK: Stubs

    /// Records invocations; on success simulates the daemon reacting by
    /// invoking a side effect (tests write the state file there).
    actor StubCLI: ProviderCLIRunning {
        private(set) var runs: [[String]] = []
        nonisolated(unsafe) var error: (any Error)?
        nonisolated(unsafe) var onRun: (@Sendable ([String]) -> Void)?

        func run(arguments: [String], timeout: Duration) async throws -> ProviderCLIResult {
            runs.append(arguments)
            if let error { throw error }
            onRun?(arguments)
            return ProviderCLIResult(exitStatus: 0, stderrTail: "")
        }
    }

    private func stateFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dstate-test-\(UUID().uuidString).json")
    }

    private func writeState(_ state: DaemonState, to url: URL) {
        DaemonStateFile.write(state, to: url)
    }


    private func makeService(
        stateFileURL: URL,
        cli: StubCLI,
        selectionInstalled: Bool = true,
        serviceLoaded: Bool = true,
        processAlive: @escaping @Sendable (Int32) -> Bool = { _ in true },
        processIdentityReader: @escaping @Sendable (Int32) -> ProcessIdentity? = { _ in nil }
    ) -> DaemonRuntimeService {
        DaemonRuntimeService(
            stateFileURL: stateFileURL,
            cli: cli,
            pollInterval: .milliseconds(20),
            cliTimeout: .seconds(5),
            settleTimeout: .seconds(5),
            providerName: "Test Mac",
            localEndpointReader: { nil },
            processAlive: processAlive,
            processIdentityReader: processIdentityReader,
            selectionInstalled: { selectionInstalled },
            serviceLoaded: { serviceLoaded }
        )
    }

    /// Drains the stream until `predicate` matches, bailing out (nil) on a
    /// timeout so a broken publish can't hang the suite.
    private func nextUpdate(
        from stream: AsyncStream<ProviderSnapshot>,
        matching predicate: @escaping @Sendable (ProviderSnapshot) -> Bool
    ) async -> ProviderSnapshot? {
        await withTaskGroup(of: ProviderSnapshot?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                while let next = await iterator.next() {
                    if predicate(next) { return next }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Polling

    @Test("updates() polls the file and publishes only real changes")
    func updatesPublishOnChange() async {
        let url = stateFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let service = makeService(stateFileURL: url, cli: StubCLI())

        let stream = await service.updates()
        let initial = await nextUpdate(from: stream) { _ in true }
        #expect(initial?.runState == .paused)

        writeState(testRunningState(), to: url)
        let online = await nextUpdate(from: stream) { $0.runState == .online }
        #expect(online?.pid == 4001)
        #expect(online?.warmModels.map(\.id) == ["gpt-oss-20b"])

        // Same content written again — no publish (stream stays suspended).
        writeState(testRunningState(), to: url)
    }

    @Test("A file that goes silent flips to stale while the process is alive")
    func staleFlipPublishes() async {
        let url = stateFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var state = testRunningState()
        state.writtenAt = Date().timeIntervalSince1970 - 120 // 120 s old > 90 s bar
        writeState(state, to: url)

        let service = makeService(stateFileURL: url, cli: StubCLI())
        let stream = await service.updates()
        let stale = await nextUpdate(from: stream) { $0.runState == .stale }
        #expect(stale != nil)
        #expect(stale?.lastProblem?.id == "provider-state-stale")
    }

    @Test("A reused PID cannot make a dead provider look live")
    func processIdentityMismatchMapsPaused() {
        let url = stateFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var state = testRunningState()
        state.processIdentity = ProcessIdentity(pid: state.pid, startTimeMicros: 11)
        writeState(state, to: url)

        let service = makeService(
            stateFileURL: url,
            cli: StubCLI(),
            serviceLoaded: false,
            processAlive: { _ in true },
            processIdentityReader: {
                ProcessIdentity(pid: $0, startTimeMicros: 22)
            }
        )

        #expect(service.initialSnapshot.runState == .paused)
        #expect(service.initialSnapshot.pid == nil)
    }

    @Test("A PID-reused record keeps only loaded scheduled-off posture")
    func processIdentityMismatchWithLoadedScheduleMapsOff() {
        let url = stateFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var state = testRunningState()
        state.processIdentity = ProcessIdentity(pid: state.pid, startTimeMicros: 11)
        state.schedule = .init(
            mode: "scheduled-off",
            summary: "Mon-Fri 09:00-17:00",
            nextChangeAtEpoch: Date().timeIntervalSince1970 + 3_600
        )
        writeState(state, to: url)

        let service = makeService(
            stateFileURL: url,
            cli: StubCLI(),
            serviceLoaded: true,
            processAlive: { _ in true },
            processIdentityReader: {
                ProcessIdentity(pid: $0, startTimeMicros: 22)
            }
        )

        #expect(service.initialSnapshot.runState == .scheduledOff)
        #expect(service.initialSnapshot.pid == nil)
    }

    @Test("A matching kernel process identity preserves daemon liveness")
    func matchingProcessIdentityMapsOnline() {
        let url = stateFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let identity = ProcessIdentity(pid: 4001, startTimeMicros: 11)
        var state = testRunningState(pid: identity.pid)
        state.processIdentity = identity
        writeState(state, to: url)

        let service = makeService(
            stateFileURL: url,
            cli: StubCLI(),
            processAlive: { _ in false },
            processIdentityReader: { _ in identity }
        )

        #expect(service.initialSnapshot.runState == .online)
        #expect(service.initialSnapshot.pid == identity.pid)
    }

    // MARK: Lifecycle

    @Test("Start with an installed selection runs `restart` and converges online")
    func startUsesRestartWhenInstalled() async throws {
        let url = stateFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cli = StubCLI()
        // The "daemon" boots when the CLI runs: the state file appears.
        cli.onRun = { _ in DaemonStateFile.write(testRunningState(), to: url) }
        let service = makeService(
            stateFileURL: url,
            cli: cli,
            selectionInstalled: true,
            serviceLoaded: false
        )

        let stream = await service.updates()
        async let starting = nextUpdate(from: stream) { $0.runState == .starting }
        let result = try await service.perform(.start)

        let runs = await cli.runs
        #expect(runs == [["restart"]])
        #expect(result.runState == .online)
        let observedTransition = await starting
        #expect(observedTransition?.runState == .starting)
    }

    @Test("Start with no selection installed runs `start --all` (never the picker)")
    func startUsesAllWhenNothingInstalled() async throws {
        let url = stateFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cli = StubCLI()
        cli.onRun = { _ in DaemonStateFile.write(testRunningState(), to: url) }
        let service = makeService(
            stateFileURL: url,
            cli: cli,
            selectionInstalled: false
        )

        let result = try await service.perform(.start)
        let runs = await cli.runs
        #expect(runs == [["start", "--all"]])
        #expect(result.runState == .online)
    }

    @Test("Stop runs `stop`, publishes the transition, and converges paused")
    func stopConvergesPaused() async throws {
        let url = stateFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        writeState(testRunningState(), to: url)
        let cli = StubCLI()
        cli.onRun = { _ in try? FileManager.default.removeItem(at: url) } // daemon exits: file cleaned up by bootout in production; deletion mimics its absence
        let service = makeService(stateFileURL: url, cli: cli)

        let stream = await service.updates()
        _ = await nextUpdate(from: stream) { $0.runState == .online }
        async let stopping = nextUpdate(from: stream) { $0.runState == .stopping }
        let result = try await service.perform(.stop)

        let runs = await cli.runs
        #expect(runs == [["stop"]])
        #expect(result.runState == .paused)
        // The last-known trust/identity fields persist; live fields clear.
        #expect(result.pid == nil)
        #expect(result.uptime == nil)
        let observedTransition = await stopping
        #expect(observedTransition?.runState == .stopping)
    }

    @Test("A CLI failure surfaces as an error and re-publishes the truth")
    func cliFailureRestoresTruth() async throws {
        let url = stateFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        writeState(testRunningState(), to: url)
        let cli = StubCLI()
        cli.error = ProviderCLIError.exited(1, message: "launchctl: Boot-out failed")
        let service = makeService(stateFileURL: url, cli: cli)

        _ = await service.updates()
        do {
            _ = try await service.perform(.stop)
            Issue.record("stop should have thrown")
        } catch let error as ProviderRuntimeServiceError {
            #expect(error == .unavailable("launchctl: Boot-out failed"))
        }
        // The transient `.stopping` is replaced by the file's actual state.
        let snapshot = try await service.currentSnapshot()
        #expect(snapshot.runState == .online)
    }

    @Test("Refresh re-reads the file without touching the CLI")
    func refreshSkipsCLI() async throws {
        let url = stateFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        writeState(testRunningState(), to: url)
        let cli = StubCLI()
        let service = makeService(stateFileURL: url, cli: cli)

        _ = await service.updates()
        var snapshot = try await service.currentSnapshot()
        #expect(snapshot.runState == .online)

        // Daemon dies: file deleted by external actor (e.g. user ran
        // `darkbloom stop` in a terminal).
        try? FileManager.default.removeItem(at: url)
        snapshot = try await service.perform(.refresh)
        #expect(snapshot.runState == .paused)
        let runs = await cli.runs
        #expect(runs.isEmpty)
    }

    @Test("Unavailable actions throw per-state, matching the store's guards")
    func actionAvailability() async throws {
        let url = stateFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let service = makeService(stateFileURL: url, cli: StubCLI())

        // Already paused: start is legal, stop is not.
        do {
            _ = try await service.perform(.stop)
            Issue.record("stop while paused should throw")
        } catch let error as ProviderRuntimeServiceError {
            guard case .actionUnavailable(.stop, state: .paused) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
    }

    @Test("initialSnapshot reflects the file written before launch")
    func initialSnapshotFromDisk() async {
        let url = stateFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        writeState(testRunningState(), to: url)
        let service = makeService(stateFileURL: url, cli: StubCLI())
        #expect(service.initialSnapshot.runState == .online)
        #expect(service.initialSnapshot.providerName == "Test Mac")
    }
}
