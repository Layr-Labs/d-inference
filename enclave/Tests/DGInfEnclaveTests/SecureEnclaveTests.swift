import XCTest
@testable import DGInfEnclave

final class SecureEnclaveTests: XCTestCase {

    // MARK: - Secure Enclave availability

    func testSecureEnclaveIsAvailable() {
        // On Apple Silicon Macs, Secure Enclave should be available
        XCTAssertTrue(
            SecureEnclaveIdentity.isAvailable,
            "Secure Enclave should be available on Apple Silicon"
        )
    }

    // MARK: - Key creation

    func testCreateIdentity() throws {
        let identity = try SecureEnclaveIdentity()
        XCTAssertFalse(identity.publicKeyBase64.isEmpty)
        XCTAssertFalse(identity.publicKeyHex.isEmpty)
        // CryptoKit raw representation: X (32 bytes) || Y (32 bytes) = 64 bytes
        XCTAssertEqual(identity.publicKeyRaw.count, 64)
    }

    func testDifferentKeysProduceDifferentPublicKeys() throws {
        let id1 = try SecureEnclaveIdentity()
        let id2 = try SecureEnclaveIdentity()
        XCTAssertNotEqual(
            id1.publicKeyBase64,
            id2.publicKeyBase64,
            "Two independently generated keys must differ"
        )
    }

    // MARK: - Sign / verify

    func testSignAndVerify() throws {
        let identity = try SecureEnclaveIdentity()
        let message = "Hello, DGInf!".data(using: .utf8)!

        let signature = try identity.sign(message)
        XCTAssertFalse(signature.isEmpty)

        let valid = identity.verify(signature: signature, for: message)
        XCTAssertTrue(valid, "Signature should be valid for the original message")

        // Tampered message must fail verification
        let tampered = "Hello, World!".data(using: .utf8)!
        let invalid = identity.verify(signature: signature, for: tampered)
        XCTAssertFalse(invalid, "Tampered message should fail verification")
    }

    func testStaticVerify() throws {
        let identity = try SecureEnclaveIdentity()
        let message = "verify me".data(using: .utf8)!
        let signature = try identity.sign(message)

        let valid = SecureEnclaveIdentity.verify(
            signature: signature,
            for: message,
            publicKey: identity.publicKeyRaw
        )
        XCTAssertTrue(valid)
    }

    func testSignEmptyData() throws {
        let identity = try SecureEnclaveIdentity()
        let empty = Data()
        let sig = try identity.sign(empty)
        XCTAssertTrue(identity.verify(signature: sig, for: empty))
    }

    func testSignLargeData() throws {
        let identity = try SecureEnclaveIdentity()
        let large = Data(repeating: 0xAB, count: 1_000_000)  // 1 MB
        let sig = try identity.sign(large)
        XCTAssertTrue(identity.verify(signature: sig, for: large))
    }

    // MARK: - Persistence

    func testSaveAndLoadIdentity() throws {
        let original = try SecureEnclaveIdentity()
        let data = original.dataRepresentation
        XCTAssertFalse(data.isEmpty)

        // Reload from the opaque data representation
        let loaded = try SecureEnclaveIdentity(dataRepresentation: data)
        XCTAssertEqual(
            original.publicKeyBase64,
            loaded.publicKeyBase64,
            "Loaded identity must have the same public key"
        )

        // Sign with original, verify with loaded — proves it's the same key
        let message = "test data".data(using: .utf8)!
        let sig = try original.sign(message)
        XCTAssertTrue(loaded.verify(signature: sig, for: message))
    }

    // MARK: - Attestation

    func testAttestation() throws {
        let identity = try SecureEnclaveIdentity()
        let service = AttestationService(identity: identity)

        let signed = try service.createAttestation()

        XCTAssertFalse(signed.attestation.publicKey.isEmpty)
        XCTAssertFalse(signed.attestation.hardwareModel.isEmpty)
        XCTAssertFalse(signed.attestation.chipName.isEmpty)
        XCTAssertFalse(signed.attestation.osVersion.isEmpty)
        XCTAssertTrue(signed.attestation.secureEnclaveAvailable)
        XCTAssertFalse(signed.signature.isEmpty)

        let valid = AttestationService.verify(signed)
        XCTAssertTrue(valid, "Attestation signature should verify")
    }

    func testAttestationJSON() throws {
        let identity = try SecureEnclaveIdentity()
        let service = AttestationService(identity: identity)
        let signed = try service.createAttestation()

        // Round-trip through JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(signed)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SignedAttestation.self, from: data)

        XCTAssertEqual(signed.attestation.publicKey, decoded.attestation.publicKey)
        XCTAssertEqual(signed.signature, decoded.signature)

        // Decoded attestation should still verify
        XCTAssertTrue(AttestationService.verify(decoded))
    }

    // MARK: - FFI bridge tests

    func testBridgeIsAvailable() {
        let result = dginf_enclave_is_available()
        XCTAssertEqual(result, 1, "Secure Enclave should be available via FFI")
    }

    func testBridgeCreateAndFree() {
        guard let ptr = dginf_enclave_create() else {
            XCTFail("Failed to create identity via FFI")
            return
        }

        // Get public key
        guard let keyPtr = dginf_enclave_public_key_base64(ptr) else {
            dginf_enclave_free(ptr)
            XCTFail("Failed to get public key via FFI")
            return
        }
        let pubKey = String(cString: keyPtr)
        dginf_enclave_free_string(keyPtr)

        XCTAssertFalse(pubKey.isEmpty)

        dginf_enclave_free(ptr)
    }

    func testBridgeSignAndVerify() {
        guard let ptr = dginf_enclave_create() else {
            XCTFail("Failed to create identity")
            return
        }
        defer { dginf_enclave_free(ptr) }

        let message = "test message".data(using: .utf8)!

        // Sign
        let sigPtr = message.withUnsafeBytes { buf -> UnsafeMutablePointer<CChar>? in
            dginf_enclave_sign(
                ptr,
                buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                message.count
            )
        }
        guard let sigPtr = sigPtr else {
            XCTFail("Failed to sign via FFI")
            return
        }
        let sigBase64 = String(cString: sigPtr)

        // Get public key
        guard let keyPtr = dginf_enclave_public_key_base64(ptr) else {
            dginf_enclave_free_string(sigPtr)
            XCTFail("Failed to get public key via FFI")
            return
        }
        let pubKeyBase64 = String(cString: keyPtr)

        // Verify
        let valid = message.withUnsafeBytes { buf -> Int32 in
            dginf_enclave_verify(
                pubKeyBase64,
                buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                message.count,
                sigBase64
            )
        }

        XCTAssertEqual(valid, 1, "FFI signature should verify")

        dginf_enclave_free_string(sigPtr)
        dginf_enclave_free_string(keyPtr)
    }

    func testBridgeCreateAttestation() throws {
        guard let ptr = dginf_enclave_create() else {
            XCTFail("Failed to create identity")
            return
        }
        defer { dginf_enclave_free(ptr) }

        guard let jsonPtr = dginf_enclave_create_attestation(ptr) else {
            XCTFail("Failed to create attestation via FFI")
            return
        }
        let json = String(cString: jsonPtr)
        dginf_enclave_free_string(jsonPtr)

        XCTAssertTrue(json.contains("publicKey"))
        XCTAssertTrue(json.contains("signature"))
        XCTAssertTrue(json.contains("hardwareModel"))
        XCTAssertTrue(json.contains("sipEnabled"))

        // Parse and verify
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let signed = try decoder.decode(SignedAttestation.self, from: data)
        XCTAssertTrue(AttestationService.verify(signed))
    }

    func testBridgeSaveAndLoad() {
        guard let ptr1 = dginf_enclave_create() else {
            XCTFail("Failed to create identity")
            return
        }

        // Query required buffer size
        let size = dginf_enclave_data_representation(ptr1, nil, 0)
        XCTAssertGreaterThan(size, 0)

        // Read data representation
        var buffer = [UInt8](repeating: 0, count: size)
        let written = dginf_enclave_data_representation(ptr1, &buffer, size)
        XCTAssertEqual(written, size)

        // Capture public key from original
        let key1Ptr = dginf_enclave_public_key_base64(ptr1)!
        let key1 = String(cString: key1Ptr)
        dginf_enclave_free_string(key1Ptr)
        dginf_enclave_free(ptr1)

        // Load from saved data
        guard let ptr2 = dginf_enclave_load(buffer, size) else {
            XCTFail("Failed to load identity from saved data")
            return
        }

        let key2Ptr = dginf_enclave_public_key_base64(ptr2)!
        let key2 = String(cString: key2Ptr)
        dginf_enclave_free_string(key2Ptr)
        dginf_enclave_free(ptr2)

        XCTAssertEqual(key1, key2, "Loaded identity should have same public key")
    }
}
