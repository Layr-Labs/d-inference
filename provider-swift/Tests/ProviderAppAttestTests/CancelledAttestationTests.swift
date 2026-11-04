import Foundation
import XCTest
@testable import ProviderAppAttest

private final class AttestationKeys: ShadowKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ShadowKeyRecord] = [:]
    func load(scope: String) -> ShadowKeyRecord? { lock.withLock { values[scope] } }
    func save(_ record: ShadowKeyRecord, scope: String) { lock.withLock { values[scope] = record } }
}

/// Apple's side of the calls. Keys and assertions answer at once; each
/// attestation answers `delay` seconds after it starts, or, with no delay,
/// only when the test answers it.
private final class AttestingApple: AppAttestCallbacks, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: Double?
    private var started: [(keyID: String, hash: Data)] = []
    private var waiting: [@Sendable (Result<Data, Error>) -> Void] = []
    private var answered = 0
    private var generated = 0

    init(answeringAttestationsAfter delay: Double?) { self.delay = delay }

    func generateKey(_ complete: @escaping @Sendable (Result<String, Error>) -> Void) {
        let count = lock.withLock { generated += 1; return generated }
        complete(.success(Data(repeating: UInt8(count), count: 32).base64EncodedString()))
    }

    func attestKey(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {
        lock.withLock { started.append((id, hash)) }
        let answer: @Sendable (Result<Data, Error>) -> Void = { [self] result in
            lock.withLock { answered += 1 }
            complete(result)
        }
        guard let delay else { lock.withLock { waiting.append(answer) }; return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { answer(.success(Data("attestation-\(id)".utf8))) }
    }

    func generateAssertion(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {
        complete(.success(Data("assertion".utf8)))
    }

    /// Answers every attestation still waiting, as a late Apple callback would.
    func answerWaitingAttestations(_ result: Result<Data, Error>) {
        let answers = lock.withLock { () -> [@Sendable (Result<Data, Error>) -> Void] in
            defer { waiting = [] }
            return waiting
        }
        for answer in answers { answer(result) }
    }

    var attestations: [(keyID: String, hash: Data)] { lock.withLock { started } }
    var answers: Int { lock.withLock { answered } }
    var generatedKeys: Int { lock.withLock { generated } }
}

/// Availability passes; key calls go through the real Apple adapter and its
/// callback deadline.
private actor AvailableApple: AppAttestService {
    private let apple: AppleAppAttestService
    init(_ callbacks: AttestingApple, deadline: Double) {
        apple = AppleAppAttestService(callbacks: callbacks, operationTimeout: deadline)
    }
    func checkAvailability(environment: String) {}
    func generateKey() async throws -> String { try await apple.generateKey() }
    func attestKey(_ id: String, hash: Data) async throws -> Data { try await apple.attestKey(id, hash: hash) }
    func generateAssertion(_ id: String, hash: Data) async throws -> Data { try await apple.generateAssertion(id, hash: hash) }
    func operationHeldSince() async -> Date? { await apple.operationHeldSince() }
}

/// Apple attests a key once. An exchange cancelled by a connection end must not
/// throw away an answer Apple is already producing: the key would be retired,
/// and its replacement would wait out the one-hour generation rule.
final class CancelledAttestationTests: XCTestCase {
    private let scope = "test:production:account:" + String(repeating: "a", count: 64)
    private let endpoint = Data(repeating: 7, count: 32).base64EncodedString()
    private let status = AppAttestStatus(osVersion: "27.2.0", osBuild: "test", appVersion: "0.10.7", chip: "test",
                                         binaryHash: String(repeating: "b", count: 64))

    private func request(_ action: String, session: UInt8 = 3, key: String? = nil) -> AppAttestShadowPayload {
        var p = AppAttestShadowPayload(action: action, session: Data(repeating: session, count: 32).base64EncodedString())
        p.protocolVersion = 3; p.accountScope = String(repeating: "a", count: 64); p.environment = "production"; p.keyID = key
        if action != "prepare" { p.challenge = Data(repeating: 4, count: 32).base64EncodedString() }
        return p
    }

    private func client(_ apple: AttestingApple, _ storage: AttestationKeys, deadline: Double = 25) -> AppAttestShadowClient {
        AppAttestShadowClient(scope: "test", service: AvailableApple(apple, deadline: deadline), storage: storage)
    }

    private func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("not reached within \(seconds) s") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Starts `attest` for `key` the way the serve loop does: in a task that a
    /// connection end cancels. Returns once Apple has the call.
    private func startAttestation(_ client: AppAttestShadowClient, _ apple: AttestingApple,
                                  key: String) async throws -> (request: AppAttestShadowPayload, exchange: Task<AppAttestShadowPayload, Never>) {
        let attest = request("attest", key: key)
        let publicKey = endpoint, status = self.status
        let exchange = Task { await client.respond(to: attest, publicKey: publicKey, status: status) }
        try await waitUntil { apple.attestations.count == 1 }
        return (attest, exchange)
    }

    func testConnectionEndKeepsApplesAttestationForTheNextConnection() async throws {
        let storage = AttestationKeys(), apple = AttestingApple(answeringAttestationsAfter: 1)
        let client = client(apple, storage)
        let ready = await client.respond(to: request("prepare"), publicKey: endpoint)
        let key = try XCTUnwrap(ready.keyID)
        let (attest, exchange) = try await startAttestation(client, apple, key: key)
        try await Task.sleep(nanoseconds: 200_000_000)
        exchange.cancel()
        _ = await exchange.value
        try await waitUntil { apple.answers == 1 }

        let stored = try XCTUnwrap(storage.load(scope: scope))
        XCTAssertEqual(stored.keyID, key, "Apple answered, so the key is not retired")
        XCTAssertTrue(stored.attested)
        XCTAssertEqual(stored.pendingProof, Data("attestation-\(key)".utf8).base64EncodedString())
        XCTAssertEqual(stored.pendingEnrollment, attest.session)
        XCTAssertEqual(stored.pendingStatus, status)
        XCTAssertNil(stored.attestationStartedAt)
        XCTAssertNil(stored.retryEnrollment)

        // The next connection: a new session, and a newer status than the one Apple attested.
        let next = await client.respond(to: request("prepare", session: 4), publicKey: endpoint)
        XCTAssertEqual(next.result, "ok")
        XCTAssertEqual(next.keyID, key)
        var newer = status; newer.appVersion = "0.10.8"
        let replay = await client.respond(to: request("attest", session: 4, key: key), publicKey: endpoint, status: newer)
        XCTAssertEqual(replay.result, "ok")
        XCTAssertEqual(replay.proof, stored.pendingProof)
        // The proof stays bound to the transcript Apple attested.
        XCTAssertEqual(replay.enrollmentSession, attest.session)
        XCTAssertEqual(replay.status, status)
        var signed = attest; signed.status = status
        XCTAssertEqual(apple.attestations.map { $0.hash }, [signed.clientHash(publicKey: endpoint)])
        XCTAssertEqual(apple.attestations.map { $0.keyID }, [key])
        XCTAssertEqual(apple.generatedKeys, 1)
    }

    func testAttestationCutOffByAProcessExitIsStillRetired() async throws {
        let storage = AttestationKeys(), unanswered = AttestingApple(answeringAttestationsAfter: nil)
        let exiting = client(unanswered, storage)
        let ready = await exiting.respond(to: request("prepare"), publicKey: endpoint)
        let key = try XCTUnwrap(ready.keyID)
        let (_, abandoned) = try await startAttestation(exiting, unanswered, key: key)
        XCTAssertNotNil(storage.load(scope: scope)?.attestationStartedAt)
        XCTAssertNil(storage.load(scope: scope)?.pendingProof)

        // A new process (fresh client, same Keychain) cannot learn what Apple answered.
        let apple = AttestingApple(answeringAttestationsAfter: 0)
        let restarted = client(apple, storage)
        let next = await restarted.respond(to: request("prepare", session: 4), publicKey: endpoint)
        XCTAssertEqual(next.result, "busy")
        let retired = try XCTUnwrap(storage.load(scope: scope))
        XCTAssertEqual(retired.keyID, "")
        XCTAssertEqual(apple.generatedKeys, 0, "the replacement waits out the hour")
        XCTAssertTrue(apple.attestations.isEmpty)
        let local = await restarted.currentLocalStatus()
        XCTAssertEqual(local?.key?.recordPresent, false)
        XCTAssertEqual(try XCTUnwrap(local?.key?.generationBlockedUntil),
                       retired.createdAt.addingTimeInterval(KeyGenerationBudget.window).timeIntervalSince1970, accuracy: 0.001)

        // The exited process's call ended with it; release this stand-in.
        unanswered.answerWaitingAttestations(.failure(ShadowFailure.appleError))
        _ = await abandoned.value
        XCTAssertEqual(storage.load(scope: scope)?.keyID, "")
    }

    func testAppleTimeoutStillRetiresTheKey() async throws {
        for cancelled in [false, true] {
            let storage = AttestationKeys(), apple = AttestingApple(answeringAttestationsAfter: nil)
            let client = client(apple, storage, deadline: 0.3)
            let ready = await client.respond(to: request("prepare"), publicKey: endpoint)
            let key = try XCTUnwrap(ready.keyID)
            let (_, exchange) = try await startAttestation(client, apple, key: key)
            if cancelled { exchange.cancel() }
            let reply = await exchange.value
            if !cancelled { XCTAssertEqual(reply.result, "operation_timeout") }
            try await waitUntil { storage.load(scope: scope)?.keyID == "" }
            XCTAssertNil(storage.load(scope: scope)?.pendingProof, "cancelled: \(cancelled)")

            let next = await client.respond(to: request("prepare", session: 4), publicKey: endpoint)
            XCTAssertEqual(next.result, "busy", "the one-hour replacement rule, cancelled: \(cancelled)")
            XCTAssertEqual(apple.generatedKeys, 1)
            // A late answer after the deadline is not taken.
            apple.answerWaitingAttestations(.success(Data("late".utf8)))
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(storage.load(scope: scope)?.keyID, "", "cancelled: \(cancelled)")
            XCTAssertNil(storage.load(scope: scope)?.pendingProof)
            XCTAssertEqual(apple.attestations.count, 1)
        }
    }

    /// The wait a planned stop uses: true at once with nothing at Apple, false
    /// at its bound while Apple has not answered, true once the answer is kept.
    func testOutstandingAttestationWaitIsBounded() async throws {
        let storage = AttestationKeys(), apple = AttestingApple(answeringAttestationsAfter: nil)
        let client = client(apple, storage)
        let idle = await client.waitForOutstandingAttestation(atMostSeconds: 0)
        XCTAssertTrue(idle)
        let ready = await client.respond(to: request("prepare"), publicKey: endpoint)
        let key = try XCTUnwrap(ready.keyID)
        let (_, exchange) = try await startAttestation(client, apple, key: key)
        exchange.cancel()
        let started = Date()
        let unanswered = await client.waitForOutstandingAttestation(atMostSeconds: 0.2)
        XCTAssertFalse(unanswered)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        apple.answerWaitingAttestations(.success(Data("attestation-\(key)".utf8)))
        let answered = await client.waitForOutstandingAttestation(atMostSeconds: 5)
        XCTAssertTrue(answered)
        XCTAssertEqual(storage.load(scope: scope)?.pendingProof, Data("attestation-\(key)".utf8).base64EncodedString())
        _ = await exchange.value
    }

    func testNextConnectionWaitsForTheOutstandingAttestationInsteadOfAskingAppleAgain() async throws {
        let storage = AttestationKeys(), apple = AttestingApple(answeringAttestationsAfter: 1)
        let client = client(apple, storage)
        let ready = await client.respond(to: request("prepare"), publicKey: endpoint)
        let key = try XCTUnwrap(ready.keyID)
        let (attest, exchange) = try await startAttestation(client, apple, key: key)
        try await Task.sleep(nanoseconds: 200_000_000)
        exchange.cancel()

        // The next connection's prepare arrives while Apple is still attesting.
        let next = await client.respond(to: request("prepare", session: 4), publicKey: endpoint)
        XCTAssertEqual(apple.answers, 1, "the prepare waited for Apple's answer")
        XCTAssertEqual(next.result, "ok")
        XCTAssertEqual(next.keyID, key)
        let replay = await client.respond(to: request("attest", session: 4, key: key), publicKey: endpoint, status: status)
        XCTAssertEqual(replay.result, "ok")
        XCTAssertEqual(replay.enrollmentSession, attest.session)
        XCTAssertEqual(apple.attestations.count, 1, "one attestKey for the key")
        XCTAssertEqual(apple.generatedKeys, 1)
        _ = await exchange.value
    }
}
