import CryptoKit
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

    /// `pairing` installs a member control whose chip and model the loop must
    /// then report, exactly as a saved setup with a pair approval does.
    /// `absentOnPort`: the coordinator is not up yet (a restart while it is
    /// away); the test brings the mock up on that port when it returns.
    static func make(stopOnDisconnect: Bool, heartbeatSeconds: UInt64 = 60,
                     pairing: NativePairMemberInstallation? = nil,
                     absentOnPort: Int? = nil) async throws -> ClusterMemberServeFixture {
        let mock = MockCoordinator()
        let coordinatorURL: String
        if let absentOnPort {
            coordinatorURL = "ws://127.0.0.1:\(absentOnPort)/ws/provider"
        } else {
            coordinatorURL = try await mock.start().mockProviderWebSocketURL()
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cluster-member-serve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hardware = HardwareInfo(
            machineModel: "Mac16,5", chipName: pairing == nil ? "Apple M4 Max" : "Apple M4",
            chipFamily: .m4, chipTier: .max, memoryGb: 64, memoryAvailableGb: 64,
            cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let loop = try ProviderLoop(
            config: .init(
                coordinatorURL: coordinatorURL, hardware: hardware,
                models: [.init(id: pairing == nil ? modelId : "fixture-model", modelType: "qwen3_5",
                               sizeBytes: 1, estimatedMemoryGb: 1)],
                config: .init(
                    provider: .init(name: "cluster-member-serve", autoUpdate: false),
                    backend: .init(),
                    coordinator: .init(url: coordinatorURL, heartbeatIntervalSecs: heartbeatSeconds)),
                executionRole: .clusterMember, clusterMemberStopsOnDisconnect: stopOnDisconnect),
            attestationSigner: ServeLoopTestSigner())
        await loop.setServeUsesHostServicesForTesting(false)
        await loop.setDaemonStateFileForTesting(directory.appendingPathComponent("state.json"))
        if let pairing { try await loop.installNativePairMember(pairing) }
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

            // Sending the registration is not acceptance: nothing connects, and
            // a wait whose deadline passes while this connection's negotiation
            // window is open runs to that window, never past it.
            let waiting = Task {
                try await fixture.loop.waitForClusterMemberRegistration(until: .now.advanced(by: .milliseconds(300)))
            }
            try await Task.sleep(for: .milliseconds(600))
            #expect(await fixture.loop.memberConnectionID == nil)

            try await fixture.mock.pushClusterMemberAcceptance(nonce: try #require(registration.memberRegistrationNonce))
            try await waiting.value
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

    /// Until a coordinator-formed pair can serve, every member (leader and
    /// follower alike) keeps reporting that it is not taking work, holds no
    /// slot, and answers a coordinator request with a retryable refusal.
    @Test func acceptedMemberReportsDrainingWithNoSlotsAndRefusesCoordinatorInference() async throws {
        let fixture = try await ClusterMemberServeFixture.make(stopOnDisconnect: false, heartbeatSeconds: 1)
        let task = fixture.start()
        do {
            let registration = try await fixture.awaitRegistration()
            try await fixture.accept(registration)
            // The acceptance itself triggers a heartbeat; every one must say the same.
            try await Task.sleep(for: .milliseconds(1500))
            let beats = fixture.mock.snapshot().heartbeats
            try #require(!beats.isEmpty)
            #expect(beats.allSatisfy { $0.status == .draining }, "statuses: \(beats.map(\.status))")
            #expect(beats.allSatisfy { $0.activeModel == nil && $0.warmModels.isEmpty })
            #expect(beats.allSatisfy { $0.backendCapacity?.slots.isEmpty == true })
            try await fixture.mock.pushInferenceRequest(requestId: "pair-request-1",
                providerPublicKeyBase64: try #require(registration.publicKey),
                chatRequestJSON: Data(#"{"model":"fixture/cluster-member-qwen","messages":[{"role":"user","content":"hi"}]}"#.utf8))
            let refused = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) { !$0.inferenceErrors.isEmpty }?.inferenceErrors.first)
            #expect(refused.requestId == "pair-request-1" && refused.statusCode == 503)
            #expect(refused.failureCode == .modelUnavailable)
            let after = fixture.mock.snapshot()
            #expect(after.inferenceAccepted.isEmpty && after.inferenceChunks.isEmpty && after.inferenceComplete.isEmpty)
        } catch { await fixture.cleanUp(task); throw error }
        await fixture.cleanUp(task)
    }

    /// A member whose saved setup carries a pair approval registers the claim
    /// derived from its installed control. The frame is read as raw bytes from
    /// a real WebSocket, on the attested registration path.
    @Test("Member with an installed control registers its membership", arguments: [0, 1])
    func memberWithAnInstalledControlRegistersItsMembership(rank: Int) async throws {
        let contract = try MemberContractFixture()
        let fixture = try await ClusterMemberServeFixture.make(stopOnDisconnect: false, pairing: contract.installations[rank])
        let task = fixture.start()
        do {
            let registration = try await fixture.awaitRegistration()
            let policy = SHA256.hash(data: contract.policy).map { String(format: "%02x", $0) }.joined()
            #expect(registration.attestation != nil)
            let claim = try ClusterMembership(clusterID: "native-member-contract", rank: rank, policySHA256: policy)
            #expect(registration.clusterMembership == claim)
            let raw = String(decoding: try #require(fixture.mock.snapshot().registerFrames.first), as: UTF8.self)
            #expect(raw.contains(#""cluster_membership":{"cluster_id":"native-member-contract","policy_sha256":"\#(policy)","rank":\#(rank)}"#))
            #expect(raw.contains(#""execution_role":"cluster_member""#) && raw.contains(#""models":[]"#))
            print("REGISTER_FRAME_AS_EMITTED rank=\(rank) \(raw)")
            // The mock speaks plain WebSocket: the acknowledgment must not
            // attach the control, and the member reports no accepted connection.
            try await fixture.mock.pushClusterMemberAcceptance(nonce: try #require(registration.memberRegistrationNonce))
            await #expect(throws: (any Error).self) {
                try await fixture.loop.waitForClusterMemberRegistration(until: .now.advanced(by: .seconds(3)))
            }
            #expect(await fixture.loop.nativePairMemberStatus == "idle")
            #expect(fixture.mock.snapshot().nativePairs.isEmpty)
        } catch { await fixture.cleanUp(task); throw error }
        await fixture.cleanUp(task)
    }

    /// F11: a leader restarted while its coordinator was away waited 30 s and
    /// then reported "Coordinator did not accept the control-only member
    /// role." although nothing had answered at all. The wait must say the
    /// coordinator was not reached, and end promptly at its deadline.
    @Test func unreachableCoordinatorIsNotReportedAsARoleRefusal() async throws {
        let port = try freeLoopbackPort()
        let fixture = try await ClusterMemberServeFixture.make(stopOnDisconnect: true, absentOnPort: port)
        let task = fixture.start()
        do {
            let started = ContinuousClock.now
            await #expect(throws: ClusterMemberControlError.coordinatorUnreachable) {
                try await fixture.loop.waitForClusterMemberRegistration(until: .now.advanced(by: .seconds(2)))
            }
            // The final attempt at the deadline is refused at once: no extra window is spent.
            let waited = ContinuousClock.now - started
            #expect(waited < .seconds(5), "waited \(waited)")
            #expect(await fixture.loop.memberConnectionID == nil)
        } catch { await fixture.cleanUp(task); throw error }
        await fixture.cleanUp(task)
    }

    /// Pilot blocker: a coordinator that predates the member role (platform
    /// master) answers the registration as an ordinary provider's (here its
    /// desired builds) and keeps the connection open without ever sending
    /// the acknowledgement. That answer means the role is unknown there, not
    /// that this member was refused: the wait says so, so the leader can
    /// serve locally instead of restarting every 38 s.
    @Test func aCoordinatorWithoutTheMemberRoleIsReportedAsUnsupported() async throws {
        try await withMemberServeLoop(stopOnDisconnect: true) { fixture, _ in
            let started = ContinuousClock.now
            let coordinator = Task {
                _ = try await fixture.awaitRegistration()
                try await fixture.mock.pushDesiredModels([])
            }
            await #expect(throws: ClusterMemberControlError.roleUnsupported) {
                try await fixture.loop.waitForClusterMemberRegistration(until: started.advanced(by: .seconds(20)))
            }
            try await coordinator.value
            // Ended by this connection's negotiation window, not the wait's deadline.
            #expect(ContinuousClock.now - started < .seconds(15))
            #expect(await fixture.loop.memberConnectionID == nil)
        }
    }

    /// A coordinator that knows the role and refuses THIS member closes the
    /// connection (or never answers it): that stays a refusal even when it
    /// had answered the registration first. Each connection is judged on its
    /// own answer.
    @Test func aCoordinatorThatClosesTheMemberConnectionStillRefusesIt() async throws {
        try await withMemberServeLoop(stopOnDisconnect: true) { fixture, _ in
            let started = ContinuousClock.now
            let coordinator = Task {
                _ = try await fixture.awaitRegistration()
                try await fixture.mock.pushDesiredModels([])
                await fixture.mock.dropActiveWebSocket()
            }
            var ended: Error?
            do { try await fixture.loop.waitForClusterMemberRegistration(until: started.advanced(by: .seconds(2))) } catch { ended = error }
            let error = try #require(ended as? ClusterMemberControlError)
            #expect(error != .roleUnsupported && error != .coordinatorUnreachable, "a closed member connection read as \(error)")
            #expect(!ClusterLocalServing.servesLocally(after: error))
            try await coordinator.value
            #expect(await fixture.loop.memberConnectionID == nil)
        }
    }

    /// An acknowledgement that does not verify (another connection's nonce)
    /// is a refusal, whatever the coordinator answered before it.
    @Test func aForeignAcknowledgementAfterAnOrdinaryAnswerIsARefusal() async throws {
        try await withMemberServeLoop(stopOnDisconnect: true) { fixture, _ in
            let coordinator = Task {
                _ = try await fixture.awaitRegistration()
                try await fixture.mock.pushDesiredModels([])
                try await fixture.mock.pushClusterMemberAcceptance(nonce: String(repeating: "0", count: 64))
            }
            await #expect(throws: ClusterMemberControlError.negotiationFailed) {
                try await fixture.loop.waitForClusterMemberRegistration(until: .now.advanced(by: .seconds(20)))
            }
            try await coordinator.value
            #expect(await fixture.loop.memberConnectionID == nil)
        }
    }

    /// F11 restart race: the coordinator comes back shortly before the
    /// restarted member's wait ends. A doubling backoff (0.5-1, 1-2, 2-4,
    /// 4-8, 8-16 s) puts the next retry after the deadline, so the member
    /// gave up although its coordinator was back. Its retries now stay
    /// inside the wait, and the one placed at the deadline is given its
    /// own negotiation window. Acceptance is still the nonce-bound one.
    @Test func restartedMemberRegistersWhenItsCoordinatorReturnsBeforeTheWaitEnds() async throws {
        let port = try freeLoopbackPort()
        let fixture = try await ClusterMemberServeFixture.make(stopOnDisconnect: true, absentOnPort: port)
        let started = ContinuousClock.now
        let task = fixture.start()
        let coordinator = Task {
            try await ContinuousClock().sleep(until: started.advanced(by: .milliseconds(7_500)))
            _ = try await fixture.mock.start(port: port)
            let registration = try #require(try await fixture.mock.awaitFirstRegister(timeout: .seconds(20)))
            try await fixture.mock.pushClusterMemberAcceptance(nonce: try #require(registration.memberRegistrationNonce))
        }
        do {
            try await fixture.loop.waitForClusterMemberRegistration(until: started.advanced(by: .seconds(8)))
            #expect(await fixture.loop.memberConnectionID != nil)
            try await coordinator.value
            let registers = fixture.mock.snapshot().registers
            #expect(registers.count == 1 && registers.first?.executionRole == .clusterMember)
        } catch {
            coordinator.cancel()
            await fixture.cleanUp(task); throw error
        }
        await fixture.cleanUp(task)
    }

    /// A connection reached just before the wait's deadline (a coordinator
    /// back a moment earlier) keeps its own negotiation window: an in-window
    /// acceptance arriving after the deadline connects the member. The wait
    /// reported a role refusal at its deadline instead.
    @Test func aNegotiationOpenAtTheDeadlineRunsToItsWindow() async throws {
        try await withMemberServeLoop(stopOnDisconnect: true) { fixture, _ in
            let started = ContinuousClock.now
            let coordinator = Task {
                let registration = try await fixture.awaitRegistration()
                try await ContinuousClock().sleep(until: started.advanced(by: .milliseconds(2_500)))
                try await fixture.mock.pushClusterMemberAcceptance(nonce: try #require(registration.memberRegistrationNonce))
            }
            do {
                try await fixture.loop.waitForClusterMemberRegistration(until: started.advanced(by: .milliseconds(1_500)))
            } catch { coordinator.cancel(); throw error }
            try await coordinator.value
            #expect(await fixture.loop.memberConnectionID != nil)
            #expect(ContinuousClock.now - started < .seconds(10))
            #expect(fixture.mock.snapshot().registers.count == 1)
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

/// A loopback port nothing listens on (bound, read, released).
private func freeLoopbackPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EMFILE) }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
        }
    }
    guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
    return Int(UInt16(bigEndian: address.sin_port))
}
