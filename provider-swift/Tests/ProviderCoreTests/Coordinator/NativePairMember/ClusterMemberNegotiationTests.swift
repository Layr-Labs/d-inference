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
    private func memberConfig(_ url: String) -> CoordinatorClientConfig {
        CoordinatorClientConfig(
            url: url,
            hardware: .init(machineModel: "fixture", chipName: "Apple M4", chipFamily: .m4, chipTier: .pro,
                memoryGb: 24, memoryAvailableGb: 20, cpuCores: .init(total: 12, performance: 8, efficiency: 4),
                gpuCores: 16, memoryBandwidthGbs: 200),
            models: [.init(id: "fixture-model", modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1)],
            backendName: "mlx-swift",
            heartbeatInterval: 60,
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
