import Foundation
import Testing
@testable import ProviderCore

/// The client asks `registrationPrivacyRefresh` before each connection attempt: a shutdown while it is pending opens
/// no socket, a refusal stops the attempts for good, and its answer is what the connection registers with.
@Suite("Coordinator client: privacy capabilities asked before connecting", .serialized)
struct RegistrationPrivacyRefreshTests {
    /// A refresh that reports when it is asked, then waits for the test to answer it.
    private final class ParkedRefresh: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0
        private var waiting: CheckedContinuation<PrivacyCapabilities?, Never>?
        private var answer: PrivacyCapabilities??

        var calls: Int { lock.withLock { asked } }

        func refresh() async -> PrivacyCapabilities? {
            await withCheckedContinuation { continuation in
                let ready: PrivacyCapabilities?? = lock.withLock {
                    asked += 1
                    if let answer { return answer }
                    waiting = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }

        func release(_ capabilities: PrivacyCapabilities?) {
            let parked: CheckedContinuation<PrivacyCapabilities?, Never>? = lock.withLock {
                answer = .some(capabilities)
                defer { waiting = nil }
                return waiting
            }
            parked?.resume(returning: capabilities)
        }
    }

    private static func capabilities(secureBoot: String) -> PrivacyCapabilities {
        PrivacyCapabilities(textBackendInprocess: true, textProxyDisabled: true, sipEnabled: true,
                            antiDebugEnabled: true, coreDumpsDisabled: true, envScrubbed: true,
                            sipConfiguration: 0, secureBoot: secureBoot)
    }

    private static func client(url: String) -> CoordinatorClient {
        let config = CoordinatorClientConfig(
            url: url,
            hardware: HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                                   memoryGb: 64, memoryAvailableGb: 64,
                                   cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                                   gpuCores: 40, memoryBandwidthGbs: 546),
            models: [],
            backendName: "mlx-swift",
            heartbeatInterval: 60,
            publicKey: NodeKeyPair.generate().publicKeyBase64,
            privacyCapabilities: capabilities(secureBoot: "unknown"))
        return CoordinatorClient(config: config, stats: AtomicProviderStats(), state: ProviderState())
    }

    private static func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    @Test func aShutdownWhileTheRefreshIsPendingOpensNoSocket() async throws {
        let mock = MockCoordinator()
        let client = Self.client(url: try await mock.start().mockProviderWebSocketURL())
        let parked = ParkedRefresh()
        await client.setRegistrationPrivacyRefresh { await parked.refresh() }
        let (events, _) = await client.start()
        let drained = Task { for await _ in events {} }

        #expect(try await Self.eventually { parked.calls == 1 }, "the first attempt asks before connecting")
        await client.shutdown()
        parked.release(Self.capabilities(secureBoot: "full"))
        try await Task.sleep(for: .seconds(2))

        let captured = mock.snapshot()
        #expect(captured.webSocketsOpened == 0, "no socket after the shutdown")
        #expect(captured.registerFrames.isEmpty, "no registration after the shutdown")
        #expect(parked.calls == 1)
        drained.cancel()
        await mock.shutdown()
    }

    @Test func eachConnectionRegistersWithTheRefreshedCapabilities() async throws {
        let mock = MockCoordinator()
        let client = Self.client(url: try await mock.start().mockProviderWebSocketURL())
        let parked = ParkedRefresh()
        parked.release(Self.capabilities(secureBoot: "full"))
        await client.setRegistrationPrivacyRefresh { await parked.refresh() }
        let (events, _) = await client.start()
        let drained = Task { for await _ in events {} }

        let register = try #require(try await mock.awaitFirstRegister(timeout: .seconds(10)))
        #expect(register.privacyCapabilities?.secureBoot == "full", "the refreshed answer, not the config's unknown")
        #expect(parked.calls == 1)
        await mock.dropActiveWebSocket()
        #expect(try await mock.waitForSnapshot(timeout: .seconds(10)) { $0.registers.count >= 2 } != nil)
        #expect(parked.calls == 2, "a reconnect asks again")
        await client.shutdown()
        drained.cancel()
        await mock.shutdown()
    }

    /// Counts the times it is asked.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func note() { lock.withLock { count += 1 } }
        var calls: Int { lock.withLock { count } }
    }

    @Test func aRefusalStopsTheAttemptsUntilShutdown() async throws {
        let mock = MockCoordinator()
        let client = Self.client(url: try await mock.start().mockProviderWebSocketURL())
        let asked = Asked()
        await client.setRegistrationPrivacyRefresh {
            asked.note()
            throw RegistrationRefused(reason: "boot settings keep Darkbloom serving off (secure_boot)")
        }
        let (events, _) = await client.start()
        let ended = Task { () -> Bool in
            for await _ in events {}
            return true
        }

        #expect(try await Self.eventually { asked.calls == 1 })
        try await Task.sleep(for: .seconds(3))
        #expect(asked.calls == 1, "no further attempt after a refusal")
        #expect(mock.snapshot().webSocketsOpened == 0)
        #expect(mock.snapshot().registerFrames.isEmpty)
        let loop = try #require(await client.runLoopTask)
        #expect(await !Self.finishes(loop, within: .milliseconds(500)), "the loop waits for shutdown")

        await client.shutdown()
        #expect(await Self.finishes(loop, within: .seconds(5)), "the loop ends at shutdown")
        #expect(await ended.value)
        await mock.shutdown()
    }

    @Test func aSecondStartGetsAnEndedStreamAndNoSecondLoop() async throws {
        let mock = MockCoordinator()
        let client = Self.client(url: try await mock.start().mockProviderWebSocketURL())
        let asked = Asked()
        await client.setRegistrationPrivacyRefresh {
            asked.note()
            return nil
        }
        let (events, _) = await client.start()
        let drained = Task { for await _ in events {} }
        let loop = try #require(await client.runLoopTask)
        let (second, _) = await client.start()
        var iterator = second.makeAsyncIterator()
        let firstEvent = await iterator.next()
        #expect(firstEvent == nil, "the second stream has already ended")
        #expect(await client.runLoopTask == loop, "the same loop")
        #expect(try await mock.awaitFirstRegister(timeout: .seconds(10)) != nil)
        #expect(asked.calls == 1, "one loop asked once")
        await client.shutdown()
        drained.cancel()
        await mock.shutdown()
    }

    private static func finishes(_ task: Task<Void, Never>, within timeout: Duration) async -> Bool {
        let done = Asked()
        Task {
            await task.value
            done.note()
        }
        let deadline = ContinuousClock.now + timeout
        while done.calls == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return done.calls > 0
    }
}
