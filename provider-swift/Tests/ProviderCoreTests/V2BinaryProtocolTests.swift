import Foundation
import Testing

@testable import ProviderCore

@Suite("Protocol v2 binary Rust layout")
struct V2BinaryProtocolTests {
    @Test("192-byte header offsets and network byte order are exact")
    func rustHeaderGolden() throws {
        let encoded = try header(ciphertextLength: 0x00ff_0102).encode()
        #expect(encoded.count == 192)
        #expect(encoded.subdata(in: 0..<4) == Data("DBV2".utf8))
        #expect(encoded[4] == 2)
        #expect(encoded[5] == 3)
        #expect(encoded.subdata(in: 6..<8) == Data([0x00, 0xc0]))
        #expect(encoded.subdata(in: 8..<10) == Data([0x00, 0x02]))
        #expect(encoded.subdata(in: 10..<12) == Data([0x11, 0x22]))
        #expect(encoded.subdata(in: 12..<28) == Data(repeating: 0x10, count: 16))
        #expect(encoded.subdata(in: 28..<44) == Data(repeating: 0x20, count: 16))
        #expect(encoded.subdata(in: 44..<52) == Data([1, 2, 3, 4, 5, 6, 7, 8]))
        #expect(encoded.subdata(in: 52..<68) == Data(repeating: 0x30, count: 16))
        #expect(encoded.subdata(in: 68..<84) == Data(repeating: 0x40, count: 16))
        #expect(encoded.subdata(in: 84..<100) == Data(repeating: 0x50, count: 16))
        #expect(encoded.subdata(in: 100..<116) == Data(repeating: 0x60, count: 16))
        #expect(encoded.subdata(in: 116..<140) == Data(repeating: 0x70, count: 24))
        #expect(encoded.subdata(in: 140..<172) == Data(repeating: 0x80, count: 32))
        #expect(
            encoded.subdata(in: 172..<180)
                == Data([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18]))
        #expect(encoded.subdata(in: 180..<184) == Data([0x00, 0xff, 0x01, 0x02]))
        #expect(
            encoded.subdata(in: 184..<192)
                == Data([0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28]))
        #expect(
            try V2BinaryFrameHeader.decode(encoded)
                == header(ciphertextLength: 0x00ff_0102))
    }

    @Test("malformed, unknown, reserved, and oversized headers fail closed")
    func malformedHeaders() throws {
        let valid = try header().encode()
        for length in 0..<v2BinaryHeaderLength {
            do {
                _ = try V2BinaryFrame.decode(valid.subdata(in: 0..<length))
                Issue.record("accepted truncation at \(length)")
            } catch {
                // Every truncation is rejected.
            }
        }

        var invalidMagic = valid
        invalidMagic[0] = UInt8(ascii: "X")
        #expect(throws: V2ProtocolError.invalidMagic) {
            _ = try V2BinaryFrame.decode(invalidMagic)
        }

        var invalidHeaderLength = valid
        invalidHeaderLength[7] = 0
        #expect(throws: V2ProtocolError.invalidHeaderLength(0)) {
            _ = try V2BinaryFrame.decode(invalidHeaderLength)
        }

        var unsupportedMajor = valid
        unsupportedMajor[9] = 0
        #expect(throws: V2ProtocolError.unsupportedMajor(0)) {
            _ = try V2BinaryFrame.decode(unsupportedMajor)
        }

        var unknownKind = valid
        unknownKind[4] = 0xff
        #expect(throws: V2ProtocolError.unknownFrameKind(0xff)) {
            _ = try V2BinaryFrame.decode(unknownKind)
        }

        var unknownFlags = valid
        unknownFlags[5] = 0x80
        #expect(throws: V2ProtocolError.unknownFrameFlags(0x80)) {
            _ = try V2BinaryFrame.decode(unknownFlags)
        }

        var oversized = valid
        oversized.replaceSubrange(180..<184, with: Data(repeating: 0xff, count: 4))
        #expect(
            throws: V2ProtocolError.ciphertextTooLarge(
                actual: Int(UInt32.max),
                maximum: maximumV2CiphertextLength
            )
        ) {
            _ = try V2BinaryFrame.decode(oversized)
        }
    }

    @Test("complete frame requires its exact declared length")
    func exactLength() throws {
        let ciphertext = Data("ciphertext".utf8)
        let expectedHeader = try header(ciphertextLength: UInt32(ciphertext.count))
        let wire = try V2BinaryFrame(
            header: expectedHeader,
            ciphertext: ciphertext
        ).encode()
        let decoded = try V2BinaryFrame.decode(wire)
        #expect(decoded.header == expectedHeader)
        #expect(decoded.ciphertext == ciphertext)

        var trailing = wire
        trailing.append(0)
        #expect(throws: (any Error).self) {
            _ = try V2BinaryFrame.decode(trailing)
        }
        #expect(throws: (any Error).self) {
            _ = try V2BinaryFrame.decode(wire.dropLastData())
        }
    }

    @Test("NaCl Box authenticates the exact inner and outer header")
    func authenticatedHeaderBinding() throws {
        let senderSecret = Data((1...32).map(UInt8.init))
        let recipientSecret = Data((101...132).map(UInt8.init))
        let sender = try NodeKeyPair(rawSecret: senderSecret)
        let recipient = try NodeKeyPair(rawSecret: recipientSecret)
        let plaintext = Data("bound application plaintext".utf8)

        let wire = try V2FrameCrypto.seal(
            senderPrivateKey: senderSecret,
            recipientPublicKey: recipient.publicKeyBytes,
            header: header(),
            plaintext: plaintext
        )
        let opened = try V2FrameCrypto.open(
            recipientPrivateKey: recipientSecret,
            senderPublicKey: sender.publicKeyBytes,
            wire: wire
        )
        #expect(opened.plaintext == plaintext)

        // Each mutation remains syntactically valid and raw NaCl Box still
        // authenticates because Box has no AAD. The inner/outer equality check
        // must reject every metadata rebind pinned by the Rust vector.
        for (name, offset) in [
            ("kind", 4),
            ("flags", 5),
            ("minor", 11),
            ("provider_id", 12),
            ("process_generation", 28),
            ("session_epoch", 44),
            ("request_id", 52),
            ("attempt_id", 68),
            ("reservation_id", 84),
            ("lease_id", 100),
            ("rolling_digest", 140),
            ("sequence", 172),
            ("cumulative_tokens", 184),
        ] {
            var rebound = wire
            rebound[offset] ^= 1
            do {
                _ = try V2FrameCrypto.open(
                    recipientPrivateKey: recipientSecret,
                    senderPublicKey: sender.publicKeyBytes,
                    wire: rebound
                )
                Issue.record("accepted rebound \(name)")
            } catch V2CryptoError.frameHeaderBindingMismatch {
                // Expected.
            } catch {
                Issue.record("wrong error for rebound \(name): \(error)")
            }
        }

        var tamperedCiphertext = wire
        tamperedCiphertext[tamperedCiphertext.count - 1] ^= 1
        #expect(throws: V2CryptoError.authenticationFailed) {
            _ = try V2FrameCrypto.open(
                recipientPrivateKey: recipientSecret,
                senderPublicKey: sender.publicKeyBytes,
                wire: tamperedCiphertext
            )
        }
    }

    @Test("Swift opens and reproduces the committed Rust encrypted frame vector")
    func rustSwiftEncryptedCrossVector() throws {
        let fixture = try JSONDecoder().decode(
            BoundFrameVector.self,
            from: Data(contentsOf: boundFrameContractURL())
        )
        #expect(fixture.schemaVersion == 2)
        let senderPrivateKey = try #require(
            Data(base64Encoded: fixture.senderPrivateKeyBase64))
        let senderPublicKey = try #require(
            Data(base64Encoded: fixture.senderPublicKeyBase64))
        let recipientPrivateKey = try #require(
            Data(base64Encoded: fixture.recipientPrivateKeyBase64))
        let recipientPublicKey = try #require(
            Data(base64Encoded: fixture.recipientPublicKeyBase64))
        let plaintext = try #require(Data(base64Encoded: fixture.plaintextBase64))
        let expectedWire = try #require(Data(base64Encoded: fixture.wireBase64))

        let sealed = try V2FrameCrypto.seal(
            senderPrivateKey: senderPrivateKey,
            recipientPublicKey: recipientPublicKey,
            header: header(),
            plaintext: plaintext
        )
        #expect(sealed == expectedWire)
        let opened = try V2FrameCrypto.open(
            recipientPrivateKey: recipientPrivateKey,
            senderPublicKey: senderPublicKey,
            wire: expectedWire
        )
        #expect(opened.plaintext == plaintext)
        let expectedHeader = try header(
            ciphertextLength: opened.header.ciphertextLength
        )
        #expect(opened.header == expectedHeader)
    }
}

private struct BoundFrameVector: Decodable {
    let schemaVersion: UInt
    let senderPrivateKeyBase64: String
    let senderPublicKeyBase64: String
    let recipientPrivateKeyBase64: String
    let recipientPublicKeyBase64: String
    let plaintextBase64: String
    let wireBase64: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case senderPrivateKeyBase64 = "sender_private_key_base64"
        case senderPublicKeyBase64 = "sender_public_key_base64"
        case recipientPrivateKeyBase64 = "recipient_private_key_base64"
        case recipientPublicKeyBase64 = "recipient_public_key_base64"
        case plaintextBase64 = "plaintext_base64"
        case wireBase64 = "wire_base64"
    }
}

private func boundFrameContractURL() -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 {
        root.deleteLastPathComponent()
    }
    return
        root
        .appendingPathComponent("tests/contracts")
        .appendingPathComponent("crypto/v2_bound_frame.json")
}

private func header(ciphertextLength: UInt32 = 0) throws -> V2BinaryFrameHeader {
    try V2BinaryFrameHeader(
        kind: .responseChunk,
        flags: .finalFrame | .retransmit,
        minor: 0x1122,
        providerID: ProtocolV2UUID(bytes: Data(repeating: 0x10, count: 16))!,
        providerProcessGeneration: ProtocolV2UUID(
            bytes: Data(repeating: 0x20, count: 16))!,
        sessionEpoch: 0x0102_0304_0506_0708,
        requestID: ProtocolV2UUID(bytes: Data(repeating: 0x30, count: 16))!,
        attemptID: ProtocolV2UUID(bytes: Data(repeating: 0x40, count: 16))!,
        reservationID: ProtocolV2UUID(bytes: Data(repeating: 0x50, count: 16))!,
        leaseID: ProtocolV2UUID(bytes: Data(repeating: 0x60, count: 16))!,
        nonce: Data(repeating: 0x70, count: 24),
        rollingDigest: Data(repeating: 0x80, count: 32),
        sequence: 0x1112_1314_1516_1718,
        ciphertextLength: ciphertextLength,
        cumulativeTokens: 0x2122_2324_2526_2728
    )
}

extension Data {
    fileprivate func dropLastData() -> Data {
        Data(dropLast())
    }
}
