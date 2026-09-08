import CryptoKit
import Foundation
import XCTest
@testable import BootContinuity

final class BootKeySessionTests: XCTestCase {
    func testDisabledAndUnavailableNeverCreateOrRecover() throws {
        let engine = MemoryEngine()
        let context = try makeContext()
        assertError(.disabled) { _ = try BootKeySession.create(context: context, activation: .disabled, engine: engine) }
        assertError(.disabled) { _ = try BootKeySession.recover(record: Data(), context: context, activation: .disabled, engine: engine) }
        engine.isAvailable = false
        assertError(.secureEnclaveUnavailable) { _ = try BootKeySession.create(context: context, activation: .experimental, engine: engine) }
        XCTAssertEqual(engine.creates, 0)
        XCTAssertEqual(engine.recovers, 0)
    }

    func testRecoveryProvesSamePrivateKeyAndBindsEachContextField() throws {
        let engine = MemoryEngine()
        let context = try makeContext()
        let original = try BootKeySession.create(context: context, activation: .experimental, engine: engine)
        let record = try original.storageRecord()
        let recovered = try BootKeySession.recover(record: record, context: context, activation: .experimental, engine: engine)
        XCTAssertEqual(original.publicKey, recovered.publicKey)
        XCTAssertEqual(engine.creates, 1)
        let challenge = try BootContinuationChallenge(nonce: Data(repeating: 1, count: 32), processPublicKey: Data(repeating: 2, count: 32))
        let proof = try recovered.provePossession(challenge)
        let key = try P256.Signing.PublicKey(rawRepresentation: proof.publicKey)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: proof.signatureDER)
        XCTAssertTrue(key.isValidSignature(signature, for: proof.transcript))
        for other in try [makeContext(account: "other"), makeContext(device: "other"),
                          makeContext(origin: "https://other.example"), makeContext(release: "other"), makeContext(generation: 2)] {
            assertError(.contextMismatch) {
                _ = try BootKeySession.recover(record: record, context: other, activation: .experimental, engine: engine)
            }
            let otherTranscript = BootContinuationTranscript.encode(context: other, publicKey: proof.publicKey, challenge: challenge)
            XCTAssertFalse(key.isValidSignature(signature, for: otherTranscript))
        }
        XCTAssertEqual(engine.recovers, 1, "Context rejection must precede hardware access")
    }

    func testUnusableHandleNeverCreatesReplacement() throws {
        let engine = MemoryEngine()
        let context = try makeContext()
        let session = try BootKeySession.create(context: context, activation: .experimental, engine: engine)
        let record = try session.storageRecord()
        engine.keys.removeAll()
        assertError(.keyUnavailable) {
            _ = try BootKeySession.recover(record: record, context: context, activation: .experimental, engine: engine)
        }
        XCTAssertEqual(engine.creates, 1)
    }

    func testRestoredPublicKeyMustMatchAndPrivateOperationMustWork() throws {
        let engine = MemoryEngine()
        let context = try makeContext()
        let session = try BootKeySession.create(context: context, activation: .experimental, engine: engine)
        let data = try session.storageRecord()
        engine.replacement = MemoryKey()
        assertError(.publicKeyMismatch) {
            _ = try BootKeySession.recover(record: data, context: context, activation: .experimental, engine: engine)
        }
        engine.replacement = nil
        engine.keys.values.first?.refuseSigning = true
        assertError(.keyUnavailable) {
            _ = try BootKeySession.recover(record: data, context: context, activation: .experimental, engine: engine)
        }
    }

    func testMalformedOversizedAndUnknownRecordsNeverReachHardware() throws {
        let engine = MemoryEngine()
        let context = try makeContext()
        for data in [Data("{}".utf8), Data(repeating: 0, count: BootKeyRecord.maximumSize + 1)] {
            assertError(.invalidRecord) {
                _ = try BootKeySession.recover(record: data, context: context, activation: .experimental, engine: engine)
            }
        }
        let session = try BootKeySession.create(context: context, activation: .experimental, engine: engine)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: session.storageRecord()) as? [String: Any])
        object["version"] = 99
        let data = try JSONSerialization.data(withJSONObject: object)
        assertError(.unsupportedRecordVersion) {
            _ = try BootKeySession.recover(record: data, context: context, activation: .experimental, engine: engine)
        }
        XCTAssertEqual(engine.recovers, 0)
    }

    func testTranscriptRejectsFieldAmbiguityAndChallengeSubstitution() throws {
        let engine = MemoryEngine()
        let a = try makeContext(account: "ab", device: "c")
        let b = try makeContext(account: "a", device: "bc")
        let session = try BootKeySession.create(context: a, activation: .experimental, engine: engine)
        let challenge = try BootContinuationChallenge(nonce: Data(repeating: 1, count: 32), processPublicKey: Data(repeating: 2, count: 32))
        let proof = try session.provePossession(challenge)
        XCTAssertNotEqual(proof.transcript, BootContinuationTranscript.encode(context: b, publicKey: session.publicKey, challenge: challenge))
        let key = try P256.Signing.PublicKey(rawRepresentation: proof.publicKey)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: proof.signatureDER)
        for changed in try [BootContinuationChallenge(nonce: Data(repeating: 3, count: 32), processPublicKey: challenge.processPublicKey),
                            BootContinuationChallenge(nonce: challenge.nonce, processPublicKey: Data(repeating: 4, count: 32))] {
            XCTAssertFalse(key.isValidSignature(signature, for: BootContinuationTranscript.encode(context: a, publicKey: session.publicKey, challenge: changed)))
        }
        assertError(.invalidChallenge) { _ = try BootContinuationChallenge(nonce: Data(), processPublicKey: Data()) }
        assertError(.invalidContext) { _ = try makeContext(origin: "https://example.test/path") }
    }
}

func makeContext(account: String = "account", device: String = "device", origin: String = "https://example.test",
                 release: String = "release-sha256", generation: UInt64 = 1) throws -> BootContinuityContext {
    try BootContinuityContext(accountID: account, deviceID: device, coordinatorOrigin: origin, releaseID: release, policyGeneration: generation)
}

func assertError(_ error: BootContinuityError, file: StaticString = #filePath, line: UInt = #line, _ operation: () throws -> Void) {
    XCTAssertThrowsError(try operation(), file: file, line: line) {
        XCTAssertEqual($0 as? BootContinuityError, error, file: file, line: line)
    }
}

final class MemoryEngine: BootKeyEngine, @unchecked Sendable {
    var isAvailable = true
    var creates = 0
    var recovers = 0
    var keys: [Data: MemoryKey] = [:]
    var replacement: MemoryKey?

    func create() throws -> any BootHardwareKey {
        creates += 1
        let key = MemoryKey()
        keys[key.opaqueHandle] = key
        return key
    }

    func recover(handle: Data) throws -> any BootHardwareKey {
        recovers += 1
        if let replacement { return replacement }
        guard let key = keys[handle] else { throw BootContinuityError.keyUnavailable }
        return key
    }
}

final class MemoryKey: BootHardwareKey {
    let key = P256.Signing.PrivateKey()
    let opaqueHandle = Data(UUID().uuidString.utf8)
    var refuseSigning = false
    var publicKey: Data { key.publicKey.rawRepresentation }
    func sign(_ message: Data) throws -> Data {
        guard !refuseSigning else { throw BootContinuityError.keyUnavailable }
        return try key.signature(for: message).derRepresentation
    }
}
