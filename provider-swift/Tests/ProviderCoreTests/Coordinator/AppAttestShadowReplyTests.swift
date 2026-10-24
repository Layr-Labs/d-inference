import Foundation
import ProviderAppAttest
import Testing
@testable import ProviderCore

@Suite(.serialized) struct AppAttestShadowReplyTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["attest", "assert"], [false, true])
    func oldProofCannotReachReplacementBeforeLoopConsumesDisconnect(action: String, delayedEvent: Bool) async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let client = CoordinatorClient(config: AppAttestResumeFixture.config(url: url.mockProviderWebSocketURL()),
            stats: AtomicProviderStats(), state: ProviderState())
        let (events, send) = await client.start()
        defer { Task { await client.shutdown() } }
        _ = try #require(try await mock.awaitFirstRegister(timeout: .seconds(5)))
        var iterator = events.makeAsyncIterator()
        let firstRequest = request(action, sessionByte: 1)
        let oldConnection = try #require(await client.nwConnection)
        try await mock.pushAppAttestShadow(firstRequest)
        // Capacity replies are handled by CoordinatorClient, not the loop. This
        // barrier proves A's earlier event is queued without consuming it.
        try await mock.pushCapacityProbe(.init(quoteId: "a-ingress-barrier", model: "fixture",
            promptTokensBucket: 512, maxOutputTokens: 1, deadlineRemainingMs: 1000))
        _ = try #require(try await mock.waitForSnapshot(timeout: .seconds(5)) {
            $0.capacityQuotes.contains { $0.quoteId == "a-ingress-barrier" }
        })
        var pending: (AppAttestShadowPayload, AppAttestShadowReply)?
        if !delayedEvent { pending = try await nextReply(&iterator) }

        await mock.dropActiveWebSocket()
        _ = try #require(try await mock.waitForSnapshot(timeout: .seconds(10)) { $0.registers.count == 2 })
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await client.sessionRegistered), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await client.sessionRegistered)
        #expect(await client.nwConnection !== oldConnection)

        if delayedEvent { pending = try await nextReply(&iterator) }
        let (captured, oldReply) = try #require(pending)
        #expect(captured == firstRequest)

        // Whether A's request was pending in the event queue or its worker was
        // already running, the loop has not consumed A's disconnect or B's
        // connected event. A loop-side generation check would still match.
        let oldProof = response(to: firstRequest)
        let finishingWorker = Task.detached { await oldReply.send(oldProof) }
        await finishingWorker.value
        // A normal outbound marker confirms B processed the wire after the old
        // send attempt. This would expose a reply sent via a stable router too.
        send(.attestationResponse(.init(nonce: "after-old-reply", signature: "fixture", statusSignature: nil,
            publicKey: "fixture", sipEnabled: true, binaryHash: "fixture")))
        _ = try #require(try await mock.waitForSnapshot(timeout: .seconds(5)) {
            $0.attestationResponses.contains { $0.nonce == "after-old-reply" }
        })
        #expect(mock.snapshot().appAttestShadow.isEmpty)

        let secondRequest = request(action, sessionByte: 2)
        try await mock.pushAppAttestShadow(secondRequest)
        let (current, newReply) = try await nextReply(&iterator)
        #expect(current == secondRequest)
        let newProof = response(to: secondRequest)
        await newReply.send(newProof)
        let snapshot = try #require(try await mock.waitForSnapshot(timeout: .seconds(5)) { $0.appAttestShadow.count == 1 })
        #expect(snapshot.appAttestShadow == [newProof])

        await client.shutdown()
        await newReply.send(newProof)
        #expect(mock.snapshot().appAttestShadow == [newProof])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["prepare", "attest", "assert"])
    func capabilityAcceptsOnlyItsBoundResponse(action: String) async throws {
        let mock = MockCoordinator()
        let url = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let client = CoordinatorClient(config: AppAttestResumeFixture.config(url: url.mockProviderWebSocketURL()),
            stats: AtomicProviderStats(), state: ProviderState())
        let (events, _) = await client.start()
        defer { Task { await client.shutdown() } }
        _ = try #require(try await mock.awaitFirstRegister(timeout: .seconds(5)))
        var iterator = events.makeAsyncIterator()
        let message = request(action, sessionByte: 3)
        try await mock.pushAppAttestShadow(message)
        let (_, reply) = try await nextReply(&iterator)
        let valid = response(to: message)
        var wrongSession = valid
        wrongSession.session = "another-session"
        var wrongProtocol = valid
        wrongProtocol.protocolVersion = 2
        var wrongAction = valid
        wrongAction.action = "prepare"
        var oversized = valid
        oversized.proof = String(repeating: "A", count: 64 * 1024)
        for invalid in [wrongSession, wrongProtocol, wrongAction, oversized] { await reply.send(invalid) }
        await reply.send(valid)
        let snapshot = try #require(try await mock.waitForSnapshot(timeout: .seconds(5)) { !$0.appAttestShadow.isEmpty })
        #expect(snapshot.appAttestShadow == [valid])
    }

    private func request(_ action: String, sessionByte: UInt8) -> AppAttestShadowPayload {
        var request = AppAttestShadowPayload(action: action,
            session: Data(repeating: sessionByte, count: 32).base64EncodedString())
        request.protocolVersion = 3
        return request
    }

    private func response(to request: AppAttestShadowPayload) -> AppAttestShadowPayload {
        var response = AppAttestShadowPayload(action: ["prepare": "ready", "attest": "attestation", "assert": "assertion"][request.action]!,
            session: request.session)
        response.protocolVersion = request.protocolVersion
        response.result = "ok"
        response.proof = Data("synthetic-proof".utf8).base64EncodedString()
        return response
    }

    private func nextReply(_ iterator: inout AsyncStream<CoordinatorEvent>.Iterator) async throws
        -> (AppAttestShadowPayload, AppAttestShadowReply) {
        while let event = await iterator.next() {
            if case .appAttestShadow(let payload, let reply) = event { return (payload, reply) }
        }
        throw CancellationError()
    }
}
