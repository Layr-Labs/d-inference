import Foundation
import Network
import Testing
@testable import ProviderCore

// End-to-end member negotiation against the real local MockCoordinator:
// registration wire shape, nonce-bound acceptance, refusal paths, and the
// native-pair driver binding. No TLS claim: the mock is a cleartext local
// socket, and every assertion here is about protocol sequencing, not trust.

@Suite("Cluster member negotiation (mock coordinator)")
struct ClusterMemberNegotiationTests {
    private func memberConfig(_ url: String, heartbeatInterval: TimeInterval = 60) -> CoordinatorClientConfig {
        CoordinatorClientConfig(
            url: url,
            hardware: .init(machineModel: "fixture", chipName: "Apple M4", chipFamily: .m4, chipTier: .pro,
                memoryGb: 24, memoryAvailableGb: 20, cpuCores: .init(total: 12, performance: 8, efficiency: 4),
                gpuCores: 16, memoryBandwidthGbs: 200),
            models: [.init(id: "fixture-model", modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1)],
            backendName: "mlx-swift",
            heartbeatInterval: heartbeatInterval,
            executionRole: .clusterMember)
    }

    private func waitFor(_ seconds: Double = 3, condition: @escaping () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test func memberRegistrationIsNonceBoundAndInventorySeparated() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        let client = CoordinatorClient(config: memberConfig(url.mockProviderWebSocketURL()),
            stats: .init(), state: .init(), liveAPNsToken: { nil })
        _ = await client.start()
        defer { Task { await client.shutdown(); await mock.shutdown() } }

        let registration = try #require(try await mock.awaitFirstRegister(timeout: .seconds(3)))
        // Ordinary inventory is empty; the cluster inventory rides separately.
        #expect(registration.models.isEmpty)
        #expect(registration.executionRole == .clusterMember)
        #expect(registration.clusterModels?.count == 1)
        let nonce = try #require(registration.memberRegistrationNonce)
        #expect(nonce.count == 64 && nonce.allSatisfy { "0123456789abcdef".contains($0) })
        // Not accepted yet: no session. A control is installed only before the
        // first connection, so installing one now is refused.
        #expect(await client.sessionRegistered == false)
        await #expect(throws: NativePairMemberError.self) {
            let fixture = try MemberContractFixture()
            try await client.installNativePairMember(NativePairMemberControl(
                installation: fixture.installations[0], signer: ContractSigner()))
        }
        // The exact echoed nonce opens the session.
        try await mock.pushClusterMemberAcceptance(nonce: nonce)
        #expect(await waitFor { await client.sessionRegistered })
        #expect(await client.memberRoleFailure == false)
    }

    /// The coordinator dispatches to a re-formed pair only once each member's
    /// heartbeat reports it (DevNet drill, 2026-11-20: a returning member's
    /// first heartbeat came one interval after its registration, ~5 s of a
    /// 10.8 s no-dispatch window). A member's first heartbeat on every
    /// connection goes at its acceptance: the baseline interval here is an
    /// hour, so no timer heartbeat can arrive. None goes before the
    /// acceptance, and one acceptance sends one heartbeat. A capacity quote
    /// is the barrier: the client answers the probe on the same ordered
    /// connection, so a heartbeat it sent before the quote arrives first.
    @Test func aMemberHeartbeatsAtItsAcceptanceAndAgainAtItsReconnectsAcceptance() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        // What `prepareClusterMemberControl` publishes: refusing, no slots.
        let state = ProviderState()
        state.refusingNewWork = true
        state.backendCapacity = BackendCapacity(slots: [], gpuMemoryActiveGb: 0, gpuMemoryPeakGb: 0,
            gpuMemoryCacheGb: 0, totalMemoryGb: 24, freeForLoadGb: 0)
        let client = CoordinatorClient(config: memberConfig(url.mockProviderWebSocketURL(), heartbeatInterval: 3_600),
            stats: .init(), state: state, liveAPNsToken: { nil })
        _ = await client.start()
        defer { Task { await client.shutdown(); await mock.shutdown() } }

        func barrier(_ quoteID: String) async throws -> CapturedMessages {
            try await mock.pushCapacityProbe(.init(quoteId: quoteID, model: "fixture-model",
                promptTokensBucket: 512, maxOutputTokens: 1, deadlineRemainingMs: 1000))
            return try #require(try await mock.waitForSnapshot(timeout: .seconds(5)) {
                $0.capacityQuotes.contains { $0.quoteId == quoteID }
            })
        }
        for connection in 1...2 {
            // The second connection is the reconnect after an edge restart (1012).
            let registered = try #require(try await mock.waitForSnapshot(timeout: .seconds(15)) {
                $0.registers.count == connection
            })
            let nonce = try #require(registered.registers[connection - 1].memberRegistrationNonce)
            let before = try await barrier("before-acceptance-\(connection)")
            #expect(before.heartbeats.count == connection - 1, "a heartbeat went before connection \(connection)'s acceptance")

            try await mock.pushClusterMemberAcceptance(nonce: nonce)
            let accepted = try #require(try await mock.waitForSnapshot(timeout: .seconds(5)) {
                $0.heartbeats.count == connection
            }, "no heartbeat within 5 s of connection \(connection)'s acceptance (baseline interval 1 h)")
            // A full heartbeat, the first of this connection's capacity session.
            let first = accepted.heartbeats[connection - 1]
            #expect(first.status == .draining)
            #expect(first.backendCapacity?.capacitySeq == 1)
            #expect(first.backendCapacity?.slots.isEmpty == true)
            let after = try await barrier("after-acceptance-\(connection)")
            #expect(after.heartbeats.count == connection, "one acceptance sends one heartbeat")

            if connection == 1 { await mock.dropActiveWebSocket(closeCode: 1012, reason: "edge restart") }
        }
        #expect(await client.memberRoleFailure == false)
    }

    /// What `prepareClusterMemberControl` publishes: refusing, no slots.
    /// `gpuMemoryActiveGb: .nan` makes the heartbeat fail to encode
    /// (JSONEncoder throws on a non-finite number).
    private func memberCapacity(gpuMemoryActiveGb: Double = 0) -> BackendCapacity {
        BackendCapacity(slots: [], gpuMemoryActiveGb: gpuMemoryActiveGb, gpuMemoryPeakGb: 0,
            gpuMemoryCacheGb: 0, totalMemoryGb: 24, freeForLoadGb: 0)
    }

    /// A member client (baseline interval one hour) whose first connection
    /// was accepted and whose acceptance heartbeat arrived.
    private func acceptedMember(state: ProviderState) async throws -> (MockCoordinator, CoordinatorClient) {
        let mock = MockCoordinator()
        let url = try await mock.start()
        let client = CoordinatorClient(config: memberConfig(url.mockProviderWebSocketURL(), heartbeatInterval: 3_600),
            stats: .init(), state: state, liveAPNsToken: { nil })
        _ = await client.start()
        let registration = try #require(try await mock.awaitFirstRegister(timeout: .seconds(3)))
        try await mock.pushClusterMemberAcceptance(nonce: try #require(registration.memberRegistrationNonce))
        _ = try #require(try await mock.waitForSnapshot(timeout: .seconds(5)) { $0.heartbeats.count == 1 })
        return (mock, client)
    }

    /// The coordinator applies a heartbeat only when its `capacity_seq` is
    /// higher than the last one it applied on the connection; an older frame
    /// counts for liveness only. The acceptance heartbeat and the next one on
    /// the same connection (the serve loop's `.connected` heartbeat in
    /// production) leave in sequence order, 1 then 2, and the later one
    /// carries the same full state, so the frame applied last never loses
    /// the member's state.
    @Test func aMembersHeartbeatsAfterItsAcceptanceLeaveInSequenceOrderWithItsFullState() async throws {
        let state = ProviderState()
        state.refusingNewWork = true
        state.backendCapacity = memberCapacity()
        let (mock, client) = try await acceptedMember(state: state)
        defer { Task { await client.shutdown(); await mock.shutdown() } }

        await client.sendEventHeartbeat()
        let beats = try #require(try await mock.waitForSnapshot(timeout: .seconds(5)) {
            $0.heartbeats.count == 2
        }).heartbeats
        // The mock records frames in the order they arrived on the connection.
        #expect(beats.map { $0.backendCapacity?.capacitySeq } == [1, 2])
        // Equal but for the sequence and the live system metrics.
        var later = beats[1]
        later.backendCapacity?.capacitySeq = 1
        later.systemMetrics = beats[0].systemMetrics
        #expect(later == beats[0])
        #expect(beats[1].status == .draining && beats[1].backendCapacity?.slots.isEmpty == true)
    }

    /// The minimal fallback frame has no `capacity_seq` and no
    /// `cluster_session`: the coordinator would apply it outside the
    /// sequence order and withdraw the member's session report. A member
    /// whose heartbeat fails to encode sends nothing, on the event path and
    /// on the baseline timer's path, and its next heartbeat is a full one. A
    /// solo provider keeps the fallback frame.
    @Test func aMemberWhoseHeartbeatFailsToEncodeSendsNoFrame() async throws {
        let state = ProviderState()
        state.refusingNewWork = true
        state.backendCapacity = memberCapacity()
        let (mock, client) = try await acceptedMember(state: state)
        defer { Task { await client.shutdown(); await mock.shutdown() } }

        state.backendCapacity = memberCapacity(gpuMemoryActiveGb: .nan)
        #expect(await client.buildHeartbeatJSON() == nil, "the baseline timer's build gives nothing to send")
        await client.sendEventHeartbeat()
        state.backendCapacity = memberCapacity()
        await client.sendEventHeartbeat()
        // The full heartbeat is the barrier: a frame sent before it on the
        // same connection would have arrived first.
        let beats = try #require(try await mock.waitForSnapshot(timeout: .seconds(5)) {
            $0.heartbeats.contains { $0.backendCapacity?.capacitySeq == 4 }
        }).heartbeats
        // Sequences 2 and 3 were the two failed builds; no frame carried them.
        #expect(beats.map { $0.backendCapacity?.capacitySeq } == [1, 4])
        #expect(beats[1].status == .draining && beats[1].backendCapacity?.slots.isEmpty == true)

        let soloState = ProviderState()
        soloState.backendCapacity = memberCapacity(gpuMemoryActiveGb: .nan)
        let solo = CoordinatorClient(config: CoordinatorClientConfig(url: "ws://127.0.0.1:0/ignored",
            hardware: memberConfig("ws://127.0.0.1:0/ignored").hardware, models: [], backendName: "mlx-swift"),
            stats: .init(), state: soloState, liveAPNsToken: { nil })
        let fallback = try #require(await solo.buildHeartbeatJSON(), "a solo provider keeps the fallback frame")
        #expect(fallback.contains(#""type":"heartbeat""#) && !fallback.contains("backend_capacity"))
    }

    @Test func wrongNonceAcceptanceFailsClosed() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        let client = CoordinatorClient(config: memberConfig(url.mockProviderWebSocketURL()),
            stats: .init(), state: .init(), liveAPNsToken: { nil })
        _ = await client.start()
        defer { Task { await client.shutdown(); await mock.shutdown() } }

        _ = try #require(try await mock.awaitFirstRegister(timeout: .seconds(3)))
        try await mock.pushClusterMemberAcceptance(nonce: String(repeating: "0", count: 64))
        #expect(await waitFor { await client.memberRoleFailure })
        #expect(await client.sessionRegistered == false)
    }

    @Test func soloConnectionIgnoresMemberAcceptance() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        let member = memberConfig(url.mockProviderWebSocketURL())
        let client = CoordinatorClient(config: CoordinatorClientConfig(
            url: member.url, hardware: member.hardware, models: member.models,
            backendName: member.backendName, heartbeatInterval: member.heartbeatInterval),
            stats: .init(), state: .init(), liveAPNsToken: { nil })
        _ = await client.start()
        defer { Task { await client.shutdown(); await mock.shutdown() } }

        _ = try #require(try await mock.awaitFirstRegister(timeout: .seconds(3)))
        #expect(await client.sessionRegistered == true)
        // A stray member acceptance is ignored on a solo connection.
        try await mock.pushClusterMemberAcceptance(nonce: String(repeating: "1", count: 64))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await client.memberRoleFailure == false)
        #expect(await client.sessionRegistered == true)
    }

    @Test func nativePairDriverBindsAfterAcceptanceAndRefusesStaleFrames() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        let client = CoordinatorClient(config: memberConfig(url.mockProviderWebSocketURL()),
            stats: .init(), state: .init(), liveAPNsToken: { nil })
        _ = await client.start()
        defer { Task { await client.shutdown(); await mock.shutdown() } }

        let registration = try #require(try await mock.awaitFirstRegister(timeout: .seconds(3)))
        let nonce = try #require(registration.memberRegistrationNonce)
        try await mock.pushClusterMemberAcceptance(nonce: nonce)
        #expect(await waitFor { await client.sessionRegistered })

        // The driver binds to the exact accepted connection and nonce. The
        // mock speaks plain WebSocket, so the test attaches past the TLS gate.
        let fixture = try MemberContractFixture()
        let control = NativePairMemberControl(installation: fixture.installations[0], signer: ContractSigner())
        _ = try await client.attachFixtureControl(control)

        // A prepare whose epoch/start does not match the committed
        // installation is refused; nothing is published to the coordinator.
        let wall = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let stalePrepare = try NativePairMessage(type: "native_pair_prepare",
            memberNonce: nonce, epoch: String(repeating: "ee", count: 16), generation: 7, sequence: 1,
            payload: fixture.preparationPayload(0),
            prepareBeforeUnixNano: wall + 5_000_000_000, expiresAtUnixNano: wall + 12_000_000_000)
        try await mock.pushNativePair(stalePrepare)
        let detached = await waitFor(1) {
            guard let connection = await client.nativePairConnection else { return true }
            return await !connection.isLive
        }
        #expect(detached)
        #expect(mock.snapshot().nativePairs.isEmpty)
    }

    /// A member that loses trust or runtime verification may not keep its
    /// attachment; the installed control stays for the next accepted connection.
    @Test("Lost trust or runtime verification drops the member attachment", arguments: ["trust", "runtime"])
    func lostTrustOrRuntimeDropsTheMemberAttachment(kind: String) async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        let client = CoordinatorClient(config: memberConfig(url.mockProviderWebSocketURL()),
            stats: .init(), state: .init(), liveAPNsToken: { nil })
        _ = await client.start()
        defer { Task { await client.shutdown(); await mock.shutdown() } }
        let registration = try #require(try await mock.awaitFirstRegister(timeout: .seconds(3)))
        try await mock.pushClusterMemberAcceptance(nonce: try #require(registration.memberRegistrationNonce))
        #expect(await waitFor { await client.sessionRegistered })
        let fixture = try MemberContractFixture()
        let control = NativePairMemberControl(installation: fixture.installations[0], signer: ContractSigner())
        let attachment = try await client.attachFixtureControl(control)
        let message: CoordinatorMessage = kind == "trust"
            ? .trustStatus(.init(trustLevel: "none", status: "untrusted", reason: "fixture"))
            : .runtimeStatus(.init(verified: false))
        await client.handleIncomingFrame(try ProviderProtocolCodec.encodeCoordinatorMessage(message), receivedAt: .now)
        #expect(await client.nativePairConnection == nil)
        #expect(!attachment.isLive)
        #expect(await client.nativePairMember === control)
    }

    /// The coordinator must queue the acknowledgment before any pair frame. A
    /// frame that overtakes it has no attachment to bind to and strict
    /// sequencing leaves no way to accept it later, so the connection ends and
    /// the member negotiates again.
    @Test func nativePairFrameBeforeAcceptanceEndsTheConnection() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        let client = CoordinatorClient(config: memberConfig(url.mockProviderWebSocketURL()),
            stats: .init(), state: .init(), liveAPNsToken: { nil })
        _ = await client.start()
        defer { Task { await client.shutdown(); await mock.shutdown() } }
        let registration = try #require(try await mock.awaitFirstRegister(timeout: .seconds(3)))
        let nonce = try #require(registration.memberRegistrationNonce)
        try await mock.pushNativePair(try MemberContractFixture().prepareMessage(0, nonce: nonce, sequence: 1))
        // A second registration with a fresh nonce is the reconnect.
        #expect(await waitFor(6) { mock.snapshot().registers.count >= 2 })
        #expect(mock.snapshot().registers.last?.memberRegistrationNonce != nonce)
        #expect(mock.snapshot().nativePairs.isEmpty)
    }
}
