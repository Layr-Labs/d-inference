import Foundation
import Testing

@testable import ProviderAppAttest
@testable import ProviderCore

#if DEBUG
@Suite("Serve loop App Attest", .serialized)
struct ServeLoopAppAttestTests {
    @Test("reconnect invalidates held attestation work and preserves the replacement grant")
    func reconnectWhileModelLoadAndAppleCallbackWait() async throws {
        let fixture = try await ServeLoopFixture.make()
        let service = ServeAttestService()
        await fixture.loop.installServeAttestClient(service)
        let task = fixture.start()
        let model = "pending-reconnect-model"
        do {
            _ = try await fixture.awaitRegistration()
            let old = attestPrepare(8)
            try await fixture.mock.pushAppAttestShadow(old)
            let first = try await fixture.mock.waitForSnapshot {
                $0.appAttestShadow.contains { $0.session == old.session && $0.result == "ok" }
            }
            let key = try #require(first?.appAttestShadow.first?.keyID)
            let grant = ProviderAuthorizationStatus(
                appAttestAvailable: true, path: "app_attest", expiresAt: Date().timeIntervalSince1970 + 900,
                sessionID: "old-connection", machineID: "fixture-machine")
            try await fixture.mock.pushTrustStatus(.init(trustLevel: "self_signed", status: "online", authorization: grant))
            #expect(await modelLoadingWaitUntil {
                DaemonStateFile.read(from: fixture.stateFile)?.trust?.authorization == grant
            })
            await service.holdAssertion()
            var assertion = old
            assertion.action = "assert"
            assertion.keyID = key
            let encrypted = try NodeKeyPair.generate().encryptPayload(
                recipientPublicKey: await fixture.loop.keyPair.publicKeyBytes,
                plaintext: Data(Data(repeating: 9, count: 32).base64EncodedString().utf8))
            assertion.encryptedChallenge = ShadowEncryptedChallenge(
                ephemeralPublicKey: encrypted.ephemeralPublicKey, ciphertext: encrypted.ciphertext)
            try await fixture.mock.pushAppAttestShadow(assertion)
            #expect(await modelLoadingWaitUntil { await service.assertionIsHeld() })
            await fixture.loop.modelLoadingMarkLoading(model)
            let body = try JSONSerialization.data(withJSONObject: [
                "model": model, "messages": [["role": "user", "content": "fixture"]], "max_tokens": 1,
            ])
            try await fixture.pushChatRequest(requestId: "held-on-disconnect", body: body)
            #expect(await modelLoadingWaitUntil { await fixture.loop.modelLoadingLoadingWaiterCount(model) == 1 })
            await fixture.mock.dropActiveWebSocket()
            _ = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) { $0.registers.count == 2 })
            #expect(DaemonStateFile.read(from: fixture.stateFile)?.trust == nil,
                    "a disconnected grant clears even though old model work is still parked")
            let replacement = attestPrepare(10)
            try await fixture.mock.pushAppAttestShadow(replacement)
            let busy = try await fixture.mock.waitForSnapshot(timeout: .seconds(2)) {
                $0.appAttestShadow.contains { $0.session == replacement.session && $0.result == "busy" }
            }
            #expect(busy != nil, "the replacement session cannot overlap the held Apple operation")
            await service.releaseAssertion()
            var recovered = false
            for _ in 0..<20 {
                try await fixture.mock.pushAppAttestShadow(replacement)
                if try await fixture.mock.waitForSnapshot(timeout: .milliseconds(100), where: {
                    $0.appAttestShadow.contains { $0.session == replacement.session && $0.result == "ok" }
                }) != nil { recovered = true; break }
            }
            #expect(recovered)
            #expect(!fixture.mock.snapshot().appAttestShadow.contains { $0.session == old.session && $0.action == "assertion" },
                    "a late callback cannot send the old proof through the new connection")
            let newGrant = ProviderAuthorizationStatus(
                appAttestAvailable: true, path: "app_attest", expiresAt: Date().timeIntervalSince1970 + 900,
                sessionID: "replacement-connection", machineID: "fixture-machine")
            try await fixture.mock.pushTrustStatus(.init(trustLevel: "self_signed", status: "online", authorization: newGrant))
            #expect(await modelLoadingWaitUntil { DaemonStateFile.read(from: fixture.stateFile)?.trust?.authorization == newGrant })
            await fixture.loop.modelLoadingClearLoading(model)
            await fixture.loop.modelLoadingResumeLoadingWaiters(model, failure: "fixture released")
            // An ordered legacy challenge is a barrier after old work cleanup.
            try await fixture.mock.pushAttestationChallenge(nonce: "barrier", timestamp: "2026-10-10T00:00:00Z")
            _ = try #require(try await fixture.mock.waitForSnapshot { $0.attestationResponses.contains { $0.nonce == "barrier" } })
            #expect(DaemonStateFile.read(from: fixture.stateFile)?.trust?.authorization == newGrant,
                    "late old-session cleanup must not erase the replacement grant")
            #expect(await service.keyGenerations() == 1, "reconnect reuses the existing key")
        } catch {
            await service.releaseAssertion()
            await fixture.loop.modelLoadingClearLoading(model)
            await fixture.loop.modelLoadingResumeLoadingWaiters(model, failure: "fixture cleanup")
            await fixture.stop(task)
            throw error
        }
        #expect(await fixture.stop(task))
    }

    @Test("a pending model load does not hold App Attest replies or grant updates")
    func attestationWhileModelLoadWaits() async throws {
        let fixture = try await ServeLoopFixture.make(heartbeatIntervalSecs: 1)
        let service = ServeAttestService()
        await fixture.loop.installServeAttestClient(service)
        let task = fixture.start()
        do {
            _ = try await fixture.awaitRegistration()
            let model = "pending-attest-model"
            await fixture.loop.modelLoadingMarkLoading(model)
            let body = try JSONSerialization.data(withJSONObject: [
                "model": model, "messages": [["role": "user", "content": "fixture"]],
                "max_tokens": 1, "stream": true,
            ])
            try await fixture.pushChatRequest(requestId: "waiting-load", body: body)
            let waiting = await modelLoadingWaitUntil {
                await fixture.loop.modelLoadingLoadingWaiterCount(model) == 1
            }
            #expect(waiting, "the real inference handler is parked on its model-load continuation")
            let before = fixture.mock.snapshot().heartbeats.count
            let session = Data(repeating: 7, count: 32).base64EncodedString()
            var prepare = AppAttestShadowPayload(action: "prepare", session: session)
            prepare.protocolVersion = 3
            prepare.environment = "production"
            prepare.accountScope = String(repeating: "a", count: 64)
            let started = ContinuousClock.now
            try await fixture.mock.pushAppAttestShadow(prepare)
            let authorization = ProviderAuthorizationStatus(
                appAttestAvailable: true, path: "app_attest",
                expiresAt: Date().timeIntervalSince1970 + 900,
                sessionID: "held-model-session", machineID: "fixture-machine")
            try await fixture.mock.pushTrustStatus(.init(
                trustLevel: "self_signed", status: "online", reason: "fixture grant",
                authorization: authorization))
            let ready = try await fixture.mock.waitForSnapshot(timeout: .seconds(2)) {
                $0.appAttestShadow.contains { $0.session == session && $0.action == "ready" }
            }
            #expect(ready != nil, "App Attest must progress before the model load completes")
            // A completed ready write is not a barrier for the independent
            // following inbound trust_status frame. Keep both under one bound.
            while DaemonStateFile.read(from: fixture.stateFile)?.trust?.authorization != authorization,
                  ContinuousClock.now < started + .seconds(2) {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(DaemonStateFile.read(from: fixture.stateFile)?.trust?.authorization == authorization,
                    "the received grant must reach daemon state before the model load completes")
            let elapsed = ContinuousClock.now - started
            print("APP_ATTEST_HELD_LOAD reply_before_release=\(ready != nil) elapsed=\(elapsed)")
            let heartbeat = try await fixture.mock.waitForSnapshot(timeout: .seconds(2)) {
                $0.heartbeats.count > before
            }
            #expect(heartbeat != nil, "the socket and independent heartbeat stay healthy")
            await fixture.loop.modelLoadingClearLoading(model)
            await fixture.loop.modelLoadingResumeLoadingWaiters(model, failure: "fixture released")
            let eventual = try await fixture.mock.waitForSnapshot(timeout: .seconds(3)) {
                $0.appAttestShadow.contains { $0.session == session && $0.action == "ready" }
            }
            #expect(eventual != nil, "the same challenge is processed after releasing the load")
            #expect(await service.keyGenerations() == 1)
        } catch {
            await fixture.loop.modelLoadingClearLoading("pending-attest-model")
            await fixture.loop.modelLoadingResumeLoadingWaiters("pending-attest-model", failure: "fixture cleanup")
            await fixture.stop(task)
            throw error
        }
        #expect(await fixture.stop(task))
    }
}

private actor ServeAttestService: AppAttestService {
    private var generated = 0
    private var hold = false
    private var assertion: CheckedContinuation<Data, Never>?
    func checkAvailability(environment: String) {}
    func generateKey() -> String {
        generated += 1
        return Data(repeating: 1, count: 32).base64EncodedString()
    }
    func attestKey(_ id: String, hash: Data) -> Data { Data("fixture attestation".utf8) }
    func generateAssertion(_ id: String, hash: Data) async -> Data {
        if hold { return await withCheckedContinuation { assertion = $0 } }
        return Data("fixture assertion".utf8)
    }
    func operationHeldSince() -> Date? { nil }
    func keyGenerations() -> Int { generated }
    func holdAssertion() { hold = true }
    func assertionIsHeld() -> Bool { assertion != nil }
    func releaseAssertion() {
        hold = false
        let pending = assertion
        assertion = nil
        pending?.resume(returning: Data("fixture assertion".utf8))
    }
}

private func attestPrepare(_ fill: UInt8) -> AppAttestShadowPayload {
    var request = AppAttestShadowPayload(action: "prepare", session: Data(repeating: fill, count: 32).base64EncodedString())
    request.protocolVersion = 3
    request.environment = "production"
    request.accountScope = String(repeating: "a", count: 64)
    return request
}

private final class ServeAttestKeys: ShadowKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ShadowKeyRecord] = [:]
    func load(scope: String) -> ShadowKeyRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[scope]
    }
    func save(_ record: ShadowKeyRecord, scope: String) {
        lock.lock(); defer { lock.unlock() }
        records[scope] = record
    }
}

private extension ProviderLoop {
    func installServeAttestClient(_ service: ServeAttestService) {
        appAttestShadowClient = AppAttestShadowClient(
            scope: loopConfig.coordinatorURL, service: service, storage: ServeAttestKeys())
    }
}
#endif
