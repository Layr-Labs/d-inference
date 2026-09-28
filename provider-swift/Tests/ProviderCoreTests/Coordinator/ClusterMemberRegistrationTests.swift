import Foundation
import Testing
@testable import ProviderCore

private func memberHardware() -> HardwareInfo {
    .init(machineModel: "fixture", chipName: "Apple M4", chipFamily: .m4, chipTier: .pro,
          memoryGb: 24, memoryAvailableGb: 20,
          cpuCores: .init(total: 12, performance: 8, efficiency: 4), gpuCores: 16, memoryBandwidthGbs: 200)
}
private func memberConfig(role: ProviderExecutionRole) -> CoordinatorClientConfig {
    .init(url: "wss://coordinator.invalid/ws", hardware: memberHardware(),
          models: [.init(id: "fixture-model", modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1)],
          backendName: "mlx-swift", attestation: .init(rawBytes: Data(#"{"signed":"fixture"}"#.utf8)),
          executionRole: role)
}

@Suite("Cluster member role negotiation")
struct ClusterMemberRegistrationTests {
    @Test func legacyOmissionAndMemberInventorySurviveRawAttestation() throws {
        let solo = try CoordinatorClientCodec.encodeRegistration(from: memberConfig(role: .solo))
        let old = try #require(JSONSerialization.jsonObject(with: solo) as? [String: Any])
        #expect(old["execution_role"] == nil && old["cluster_models"] == nil)
        #expect((old["models"] as? [[String: Any]])?.count == 1)
        let negotiation = ClusterMemberNegotiation()
        let bytes = try CoordinatorClientCodec.encodeRegistration(from: memberConfig(role: .clusterMember),
            memberRegistrationNonce: negotiation.nonce)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["execution_role"] as? String == "cluster_member")
        #expect((object["models"] as? [Any])?.isEmpty == true)
        #expect((object["cluster_models"] as? [[String: Any]])?.first?["id"] as? String == "fixture-model")
        guard case .register(let decoded) = try ProviderProtocolCodec.decodeProviderMessage(from: bytes) else {
            Issue.record("wrong registration type"); return
        }
        #expect(decoded.executionRole == .clusterMember && decoded.models.isEmpty)
        #expect(decoded.memberRegistrationNonce == negotiation.nonce && decoded.clusterModels?.count == 1)
    }

    @Test func explicitAckRejectsWrongNonceRoleLateAndDuplicate() throws {
        let start = ContinuousClock.now
        let original = ClusterMemberNegotiation(now: start)
        func ack(_ nonce: String, role: ProviderExecutionRole = .clusterMember) -> ClusterMemberAccepted {
            .init(executionRole: role, memberRegistrationNonce: nonce, providerID: "connection-1")
        }
        for bad in [ack("wrong"), ack(original.nonce, role: .solo)] {
            var attempt = original
            #expect(throws: ClusterMemberControlError.self) { try attempt.accept(bad, now: start) }
            #expect(attempt.providerID == nil)
        }
        var late = original
        #expect(throws: ClusterMemberControlError.self) { try late.accept(ack(original.nonce), now: original.deadline) }
        var valid = original
        try valid.accept(ack(original.nonce), now: start)
        #expect(valid.providerID == "connection-1")
        #expect(throws: ClusterMemberControlError.self) { try valid.accept(ack(original.nonce), now: start) }
        var reconnect = ClusterMemberNegotiation(now: start)
        #expect(reconnect.nonce != original.nonce)
        #expect(throws: ClusterMemberControlError.self) { try reconnect.accept(ack(original.nonce), now: start) }
        let bytes = try ProviderProtocolCodec.encodeCoordinatorMessage(.clusterMemberAccepted(ack(original.nonce)))
        #expect(try CoordinatorClientCodec.decodeIncomingMessage(from: bytes) == .clusterMemberAccepted(ack(original.nonce)))
    }

    @Test("Real WebSocket requires explicit member acknowledgment", arguments: [false, true])
    func realSocketRoleNegotiation(acknowledge: Bool) async throws {
        let mock = MockCoordinator()
        let base = try await mock.start()
        let client = CoordinatorClient(config: .init(url: base.mockProviderWebSocketURL(),
            hardware: memberHardware(), models: memberConfig(role: .clusterMember).models,
            backendName: "mlx-swift", heartbeatInterval: 1, executionRole: .clusterMember),
            stats: .init(), state: .init(), liveAPNsToken: { nil })
        let (events, _) = await client.start()
        do {
            let first = try await mock.awaitFirstRegister(timeout: .seconds(5))
            let registration = try #require(first)
            #expect(registration.models.isEmpty && registration.clusterModels?.count == 1)
            #expect(await client.sessionRegistered == false)
            if acknowledge {
                try await mock.pushClusterMemberAcceptance(nonce: try #require(registration.memberRegistrationNonce))
            }
            // AsyncStream cancellation resumes the losing iterator; no blocked
            // network read is left owned by this task group.
            let connected = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await event in events { if case .connected = event { return true } }
                    return false
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw ClusterMemberControlError.negotiationFailed
                }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }
            #expect(connected == acknowledge)
            #expect(await client.memberRoleFailure == !acknowledge)
            await client.shutdownAndWait()
            await mock.shutdown()
        } catch {
            await client.shutdownAndWait()
            await mock.shutdown()
            throw error
        }
    }

    @Test func staleNegotiationTimerCannotRefuseReplacement() async throws {
        let client = CoordinatorClient(config: memberConfig(role: .clusterMember),
            stats: .init(), state: .init(), liveAPNsToken: { nil })
        let old = await client.testBeginMemberNegotiation()
        let fresh = await client.testBeginMemberNegotiation()
        await client.expireMemberNegotiation(nonce: old.nonce, now: fresh.deadline)
        #expect(await client.memberRoleFailure == false)
        #expect(await client.memberNegotiation?.nonce == fresh.nonce)
        await client.expireMemberNegotiation(nonce: fresh.nonce, now: fresh.deadline)
        #expect(await client.memberRoleFailure)
        #expect(await client.sessionRegistered == false)
    }

    @Test func clientDoesNotPublishConnectedBeforeAckAndRefusesOldAckOnReconnect() async throws {
        let client = CoordinatorClient(config: memberConfig(role: .clusterMember),
            stats: .init(), state: .init(), liveAPNsToken: { nil })
        let first = await client.testBeginMemberNegotiation()
        #expect(await client.sessionRegistered == false)
        let ack = ClusterMemberAccepted(executionRole: .clusterMember,
            memberRegistrationNonce: first.nonce, providerID: "connection-1")
        let bytes = try ProviderProtocolCodec.encodeCoordinatorMessage(.clusterMemberAccepted(ack))
        await client.handleIncomingFrame(bytes, receivedAt: .now)
        #expect(await client.sessionRegistered)
        _ = await client.testBeginMemberNegotiation()
        await client.handleIncomingFrame(bytes, receivedAt: .now)
        #expect(await client.sessionRegistered == false)
        #expect(await client.memberRoleFailure)
    }
}

private extension CoordinatorClient {
    func testBeginMemberNegotiation() -> ClusterMemberNegotiation {
        sessionRegistered = false
        let value = ClusterMemberNegotiation()
        memberNegotiation = value
        return value
    }
}
