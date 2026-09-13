import Foundation
import XCTest
@testable import ProviderAppAttest

private actor FakeService: AppAttestService {
    var generated = 0
    var attested = 0
    var asserted = 0
    var failure: ShadowFailure?
    init(failure: ShadowFailure? = nil) { self.failure = failure }
    func checkAvailability(environment: String) throws { if let failure { throw failure } }
    func generateKey() -> String { generated += 1; return Data(repeating: 1, count: 32).base64EncodedString() }
    func attestKey(_ id: String, hash: Data) -> Data { attested += 1; return Data("attestation".utf8) }
    func generateAssertion(_ id: String, hash: Data) -> Data { asserted += 1; return Data("assertion".utf8) }
    func counts() -> [Int] { [generated, attested, asserted] }
}

private final class MemoryKeys: ShadowKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ShadowKeyRecord] = [:]
    func load(scope: String) -> ShadowKeyRecord? { lock.lock(); defer { lock.unlock() }; return records[scope] }
    func save(_ record: ShadowKeyRecord, scope: String) { lock.lock(); defer { lock.unlock() }; records[scope] = record }
}

private struct UnwritableKeys: ShadowKeyStorage {
    func load(scope: String) -> ShadowKeyRecord? { nil }
    func save(_ record: ShadowKeyRecord, scope: String) throws { throw ShadowFailure.keychainError }
}

final class AppAttestShadowTests: XCTestCase {
    let session = Data(repeating: 0, count: 32).base64EncodedString()
    let publicKey = Data(repeating: 3, count: 32).base64EncodedString()

    func request(_ action: String, key: String? = nil) -> AppAttestShadowPayload {
        var p = AppAttestShadowPayload(action: action, session: session)
        p.environment = "production"; p.keyID = key
        if action != "prepare" { p.challenge = Data(repeating: 2, count: 32).base64EncodedString() }
        return p
    }

    func testUnwritableKeychainDoesNotCreateKeys() async {
        let service = FakeService()
        let client = AppAttestShadowClient(scope: "test", service: service, storage: UnwritableKeys())
        let response = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(response.result, "keychain_error")
        let counts = await service.counts(); XCTAssertEqual(counts, [0, 0, 0])
    }

    func testUnsupportedDoesNotCreateKeys() async {
        let service = FakeService(failure: .unsupported)
        let client = AppAttestShadowClient(scope: "test", service: service, storage: MemoryKeys())
        let response = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(response.result, "unsupported")
        let counts = await service.counts(); XCTAssertEqual(counts, [0, 0, 0])
    }

    func testPersistentKeySurvivesReconnectAndOnlyAttestsOnce() async {
        let service = FakeService(); let storage = MemoryKeys()
        let client = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        let ready = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(ready.result, "ok")
        let proof = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey)
        XCTAssertEqual(proof.result, "ok")
        let assertion = await client.respond(to: request("assert", key: ready.keyID), publicKey: publicKey)
        XCTAssertEqual(assertion.result, "ok")
        let restarted = AppAttestShadowClient(scope: "test", service: service, storage: storage)
        let next = await restarted.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(next.keyID, ready.keyID)
        let nextProof = await restarted.respond(to: request("assert", key: next.keyID), publicKey: publicKey)
        XCTAssertEqual(nextProof.result, "ok")
        let counts = await service.counts(); XCTAssertEqual(counts, [1, 1, 2])
    }

    func testWrongSessionOrKeyCannotSign() async {
        let service = FakeService()
        let client = AppAttestShadowClient(scope: "test", service: service, storage: MemoryKeys())
        let ready = await client.respond(to: request("prepare"), publicKey: publicKey)
        var bad = request("assert", key: ready.keyID); bad.session = Data(repeating: 9, count: 32).base64EncodedString()
        let response = await client.respond(to: bad, publicKey: publicKey)
        XCTAssertEqual(response.result, "invalid_request")
        bad = request("assert", key: Data(repeating: 8, count: 32).base64EncodedString())
        let other = await client.respond(to: bad, publicKey: publicKey)
        XCTAssertEqual(other.result, "invalid_request")
        let counts = await service.counts(); XCTAssertEqual(counts, [1, 0, 0])
    }

    func testUnknownEnrolledKeyCannotCauseRapidKeyChurn() async {
        let service = FakeService()
        let client = AppAttestShadowClient(scope: "test", service: service, storage: MemoryKeys())
        let ready = await client.respond(to: request("prepare"), publicKey: publicKey)
        _ = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey)
        let retry = await client.respond(to: request("attest", key: ready.keyID), publicKey: publicKey)
        XCTAssertEqual(retry.result, "key_unregistered")
        let prepared = await client.respond(to: request("prepare"), publicKey: publicKey)
        XCTAssertEqual(prepared.result, "busy")
        let counts = await service.counts(); XCTAssertEqual(counts, [1, 1, 0])
    }

    func testTranscriptMatchesGoVectorAndBindsEndpoint() throws {
        let p = request("assert", key: Data(repeating: 1, count: 32).base64EncodedString())
        let hash = p.clientHash(publicKey: publicKey).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "6961d03f72d47b5e4d66746d590a82fabfca7a9fd4de48a05bfcef5c1e850449")
        XCTAssertNotEqual(p.clientHash(publicKey: publicKey), p.clientHash(publicKey: Data(repeating: 4, count: 32).base64EncodedString()))
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(AppAttestShadowPayload.self, from: data), p)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["encrypted_challenge"])
        XCTAssertNotNil(object["key_id"])
    }
}
