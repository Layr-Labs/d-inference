import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

@Suite(.serialized) struct AppAttestResumeTransportTests {
    @Test(.timeLimit(.minutes(1))) func reconnectBindsNonceAndResponseToExactSocketWithoutChangingModelState() async throws {
        let fixture = try AppAttestResumeFixture()
        let keys = try fixture.provider
        let mock = MockCoordinator()
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let state = ProviderState()
        state.currentModel = "resident-model"
        state.warmModels = ["resident-model"]
        let client = CoordinatorClient(
            config: AppAttestResumeFixture.config(url: url.mockProviderWebSocketURL(), publicKey: keys.publicKeyBase64),
            stats: AtomicProviderStats(), state: state,
            appAttestResumeResponder: { challenge, nonce in
                try keys.appAttestResumeResponse(to: challenge, clientNonce: nonce)
            })
        let (events, send) = await client.start()
        defer { Task { await client.shutdown() } }
        let drain = Task {
            for await event in events {
                if case .attestationChallenge(let nonce, _) = event {
                    send(.attestationResponse(.init(nonce: nonce, signature: "fixture", statusSignature: nil,
                        publicKey: keys.publicKeyBase64, sipEnabled: true, binaryHash: String(repeating: "a", count: 64))))
                }
                if case .trustStatus = event { Issue.record("custody response must not authorize locally") }
            }
        }
        defer { drain.cancel() }

        let first = try #require(try await mock.awaitFirstRegister(timeout: .seconds(5)))
        let oldConnection = try #require(await client.nwConnection)
        let firstNonce = try #require(first.appAttestResumeNonce)
        #expect(first.appAttestResumeProtocol == 1)
        #expect(Data(base64Encoded: firstNonce)?.count == 32)
        let (firstChallenge, firstPlaintext) = try challenge(fixture, nonce: firstNonce)
        try await mock.pushAppAttestResume(firstChallenge)
        let received = try #require(try await mock.waitForSnapshot(timeout: .seconds(5)) { $0.appAttestResume.count == 1 })
        try expectResponse(fixture, received.appAttestResume[0], plaintext: firstPlaintext)

        // A valid second challenge (different ID) is also refused on this socket.
        try await mock.pushAppAttestResume(firstChallenge)
        try await mock.pushAppAttestResume(challenge(fixture, nonce: firstNonce, idByte: 8).0)
        try await barrier(mock, nonce: "first-barrier")
        #expect(mock.snapshot().appAttestResume.count == 1)

        await mock.dropActiveWebSocket()
        let reconnected = try #require(try await mock.waitForSnapshot(timeout: .seconds(10)) { $0.registers.count == 2 })
        let second = try #require(reconnected.registers.last)
        let secondNonce = try #require(second.appAttestResumeNonce)
        #expect(second.publicKey == first.publicKey)
        #expect(secondNonce != firstNonce)
        #expect(state.currentModel == "resident-model")
        #expect(state.warmModels == ["resident-model"])
        #expect(await client.nwConnection !== oldConnection)

        let (secondChallenge, secondPlaintext) = try challenge(fixture, nonce: secondNonce)
        // Simulate a receive callback queued from the old transport but delivered
        // after reconnect, even carrying the new nonce. It cannot invoke custody.
        await client.handleIncomingFrame(
            try ProviderProtocolCodec.encodeCoordinatorMessage(.appAttestResume(secondChallenge)),
            receivedAt: .now, connection: oldConnection)
        // Same retained record and endpoint, but old connection nonce: no reply.
        try await mock.pushAppAttestResume(firstChallenge)
        try await barrier(mock, nonce: "stale-barrier")
        #expect(mock.snapshot().appAttestResume.count == 1)

        try await mock.pushAppAttestResume(secondChallenge)
        let resumed = try #require(try await mock.waitForSnapshot(timeout: .seconds(5)) { $0.appAttestResume.count == 2 })
        try expectResponse(fixture, resumed.appAttestResume[1], plaintext: secondPlaintext)
        #expect(state.currentModel == "resident-model")
        #expect(state.warmModels == ["resident-model"])

        await client.shutdown()
        #expect(await client.appAttestResumeNonce == nil)
        #expect(await client.appAttestResumeAnswered == false)
        // Delayed responses after shutdown cannot enter a future outbound stream.
        await client.handleIncomingFrame(
            try ProviderProtocolCodec.encodeCoordinatorMessage(.appAttestResume(secondChallenge)),
            receivedAt: .now, connection: oldConnection)
        #expect(mock.snapshot().appAttestResume.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func absentCustodyCallbackDoesNotNegotiate() async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let client = CoordinatorClient(config: AppAttestResumeFixture.config(url: url.mockProviderWebSocketURL()),
            stats: AtomicProviderStats(), state: ProviderState())
        _ = await client.start()
        defer { Task { await client.shutdown() } }
        let register = try #require(try await mock.awaitFirstRegister(timeout: .seconds(5)))
        #expect(register.appAttestResumeProtocol == nil)
        #expect(register.appAttestResumeNonce == nil)
    }

    private func challenge(_ fixture: AppAttestResumeFixture, nonce: String, idByte: UInt8 = 1) throws
        -> (AppAttestResumeChallenge, String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000) - 1000
        let id = Data(repeating: idByte, count: 32).base64EncodedString()
        let plaintext = try fixture.request(overrides: [
            "id": id, "client_nonce": nonce, "issued_at": now, "expires_at": now + 30_000,
        ])
        return (try fixture.seal(plaintext, id: id), plaintext)
    }

    private func expectResponse(_ fixture: AppAttestResumeFixture, _ response: AppAttestResumeResponse,
        plaintext: String) throws {
        var expected = Data("darkbloom.app-attest.endpoint-resume.response.v1\0".utf8)
        expected.append(contentsOf: SHA256.hash(data: Data(plaintext.utf8)))
        #expect(try fixture.open(response) == expected)
    }

    private func barrier(_ mock: MockCoordinator, nonce: String) async throws {
        try await mock.pushAttestationChallenge(nonce: nonce, timestamp: "fixture")
        _ = try #require(try await mock.waitForSnapshot(timeout: .seconds(5)) {
            $0.attestationResponses.contains { $0.nonce == nonce }
        })
    }
}
