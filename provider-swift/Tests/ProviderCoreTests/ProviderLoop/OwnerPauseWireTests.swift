import Foundation
import Testing

@testable import ProviderCore

/// The owner pause on the wire: a real `CoordinatorClient` on the loop's state,
/// connected to the loopback mock coordinator, with no serve loop (nothing here
/// opens the GPU). The baseline heartbeat is an hour away, so every heartbeat
/// the mock sees is an event heartbeat.
@Suite("Owner pause on the wire", .serialized)
struct OwnerPauseWireTests {
    /// A loop with me first on (one idle minute, a test clock) and a client on
    /// its state, registered with a fresh mock coordinator.
    struct Wire {
        let mock: MockCoordinator
        let sandbox: ModelLoadingSandbox
        let loop: ProviderLoop
        let clock: MeFirstTestClock
        let client: CoordinatorClient

        static func connect() async throws -> Wire {
            let mock = MockCoordinator()
            let url = try await mock.start().mockProviderWebSocketURL()
            let sandbox = try ModelLoadingSandbox()
            let loop = try await ModelLoadingFixtures.makeLoop(sandbox: sandbox)
            let clock = MeFirstTestClock()
            await loop.useMeFirstClockForTesting(clock)
            await loop.skipCapacityRebuildForTesting()
            await loop.enableMeFirst(idle: .seconds(60))
            let client = CoordinatorClient(
                config: .init(url: url, hardware: ModelLoadingFixtures.defaultHardware, models: [],
                              backendName: "mlx-swift", heartbeatInterval: 3_600),
                stats: AtomicProviderStats(), state: await loop.state, liveAPNsToken: { nil })
            _ = await client.start()
            let wire = Wire(mock: mock, sandbox: sandbox, loop: loop, clock: clock, client: client)
            guard let first = try await mock.awaitFirstRegister(timeout: .seconds(10)) else {
                wire.close()
                throw CancellationError()
            }
            #expect(first.busy == nil)
            await loop.setCoordinatorClientForTesting(client)
            return wire
        }

        func close() {
            sandbox.remove()
            Task {
                await client.shutdown()
                await mock.shutdown()
            }
        }
    }

    /// The owner's idle time passes while the connection is down (a sleeping
    /// Mac, for one, whose timer runs late): the fresh registration ends the
    /// pause, and the connection's one event heartbeat already says so.
    @Test func aRegistrationAfterTheIdleTimeEndsThePauseWithOneRoutableHeartbeat() async throws {
        let w = try await Wire.connect()
        defer { w.close() }
        await w.loop.noteLocalUse(.start)
        let since = w.clock.now
        let paused = try #require(try await w.mock.waitForSnapshot { $0.heartbeats.count == 1 })
        #expect(paused.heartbeats[0].status == .draining)
        await w.loop.noteLocalUse(.end)

        await w.mock.dropActiveWebSocket(closeCode: 1012, reason: "restart")
        let again = try #require(try await w.mock.waitForSnapshot(timeout: .seconds(15)) { $0.registers.count == 2 })
        #expect(again.registers[1].busy == ProviderBusy(reason: .owner, sinceMs: since))
        // The serve loop's `.connected` step runs after the idle time has passed.
        await w.loop.finishPlannedReconnectForTesting(advancing: w.clock, by: 60_000)
        #expect(await !w.loop.ownerPausesPublic)
        let resumed = try #require(try await w.mock.waitForSnapshot { $0.heartbeats.count >= 2 })
        #expect(resumed.heartbeats[1].status == .idle && resumed.heartbeats[1].busy == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(w.mock.snapshot().heartbeats.count == 2)
        #expect(await !w.loop.meFirstResumeTimerArmedForTesting)
        #expect(await w.loop.currentDaemonState().meFirst?.paused == false)
    }

    @Test func heartbeatsGoOutOnTransitionsOnlyAndAFreshRegistrationKeepsThePause() async throws {
        let w = try await Wire.connect()
        defer { w.close() }
        let (mock, loop, clock) = (w.mock, w.loop, w.clock)

        // The owner's first request: one event heartbeat, at once.
        await loop.noteLocalUse(.start)
        let since = clock.now
        let paused = try #require(try await mock.waitForSnapshot { $0.heartbeats.count == 1 })
        #expect(paused.heartbeats[0].status == .draining)
        #expect(paused.heartbeats[0].busy == ProviderBusy(reason: .owner, sinceMs: since))
        // Fifty more requests during the pause send nothing.
        for _ in 0..<50 {
            await loop.noteLocalUse(.end)
            await loop.noteLocalUse(.start)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(mock.snapshot().heartbeats.count == 1)

        // A fresh registration carries the owner's busy fields, and the
        // connection's first heartbeat repeats the draining status.
        await mock.dropActiveWebSocket(closeCode: 1012, reason: "restart")
        let again = try #require(try await mock.waitForSnapshot(timeout: .seconds(15)) { $0.registers.count == 2 })
        #expect(again.registers[1].busy == ProviderBusy(reason: .owner, sinceMs: since))
        await loop.finishPlannedReconnect()  // the serve loop's `.connected` step
        let reasserted = try #require(try await mock.waitForSnapshot { $0.heartbeats.count == 2 })
        #expect(reasserted.heartbeats[1].status == .draining)
        #expect(reasserted.heartbeats[1].busy == ProviderBusy(reason: .owner, sinceMs: since))

        // The owner goes idle: one routable heartbeat without busy fields, and nothing after it.
        await loop.noteLocalUse(.end)
        #expect(await loop.resumeIfOwnerIdleForTesting(advancing: clock, by: 60_000))
        let resumed = try #require(try await mock.waitForSnapshot { $0.heartbeats.count == 3 })
        #expect(resumed.heartbeats[2].status == .idle && resumed.heartbeats[2].busy == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(mock.snapshot().heartbeats.count == 3)
        #expect(await !loop.meFirstResumeTimerArmedForTesting)
    }
}
