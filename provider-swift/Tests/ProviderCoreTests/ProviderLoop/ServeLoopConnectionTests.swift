import Foundation
import Testing

@testable import ProviderCore

#if DEBUG
/// `ProviderLoop.run()` against a mock coordinator: connection,
/// registration, heartbeats, reconnect and shutdown.
@Suite("Serve loop connection", .serialized)
struct ServeLoopConnectionTests {
    @Test("registers with the loop's key, a signed attestation and the configured options")
    func registersWithIdentityAndOptions() async throws {
        let fixture = try await ServeLoopFixture.make(privateOnly: true)
        let task = fixture.start()
        let register = try await fixture.awaitRegistration()

        #expect(register.backend == "mlx-swift")
        #expect(register.publicKey == (await fixture.loop.keyPair.publicKeyBase64))
        #expect(register.encryptedResponseChunks)
        #expect(register.privateOnly)
        #expect(register.models.isEmpty, "no model is advertised by this fixture")
        #expect(register.apnsDeviceToken == nil, "the APNs bridge is not used")
        #expect(register.version == ProviderCore.version)
        let caps = try #require(register.privacyCapabilities)
        #expect(caps.textBackendInprocess)
        #expect(caps.textProxyDisabled)
        let attestation = try #require(register.attestation)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let signed = try decoder.decode(SignedAttestation.self, from: attestation.rawBytes)
        #expect(signed.attestation.publicKey == fixture.signer.publicKeyBase64)
        #expect(signed.attestation.encryptionPublicKey == register.publicKey)
        #expect(AttestationBuilder.verify(signed), "the signer's signature verifies")

        // The loop writes its daemon state for `status` and `doctor`.
        let state = try #require(DaemonStateFile.read(from: fixture.stateFile))
        #expect(state.coordinatorUrl == fixture.coordinatorURL)
        #expect(state.pid == getpid())

        #expect(await fixture.stop(task), "run() returns after cancellation")
    }

    @Test("sends idle heartbeats at the configured interval")
    func heartbeatsFollowTheInterval() async throws {
        let fixture = try await ServeLoopFixture.make(heartbeatIntervalSecs: 1)
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        let registeredAt = ContinuousClock.now

        let snapshot = try await fixture.mock.waitForSnapshot(timeout: .seconds(15)) {
            $0.heartbeats.count >= 3
        }
        let elapsed = registeredAt.duration(to: .now)
        let heartbeats = try #require(snapshot).heartbeats
        #expect(heartbeats.count >= 3)
        // The first timed heartbeat waits one interval, so three of them
        // cannot all arrive at once.
        #expect(elapsed >= .milliseconds(1_500), "elapsed \(elapsed)")
        #expect(heartbeats.allSatisfy { $0.status == .idle })

        #expect(await fixture.stop(task))
    }

    @Test("cancels in-flight work on disconnect, registers again and keeps serving")
    func reconnectsAfterDisconnect() async throws {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()

        try await fixture.pushChatRequest(requestId: "before-drop")
        try await fixture.awaitSubmissions(1)

        await fixture.mock.dropActiveWebSocket()
        // The loop cancels every in-flight request when the socket drops.
        try await fixture.awaitEngineCancellations(1)
        let again = try await fixture.mock.waitForSnapshot(timeout: .seconds(15)) {
            $0.registers.count >= 2
        }
        #expect(try #require(again).registers.count >= 2)

        // The new session serves a new request end to end.
        try await fixture.pushChatRequest(requestId: "after-drop")
        try await fixture.awaitSubmissions(2)
        fixture.completeSubmission(1)
        let done = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.inferenceComplete.contains { $0.requestId == "after-drop" }
        }
        let complete = try #require(done?.inferenceComplete.first { $0.requestId == "after-drop" })
        #expect(complete.usage.completionTokens == 1)

        #expect(await fixture.stop(task))
    }

    @Test("a lifecycle drain sends a drain barrier, ends the session and unloads the model")
    func drainAndShutdownEndsTheLoop() async throws {
        let fixture = try await ServeLoopFixture.make()
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        #expect(await fixture.loop.hasEngineV2SlotsForTesting())

        #expect(await fixture.loop.drainAndShutdown(timeoutSeconds: 5))
        #expect(await ServeLoopFixture.finishes(task, within: .seconds(30)), "run() returns")

        let snapshot = fixture.mock.snapshot()
        #expect(!snapshot.drainBarriers.isEmpty, "the coordinator is asked to acknowledge the drain")
        #expect(snapshot.heartbeats.contains { $0.status == .draining })
        #expect(!(await fixture.loop.hasEngineV2SlotsForTesting()), "shutdown unloads every slot")

        await fixture.stop(task)
    }

    @Test("a loop drained before it starts never connects")
    func drainedLoopDoesNotConnect() async throws {
        let fixture = try await ServeLoopFixture.make()
        _ = await fixture.loop.drainAndShutdown(timeoutSeconds: 1)

        let task = fixture.start()
        #expect(await ServeLoopFixture.finishes(task, within: .seconds(10)), "run() returns at once")
        let snapshot = try await fixture.mock.waitForSnapshot(timeout: .milliseconds(500)) {
            !$0.registers.isEmpty
        }
        #expect(snapshot == nil, "no registration reaches the coordinator")

        await fixture.stop(task)
    }
}
#endif
