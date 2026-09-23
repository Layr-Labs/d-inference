import Foundation
import XCTest
@preconcurrency import DeviceCheck
@testable import ProviderAppAttest

private final class EnrollmentStorage: ShadowKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ShadowKeyRecord] = [:]
    func load(scope: String) -> ShadowKeyRecord? { lock.lock(); defer { lock.unlock() }; return values[scope] }
    func save(_ record: ShadowKeyRecord, scope: String) { lock.lock(); defer { lock.unlock() }; values[scope] = record }
}

private final class FailingEnrollmentStorage: ShadowKeyStorage, @unchecked Sendable {
    let backing = EnrollmentStorage()
    private let lock = NSLock()
    private var failed = false
    private let failOnRetirement: Bool
    init(failOnRetirement: Bool) { self.failOnRetirement = failOnRetirement }
    func load(scope: String) -> ShadowKeyRecord? { backing.load(scope: scope) }
    func save(_ record: ShadowKeyRecord, scope: String) throws {
        lock.lock(); defer { lock.unlock() }
        let targetedWrite = failOnRetirement ? record.keyID.isEmpty : record.attestationStartedAt != nil
        if targetedWrite && !failed { failed = true; throw ShadowFailure.keychainError }
        backing.save(record, scope: scope)
    }
}

private actor EnrollmentService: AppAttestService {
    var enrollmentFailure: ShadowFailure?
    var assertionFailure: ShadowFailure?
    var nativeEnrollmentFailure: AppleAppAttestFailure?
    private var enrollmentCalls: [(String, Data)] = []
    private var assertionCalls: [(String, Data)] = []
    private var generations = 0
    init(enrollmentFailure: ShadowFailure? = nil, assertionFailure: ShadowFailure? = nil) {
        self.enrollmentFailure = enrollmentFailure; self.assertionFailure = assertionFailure
    }
    func checkAvailability(environment: String) {}
    func generateKey() -> String { generations += 1; return Data(repeating: UInt8(generations), count: 32).base64EncodedString() }
    func attestKey(_ id: String, hash: Data) throws -> Data {
        enrollmentCalls.append((id, hash))
        if let nativeEnrollmentFailure { throw nativeEnrollmentFailure }
        if let enrollmentFailure { throw enrollmentFailure }
        return Data("test-attestation".utf8)
    }
    func generateAssertion(_ id: String, hash: Data) throws -> Data {
        assertionCalls.append((id, hash))
        if let assertionFailure { throw assertionFailure }
        return Data("test-assertion".utf8)
    }
    func allowEnrollment() { enrollmentFailure = nil; nativeEnrollmentFailure = nil }
    func generated() -> Int { generations }
    func failNatively(_ error: AppleAppAttestFailure) { nativeEnrollmentFailure = error }
    func calls() -> [(String, Data)] { enrollmentCalls }
    func assertions() -> [(String, Data)] { assertionCalls }
}

final class EnrollmentRecoveryTests: XCTestCase {
    private let scope = "test:production:account:" + String(repeating: "a", count: 64)
    private let endpoint = Data(repeating: 7, count: 32).base64EncodedString()
    private let oldKey = Data(repeating: 9, count: 32).base64EncodedString()
    private let status = AppAttestStatus(osVersion: "27.0", osBuild: "test", appVersion: "0.9.8", chip: "test", binaryHash: String(repeating: "b", count: 64))

    private func request(_ action: String, key: String? = nil) -> AppAttestShadowPayload {
        var p = AppAttestShadowPayload(action: action, session: Data(repeating: 3, count: 32).base64EncodedString())
        p.protocolVersion = 2; p.accountScope = String(repeating: "a", count: 64); p.environment = "production"; p.keyID = key
        if action != "prepare" { p.challenge = Data(repeating: 4, count: 32).base64EncodedString() }
        return p
    }

    func testFailedEnrollmentRetiresOldKeyAndRecoversOnFreshKey() async {
        for failure in [ShadowFailure.appleError, .appleInvalidKey, .operationTimeout, .cancelled] {
            let storage = EnrollmentStorage()
            storage.save(ShadowKeyRecord(keyID: oldKey, attested: false, createdAt: Date(timeIntervalSinceNow: -7200)), scope: scope)
            let service = EnrollmentService(enrollmentFailure: failure)
            let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
            let ready = await client.respond(to: request("prepare"), publicKey: endpoint)
            let failed = await client.respond(to: request("attest", key: ready.keyID), publicKey: endpoint, status: status)
            XCTAssertEqual(failed.result, failure.rawValue)
            XCTAssertEqual(storage.load(scope: scope)?.keyID, "")
            await service.allowEnrollment()
            let retried = await client.respond(to: request("prepare"), publicKey: endpoint)
            XCTAssertNotEqual(retried.keyID, oldKey)
            let proof = await client.respond(to: request("attest", key: retried.keyID), publicKey: endpoint, status: status)
            XCTAssertEqual(proof.result, "ok")
            let count = await service.generated(); XCTAssertEqual(count, 1)
        }
    }

    func testFreshFailedKeyCannotBypassPersistentGenerationCooldown() async {
        let storage = EnrollmentStorage(); let service = EnrollmentService(enrollmentFailure: .appleError)
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        let ready = await client.respond(to: request("prepare"), publicKey: endpoint)
        _ = await client.respond(to: request("attest", key: ready.keyID), publicKey: endpoint, status: status)
        let restarted = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        let retry = await restarted.respond(to: request("prepare"), publicKey: endpoint)
        XCTAssertEqual(retry.result, "busy")
        let count = await service.generated(); XCTAssertEqual(count, 1)
    }

    func testInterruptedOneTimeEnrollmentIsNotRetriedAfterProcessRestart() async {
        let storage = EnrollmentStorage(); let service = EnrollmentService()
        var interrupted = ShadowKeyRecord(keyID: oldKey, attested: false, createdAt: Date(timeIntervalSinceNow: -7200))
        interrupted.attestationStartedAt = Date(timeIntervalSinceNow: -60)
        storage.save(interrupted, scope: scope)
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        let ready = await client.respond(to: request("prepare"), publicKey: endpoint)
        XCTAssertEqual(ready.result, "ok"); XCTAssertNotEqual(ready.keyID, oldKey)
        let count = await service.generated(); XCTAssertEqual(count, 1)
    }

    func testLaterPrepareRetiresExpiredCachedProofAndEnrollsAgain() async {
        let storage = EnrollmentStorage(); let service = EnrollmentService()
        var cached = ShadowKeyRecord(keyID: oldKey, attested: true, createdAt: Date(timeIntervalSinceNow: -90000))
        cached.pendingProof = Data("cached-proof".utf8).base64EncodedString()
        cached.pendingEnrollment = "original-enrollment"
        cached.pendingStatus = status
        // Apple's response arrived later than the coordinator saved its
        // transaction. The server can reject expiry while this cache is fresh.
        cached.pendingCreatedAt = Date(timeIntervalSinceNow: -86375)
        storage.save(cached, scope: scope)
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        _ = await client.respond(to: request("prepare"), publicKey: endpoint)
        let replay = await client.respond(to: request("attest", key: oldKey), publicKey: endpoint, status: status)
        XCTAssertEqual(replay.proof, cached.pendingProof)
        XCTAssertEqual(replay.enrollmentSession, cached.pendingEnrollment)
        var calls = await service.calls(); XCTAssertTrue(calls.isEmpty)

        // Model the passage of the server's bounded retry delay by aging the
        // stored timestamp. The next prepare must not retain the expired proof.
        cached.pendingCreatedAt = Date(timeIntervalSinceNow: -86435)
        storage.save(cached, scope: scope)
        let ready = await client.respond(to: request("prepare"), publicKey: endpoint)
        XCTAssertEqual(ready.result, "ok"); XCTAssertNotEqual(ready.keyID, oldKey)
        let replacement = await client.respond(to: request("attest", key: ready.keyID), publicKey: endpoint, status: status)
        XCTAssertEqual(replacement.result, "ok")
        XCTAssertNotEqual(replacement.proof, cached.pendingProof)
        calls = await service.calls(); XCTAssertEqual(calls.count, 1)
        let count = await service.generated(); XCTAssertEqual(count, 1)
    }

    func testBusyEnrollmentPreservesKeyAndClearsUnstartedAttempt() async {
        let storage = EnrollmentStorage(); let service = EnrollmentService(enrollmentFailure: .busy)
        storage.save(ShadowKeyRecord(keyID: oldKey, attested: false, createdAt: Date(timeIntervalSinceNow: -7200)), scope: scope)
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        _ = await client.respond(to: request("prepare"), publicKey: endpoint)
        _ = await client.respond(to: request("attest", key: oldKey), publicKey: endpoint, status: status)
        XCTAssertEqual(storage.load(scope: scope)?.keyID, oldKey)
        XCTAssertNil(storage.load(scope: scope)?.attestationStartedAt)
    }

    func testAssertionErrorDoesNotRotateAcceptedCredential() async {
        let storage = EnrollmentStorage(); let service = EnrollmentService(assertionFailure: .appleError)
        storage.save(ShadowKeyRecord(keyID: oldKey, attested: true, createdAt: Date(timeIntervalSinceNow: -7200)), scope: scope)
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        _ = await client.respond(to: request("prepare"), publicKey: endpoint)
        let failed = await client.respond(to: request("assert", key: oldKey), publicKey: endpoint, status: status)
        XCTAssertEqual(failed.result, "apple_error")
        XCTAssertEqual(storage.load(scope: scope)?.keyID, oldKey)
        let count = await service.generated(); XCTAssertEqual(count, 0)
    }

    func testAttemptPersistenceFailureDoesNotCallAppleOrRetireKey() async {
        let storage = FailingEnrollmentStorage(failOnRetirement: false)
        storage.backing.save(ShadowKeyRecord(keyID: oldKey, attested: false, createdAt: Date(timeIntervalSinceNow: -7200)), scope: scope)
        let service = EnrollmentService()
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        _ = await client.respond(to: request("prepare"), publicKey: endpoint)
        let failed = await client.respond(to: request("attest", key: oldKey), publicKey: endpoint, status: status)
        XCTAssertEqual(failed.result, "keychain_error")
        XCTAssertEqual(storage.load(scope: scope)?.keyID, oldKey)
        XCTAssertNil(storage.load(scope: scope)?.attestationStartedAt)
        let calls = await service.calls(); XCTAssertTrue(calls.isEmpty)
    }

    func testRetirementWriteFailureIsReportedAndInterruptedMarkerRecovers() async {
        let storage = FailingEnrollmentStorage(failOnRetirement: true)
        storage.backing.save(ShadowKeyRecord(keyID: oldKey, attested: false, createdAt: Date(timeIntervalSinceNow: -7200)), scope: scope)
        let service = EnrollmentService(enrollmentFailure: .appleError)
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        _ = await client.respond(to: request("prepare"), publicKey: endpoint)
        let failed = await client.respond(to: request("attest", key: oldKey), publicKey: endpoint, status: status)
        XCTAssertEqual(failed.result, "keychain_error")
        XCTAssertEqual(storage.load(scope: scope)?.keyID, oldKey)
        XCTAssertNotNil(storage.load(scope: scope)?.attestationStartedAt)
        let restarted = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        let ready = await restarted.respond(to: request("prepare"), publicKey: endpoint)
        XCTAssertEqual(ready.result, "ok"); XCTAssertNotEqual(ready.keyID, oldKey)
        let calls = await service.calls(); XCTAssertEqual(calls.count, 1)
    }

    func testServerUnavailableRetriesSameKeyAndHashWithoutRetirement() async {
        let storage = EnrollmentStorage(); let service = EnrollmentService()
        await service.failNatively(AppleAppAttestFailure(NSError(domain: DCErrorDomain, code: DCError.Code.serverUnavailable.rawValue)))
        storage.save(ShadowKeyRecord(keyID: oldKey, attested: false, createdAt: Date(timeIntervalSinceNow: -7200)), scope: scope)
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        _ = await client.respond(to: request("prepare"), publicKey: endpoint)
        let failed = await client.respond(to: request("attest", key: oldKey), publicKey: endpoint, status: status)
        XCTAssertEqual(failed.result, "apple_unavailable")
        XCTAssertEqual(failed.appleError?.domain, "devicecheck")
        XCTAssertEqual(failed.appleError?.code, DCError.Code.serverUnavailable.rawValue)
        XCTAssertEqual(storage.load(scope: scope)?.keyID, oldKey)
        XCTAssertNil(storage.load(scope: scope)?.attestationStartedAt)
        let calls = await service.calls(); XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls.allSatisfy { $0.0 == oldKey && $0.1 == calls[0].1 })
        let count = await service.generated(); XCTAssertEqual(count, 0)
    }

    func testUnavailableEnrollmentKeepsOriginalHashAcrossRestartAndProtocolUpgrade() async {
        let storage = EnrollmentStorage(); let service = EnrollmentService(enrollmentFailure: .appleUnavailable)
        storage.save(ShadowKeyRecord(keyID: oldKey, attested: false, createdAt: Date(timeIntervalSinceNow: -7200)), scope: scope)
        let first = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        _ = await first.respond(to: request("prepare"), publicKey: endpoint)
        let unavailable = await first.respond(to: request("attest", key: oldKey), publicKey: endpoint, status: status)
        XCTAssertEqual(unavailable.result, "apple_unavailable")
        await service.allowEnrollment()
        let restarted = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        let newEndpoint = Data(repeating: 8, count: 32).base64EncodedString()
        var prepare = request("prepare")
        prepare.session = Data(repeating: 11, count: 32).base64EncodedString()
        prepare.protocolVersion = 3
        let ready = await restarted.respond(to: prepare, publicKey: newEndpoint)
        var retry = request("attest", key: ready.keyID)
        retry.session = prepare.session; retry.protocolVersion = 3
        retry.challenge = Data(repeating: 12, count: 32).base64EncodedString()
        var newStatus = status; newStatus.appVersion = "0.9.9"
        let recovered = await restarted.respond(to: retry, publicKey: newEndpoint, status: newStatus)
        XCTAssertEqual(recovered.result, "ok")
        XCTAssertEqual(recovered.enrollmentSession, request("attest").session)
        XCTAssertEqual(recovered.status, status)
        let calls = await service.calls(); XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.allSatisfy { $0.0 == oldKey && $0.1 == calls[0].1 })
        let count = await service.generated(); XCTAssertEqual(count, 0)
        retry.action = "assert"
        retry.challenge = Data(repeating: 13, count: 32).base64EncodedString()
        let asserted = await restarted.respond(to: retry, publicKey: newEndpoint, status: newStatus)
        XCTAssertEqual(asserted.result, "ok"); XCTAssertEqual(asserted.status, newStatus)
        retry.status = newStatus
        let assertions = await service.assertions(); XCTAssertEqual(assertions.count, 1)
        XCTAssertEqual(assertions[0].1, retry.clientHash(publicKey: newEndpoint))
        XCTAssertNotEqual(assertions[0].1, calls[0].1)
        XCTAssertNil(storage.load(scope: scope)?.retryEnrollment)
    }

    func testCancellationDuringUnavailableBackoffKeepsRetryableKey() async throws {
        let storage = EnrollmentStorage(); let service = EnrollmentService(enrollmentFailure: .appleUnavailable)
        storage.save(ShadowKeyRecord(keyID: oldKey, attested: false, createdAt: Date()), scope: scope)
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        _ = await client.respond(to: request("prepare"), publicKey: endpoint)
        let enrollmentRequest = request("attest", key: oldKey)
        let callEndpoint = endpoint, callStatus = status
        let task = Task { await client.respond(to: enrollmentRequest, publicKey: callEndpoint, status: callStatus) }
        // Observe the first failed call during its two-second retry backoff.
        // Bound the wait so a broken implementation cannot hang this test.
        let deadline = Date(timeIntervalSinceNow: 1)
        while Date() < deadline {
            let calls = await service.calls()
            if calls.count == 1 && storage.load(scope: scope)?.attestationStartedAt == nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.result, "cancelled")
        XCTAssertEqual(storage.load(scope: scope)?.keyID, oldKey)
        XCTAssertNil(storage.load(scope: scope)?.attestationStartedAt)
        await service.allowEnrollment()
        let restarted = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        var prepare = request("prepare"); prepare.session = Data(repeating: 21, count: 32).base64EncodedString()
        let ready = await restarted.respond(to: prepare, publicKey: endpoint)
        XCTAssertEqual(ready.result, "ok"); XCTAssertEqual(ready.keyID, oldKey)
        var retry = request("attest", key: ready.keyID); retry.session = prepare.session
        let proof = await restarted.respond(to: retry, publicKey: endpoint, status: status)
        XCTAssertEqual(proof.result, "ok")
        let calls = await service.calls(); XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.1 == calls[0].1 })
        let count = await service.generated(); XCTAssertEqual(count, 0)
    }

    func testExpiredOrInvalidRetryTranscriptIsRetiredBeforeAppleUse() async {
        for scenario in ["expired", "future", "wrong key", "short hash", "legacy session"] {
            let storage = EnrollmentStorage(); let service = EnrollmentService()
            var key = ShadowKeyRecord(keyID: oldKey, attested: false, createdAt: Date(timeIntervalSinceNow: -90000))
            key.retryEnrollment = ShadowEnrollmentAttempt(
                keyID: scenario == "wrong key" ? "different" : oldKey,
                clientHash: Data(repeating: 1, count: scenario == "short hash" ? 31 : 32),
                session: Data(repeating: 17, count: 32).base64EncodedString(),
                protocolVersion: scenario == "legacy session" ? 1 : 2, status: status,
                createdAt: Date(timeIntervalSinceNow: scenario == "expired" ? -86401 : scenario == "future" ? 3600 : -60))
            storage.save(key, scope: scope)
            let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
            let ready = await client.respond(to: request("prepare"), publicKey: endpoint)
            XCTAssertEqual(ready.result, "ok", scenario)
            XCTAssertNotEqual(ready.keyID, oldKey, scenario)
            let calls = await service.calls(); XCTAssertTrue(calls.isEmpty, scenario)
            let count = await service.generated(); XCTAssertEqual(count, 1, scenario)
        }
    }

    func testReplacementRespectsSharedGenerationBudgetAcrossAccounts() async {
        let storage = EnrollmentStorage(); let service = EnrollmentService()
        var retired = ShadowKeyRecord(keyID: "", attested: false, createdAt: Date(timeIntervalSinceNow: -7200))
        retired.retireEnrollment(); storage.save(retired, scope: scope)
        var budget = ShadowKeyRecord(keyID: "budget", attested: false, createdAt: Date())
        budget.generationCount = 5; storage.save(budget, scope: "test:production:generation-budget")
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        let reply = await client.respond(to: request("prepare"), publicKey: endpoint)
        XCTAssertEqual(reply.result, "busy")
        let count = await service.generated(); XCTAssertEqual(count, 0)
    }

    func testAppleDiagnosticsRetainCodesWithoutUnboundedStringsOrUserInfo() throws {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -34018, userInfo: [NSLocalizedDescriptionKey: "private device details"])
        let error = NSError(domain: DCErrorDomain, code: DCError.Code.invalidInput.rawValue, userInfo: [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: "private key details"])
        let failure = AppleAppAttestFailure(error)
        XCTAssertEqual(failure.failure, .appleError)
        let data = try JSONEncoder().encode(failure.details)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["domain"] as? String, "devicecheck")
        XCTAssertEqual(object["code"] as? Int, DCError.Code.invalidInput.rawValue)
        XCTAssertEqual(object["underlying_domain"] as? String, "osstatus")
        XCTAssertEqual(object["underlying_code"] as? Int, -34018)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
        XCTAssertEqual(AppAttestAppleError(NSError(domain: "private.example", code: 1)).domain, "other")
        XCTAssertFalse(shouldRetireEnrollmentKey(after: .appleUnavailable))
    }
}
