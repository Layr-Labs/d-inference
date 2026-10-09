import Foundation
import Testing
@testable import ProviderCore

/// Runs a control-only member `ProviderLoop.run()` against a `MockCoordinator`
/// on a loopback port. No model, GPU work or native owner; the attestation is
/// signed by a software key, so registration takes the raw-attestation path.
private struct ClusterMemberServeFixture: Sendable {
    static let modelId = "fixture/cluster-member-qwen"

    let mock: MockCoordinator
    let loop: ProviderLoop
    let directory: URL

    static func make(stopOnDisconnect: Bool) async throws -> ClusterMemberServeFixture {
        let mock = MockCoordinator()
        let coordinatorURL = try await mock.start().mockProviderWebSocketURL()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cluster-member-serve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hardware = HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max",
            chipFamily: .m4, chipTier: .max, memoryGb: 64, memoryAvailableGb: 64,
            cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let loop = try ProviderLoop(
            config: .init(
                coordinatorURL: coordinatorURL, hardware: hardware,
                models: [.init(id: modelId, modelType: "qwen3_5", sizeBytes: 1, estimatedMemoryGb: 1)],
                config: .init(
                    provider: .init(name: "cluster-member-serve", autoUpdate: false),
                    backend: .init(),
                    coordinator: .init(url: coordinatorURL, heartbeatIntervalSecs: 60)),
                executionRole: .clusterMember, clusterMemberStopsOnDisconnect: stopOnDisconnect),
            attestationSigner: ServeLoopTestSigner())
        await loop.setServeUsesHostServicesForTesting(false)
        await loop.setDaemonStateFileForTesting(directory.appendingPathComponent("state.json"))
        return ClusterMemberServeFixture(mock: mock, loop: loop, directory: directory)
    }

    func start() -> Task<Void, Error> {
        let loop = self.loop
        return Task { try await loop.run() }
    }

    func awaitRegistration() async throws -> ProviderMessage.Register {
        try #require(try await mock.awaitFirstRegister(timeout: .seconds(15)))
    }

    /// Acknowledges `registration` and waits until the loop holds an accepted connection.
    func accept(_ registration: ProviderMessage.Register) async throws {
        try await mock.pushClusterMemberAcceptance(nonce: try #require(registration.memberRegistrationNonce))
        try await loop.waitForClusterMemberRegistration(until: .now.advanced(by: .seconds(5)))
    }

    func cleanUp(_ task: Task<Void, Error>) async {
        task.cancel()
        _ = await ServeLoopFixture.finishes(task, within: .seconds(30))
        await mock.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Runs `body` against a started member loop, then cancels the loop and
/// removes everything the fixture made, whether or not `body` threw.
private func withMemberServeLoop(
    stopOnDisconnect: Bool,
    _ body: (ClusterMemberServeFixture, Task<Void, Error>) async throws -> Void
) async throws {
    let fixture = try await ClusterMemberServeFixture.make(stopOnDisconnect: stopOnDisconnect)
    let task = fixture.start()
    do { try await body(fixture, task) } catch {
        await fixture.cleanUp(task)
        throw error
    }
    await fixture.cleanUp(task)
}

@Suite("Cluster member serve loop", .timeLimit(.minutes(2)))
struct ClusterMemberServeLoopTests {
    @Test func attestedMemberLoopRegistersItsRoleAndConnectsOnlyOnAcceptance() async throws {
        try await withMemberServeLoop(stopOnDisconnect: false) { fixture, _ in
            let registration = try await fixture.awaitRegistration()
            #expect(registration.attestation != nil)
            #expect(registration.executionRole == .clusterMember)
            #expect(registration.models.isEmpty)
            #expect(registration.clusterModels?.map(\.id) == [ClusterMemberServeFixture.modelId])
            #expect(registration.memberRegistrationNonce?.count == 64)

            // Sending the registration is not acceptance: the wait must expire.
            await #expect(throws: ClusterMemberControlError.negotiationFailed) {
                try await fixture.loop.waitForClusterMemberRegistration(
                    until: .now.advanced(by: .milliseconds(300)))
            }
            #expect(await fixture.loop.memberConnectionID == nil)

            try await fixture.accept(registration)
            #expect(await fixture.loop.memberConnectionID != nil)
        }
    }

    @Test func acceptedMemberRunsNoSoloMonitorAndKeepsItsEmptyCapacity() async throws {
        try await withMemberServeLoop(stopOnDisconnect: false) { fixture, _ in
            try await fixture.accept(try await fixture.awaitRegistration())
            #expect(await fixture.loop.runsNoSoloMonitor())
            let capacity = await fixture.loop.state.backendCapacity
            #expect(capacity?.slots.isEmpty == true && capacity?.freeForLoadGb == 0)
        }
    }

    @Test func acceptedLeaderLoopEndsWhenItsControlConnectionDrops() async throws {
        try await withMemberServeLoop(stopOnDisconnect: true) { fixture, task in
            try await fixture.accept(try await fixture.awaitRegistration())
            await fixture.mock.dropActiveWebSocket()
            // Without the stop, the client would reconnect after its one-second
            // backoff and run a second ten-second negotiation.
            let ended = await ServeLoopFixture.finishes(task, within: .seconds(5))
            #expect(ended, "the leader kept running after its accepted control connection dropped")
            // A leader stop is a normal return, not a negotiation failure.
            if ended { try await task.value }
            #expect(await fixture.loop.memberControlRequiresStop)
            #expect(await fixture.loop.memberConnectionID == nil)
            #expect(fixture.mock.snapshot().registers.count == 1)
        }
    }
}

private extension ProviderLoop {
    func runsNoSoloMonitor() -> Bool {
        idleMonitorTask == nil && capacityRefreshTask == nil && mtpUpgradeMonitorTask == nil
            && modelRevisionMonitorTask == nil && autoUpdateTask == nil && prefetchCoordinator == nil
    }
}
