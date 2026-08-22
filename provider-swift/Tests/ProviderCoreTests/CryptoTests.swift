import Foundation
import Testing
@testable import ProviderCore

protocol VersionedSecurityFixture: Decodable {
    var schemaVersion: Int { get }
}

enum SecurityFixtureError: Error {
    case unsupportedSchemaVersion(Int)
}

func securityFixtureURL(named name: String) -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 4 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("fixtures/security/v1/\(name)")
}

func decodeSecurityFixture<T: VersionedSecurityFixture>(
    _ type: T.Type,
    from data: Data
) throws -> T {
    let corpus = try JSONDecoder().decode(type, from: data)
    guard corpus.schemaVersion == 1 else {
        throw SecurityFixtureError.unsupportedSchemaVersion(corpus.schemaVersion)
    }
    return corpus
}

private struct EncryptionFixtureCorpus: VersionedSecurityFixture {
    let schemaVersion: Int
    let cases: [EncryptionFixture]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cases
    }
}

private struct EncryptionFixture: Decodable {
    let name: String
    let recipientPrivateKeyHex: String
    let senderPublicKeyBase64: String
    let ciphertextBase64: String
    let plaintextUTF8: String

    enum CodingKeys: String, CodingKey {
        case name
        case recipientPrivateKeyHex = "recipient_private_key_hex"
        case senderPublicKeyBase64 = "sender_public_key_base64"
        case ciphertextBase64 = "ciphertext_base64"
        case plaintextUTF8 = "plaintext_utf8"
    }
}

@Test("NaCl box: decrypt shared cross-language vectors")
func naclBoxDecryptsSharedVectors() throws {
    let corpus = try decodeSecurityFixture(
        EncryptionFixtureCorpus.self,
        from: Data(contentsOf: securityFixtureURL(named: "encryption_vectors.json"))
    )
    #expect(!corpus.cases.isEmpty)
    #expect(Set(corpus.cases.map(\.name)).count == corpus.cases.count)

    for vector in corpus.cases {
        #expect(!vector.name.isEmpty)
        let privateKey = try Data(hexString: vector.recipientPrivateKeyHex)
        let keyPair = try NodeKeyPair(rawSecret: privateKey)
        let senderPublicKey = try #require(Data(base64Encoded: vector.senderPublicKeyBase64))
        let ciphertext = try #require(Data(base64Encoded: vector.ciphertextBase64))

        let decrypted = try keyPair.decrypt(
            senderPublicKey: senderPublicKey,
            ciphertext: ciphertext
        )
        #expect(
            decrypted == Data(vector.plaintextUTF8.utf8),
            "Shared encryption vector '\(vector.name)' drifted"
        )
    }
}

@Test("Security fixture loader rejects encryption schema drift")
func encryptionFixtureRejectsSchemaDrift() {
    for encoded in [
        #"{"cases":[]}"#,
        #"{"schema_version":2,"cases":[]}"#,
    ] {
        #expect(throws: (any Error).self) {
            _ = try decodeSecurityFixture(
                EncryptionFixtureCorpus.self,
                from: Data(encoded.utf8)
            )
        }
    }
}

@Test("NaCl box: Swift encrypt → Swift decrypt round-trip")
func naclBoxSwiftRoundTrip() throws {
    let alice = NodeKeyPair.generate()
    let bob = NodeKeyPair.generate()

    let plaintext = Data("cross-language round-trip test payload".utf8)
    let encrypted = try alice.encrypt(recipientPublicKey: bob.publicKeyBytes, plaintext: plaintext)
    let decrypted = try bob.decrypt(senderPublicKey: alice.publicKeyBytes, ciphertext: encrypted)

    #expect(decrypted == plaintext)
}

@Test("NaCl box: EncryptedPayload wire format round-trip")
func naclBoxPayloadRoundTrip() throws {
    let provider = NodeKeyPair.generate()
    let coordinator = NodeKeyPair.generate()

    let message = Data(#"{"model":"qwen","messages":[{"role":"user","content":"test"}]}"#.utf8)

    let payload = try coordinator.encryptPayload(recipientPublicKey: provider.publicKeyBytes, plaintext: message)

    #expect(!payload.ephemeralPublicKey.isEmpty)
    #expect(!payload.ciphertext.isEmpty)

    let decrypted = try provider.decryptPayload(payload)
    #expect(decrypted == message)
}

@Test("NaCl box: tampered ciphertext fails authentication")
func naclBoxRejectsTamperedCiphertext() throws {
    let alice = NodeKeyPair.generate()
    let bob = NodeKeyPair.generate()

    let plaintext = Data("sensitive data".utf8)
    var encrypted = try alice.encrypt(recipientPublicKey: bob.publicKeyBytes, plaintext: plaintext)

    // Flip a byte in the ciphertext (after the 24-byte nonce)
    encrypted[encrypted.count - 1] ^= 0xFF

    #expect(throws: CryptoError.self) {
        _ = try bob.decrypt(senderPublicKey: alice.publicKeyBytes, ciphertext: encrypted)
    }
}

@Test("NaCl box: wrong key fails decryption")
func naclBoxRejectsWrongKey() throws {
    let alice = NodeKeyPair.generate()
    let bob = NodeKeyPair.generate()
    let eve = NodeKeyPair.generate()

    let plaintext = Data("for bob only".utf8)
    let encrypted = try alice.encrypt(recipientPublicKey: bob.publicKeyBytes, plaintext: plaintext)

    #expect(throws: CryptoError.self) {
        _ = try eve.decrypt(senderPublicKey: alice.publicKeyBytes, ciphertext: encrypted)
    }
}

// MARK: - Hex helper

extension Data {
    init(hexString: String) throws {
        var data = Data()
        var hex = hexString
        while !hex.isEmpty {
            let byte = hex.prefix(2)
            hex = String(hex.dropFirst(2))
            guard let b = UInt8(byte, radix: 16) else {
                throw CryptoError.decryptionFailed
            }
            data.append(b)
        }
        self = data
    }
}
