/// AttestationTests — Attestation blob serialization, JSON structure, and field validation.

import XCTest
import CryptoKit
@testable import EigenInferenceEnclave

final class AttestationTests: XCTestCase {

    // MARK: - JSON Serialization

    func testAttestationBlobSerializesToJSON() throws {
        try XCTSkipIf(!SecureEnclave.isAvailable, "Secure Enclave not available")

        let identity = try SecureEnclaveIdentity()
        let service = AttestationService(identity: identity)
        let signed = try service.createAttestation()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(signed)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        XCTAssertFalse(jsonString.isEmpty)
        XCTAssertTrue(jsonString.hasPrefix("{"))
        XCTAssertTrue(jsonString.hasSuffix("}"))
    }

    func testJSONHasSortedKeys() throws {
        try XCTSkipIf(!SecureEnclave.isAvailable, "Secure Enclave not available")

        let identity = try SecureEnclaveIdentity()
        let service = AttestationService(identity: identity)
        let signed = try service.createAttestation()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(signed)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        // Parse to verify sorted key order in the attestation sub-object.
        // With .sortedKeys, JSON keys appear alphabetically. Verify the
        // "attestation" object's keys are in alphabetical order.
        //
        // The attestation blob fields in alphabetical order are:
        //   authenticatedRootEnabled, binaryHash, chipName, encryptionPublicKey,
        //   hardwareModel, osVersion, publicKey, rdmaDisabled, secureBootEnabled,
        //   secureEnclaveAvailable, serialNumber, sipEnabled, systemVolumeHash, timestamp
        //
        // Verify a few key orderings by checking string positions
        if let authPos = jsonString.range(of: "\"authenticatedRootEnabled\""),
           let chipPos = jsonString.range(of: "\"chipName\""),
           let pubPos = jsonString.range(of: "\"publicKey\""),
           let sipPos = jsonString.range(of: "\"sipEnabled\""),
           let tsPos = jsonString.range(of: "\"timestamp\"") {
            XCTAssertTrue(authPos.lowerBound < chipPos.lowerBound,
                          "authenticatedRootEnabled should come before chipName")
            XCTAssertTrue(chipPos.lowerBound < pubPos.lowerBound,
                          "chipName should come before publicKey")
            XCTAssertTrue(pubPos.lowerBound < sipPos.lowerBound,
                          "publicKey should come before sipEnabled")
            XCTAssertTrue(sipPos.lowerBound < tsPos.lowerBound,
                          "sipEnabled should come before timestamp")
        } else {
            XCTFail("Expected attestation fields not found in JSON")
        }
    }

    // MARK: - Required Fields

    func testAllRequiredFieldsPresent() throws {
        try XCTSkipIf(!SecureEnclave.isAvailable, "Secure Enclave not available")

        let identity = try SecureEnclaveIdentity()
        let service = AttestationService(identity: identity)
        let signed = try service.createAttestation()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(signed)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        // Required fields from the AttestationBlob struct
        let requiredFields = [
            "authenticatedRootEnabled",
            "chipName",
            "hardwareModel",
            "osVersion",
            "publicKey",
            "rdmaDisabled",
            "secureBootEnabled",
            "secureEnclaveAvailable",
            "sipEnabled",
            "timestamp",
        ]

        for field in requiredFields {
            XCTAssertTrue(jsonString.contains("\"\(field)\""),
                          "JSON should contain required field '\(field)'")
        }

        // Also verify the top-level structure has attestation + signature
        XCTAssertTrue(jsonString.contains("\"attestation\""))
        XCTAssertTrue(jsonString.contains("\"signature\""))
    }

    func testAttestationFieldValues() throws {
        try XCTSkipIf(!SecureEnclave.isAvailable, "Secure Enclave not available")

        let identity = try SecureEnclaveIdentity()
        let service = AttestationService(identity: identity)
        let signed = try service.createAttestation()

        let blob = signed.attestation

        // chip_name should not be empty (system_profiler should find something)
        XCTAssertFalse(blob.chipName.isEmpty, "chipName should not be empty")

        // hardwareModel should look like "Mac16,1" or similar
        XCTAssertFalse(blob.hardwareModel.isEmpty, "hardwareModel should not be empty")

        // osVersion should be semver-like
        let versionParts = blob.osVersion.split(separator: ".")
        XCTAssertGreaterThanOrEqual(versionParts.count, 2,
                                    "osVersion should have at least major.minor")

        // publicKey should be base64-encoded 64 bytes (P-256 raw = 64 bytes = 88 base64 chars)
        XCTAssertFalse(blob.publicKey.isEmpty)
        let pubKeyData = Data(base64Encoded: blob.publicKey)
        XCTAssertNotNil(pubKeyData, "publicKey should be valid base64")
        XCTAssertEqual(pubKeyData?.count, 64,
                       "P-256 raw public key should be 64 bytes")

        // secureEnclaveAvailable should be true (we already checked isAvailable)
        XCTAssertTrue(blob.secureEnclaveAvailable)

        // signature should be valid base64
        XCTAssertFalse(signed.signature.isEmpty)
        let sigData = Data(base64Encoded: signed.signature)
        XCTAssertNotNil(sigData, "signature should be valid base64")
    }

    // MARK: - Timestamp Format

    func testTimestampIsISO8601() throws {
        try XCTSkipIf(!SecureEnclave.isAvailable, "Secure Enclave not available")

        let identity = try SecureEnclaveIdentity()
        let service = AttestationService(identity: identity)
        let signed = try service.createAttestation()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(signed)

        // Parse the JSON to extract the timestamp string
        let json = try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]
        let attestation = json["attestation"] as! [String: Any]
        let timestampStr = attestation["timestamp"] as! String

        // ISO 8601 format: "2026-04-03T12:00:00Z" or with fractional seconds
        // Verify it parses correctly with ISO8601DateFormatter
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Try with fractional seconds first, then without
        var parsed = formatter.date(from: timestampStr)
        if parsed == nil {
            formatter.formatOptions = [.withInternetDateTime]
            parsed = formatter.date(from: timestampStr)
        }

        XCTAssertNotNil(parsed, "Timestamp '\(timestampStr)' should be valid ISO 8601")

        // Timestamp should be recent (within the last minute)
        if let date = parsed {
            let elapsed = Date().timeIntervalSince(date)
            XCTAssertLessThan(elapsed, 60,
                              "Timestamp should be within the last minute")
            XCTAssertGreaterThanOrEqual(elapsed, 0,
                                       "Timestamp should not be in the future")
        }
    }

    // MARK: - Signature Verification

    func testSignedAttestationVerifies() throws {
        try XCTSkipIf(!SecureEnclave.isAvailable, "Secure Enclave not available")

        let identity = try SecureEnclaveIdentity()
        let service = AttestationService(identity: identity)
        let signed = try service.createAttestation()

        XCTAssertTrue(AttestationService.verify(signed),
                      "Attestation signature should verify against embedded public key")
    }

    func testAttestationJSONRoundTrip() throws {
        try XCTSkipIf(!SecureEnclave.isAvailable, "Secure Enclave not available")

        let identity = try SecureEnclaveIdentity()
        let service = AttestationService(identity: identity)
        let signed = try service.createAttestation()

        // Encode
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(signed)

        // Decode
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SignedAttestation.self, from: data)

        // Fields should match
        XCTAssertEqual(signed.attestation.publicKey, decoded.attestation.publicKey)
        XCTAssertEqual(signed.attestation.chipName, decoded.attestation.chipName)
        XCTAssertEqual(signed.attestation.hardwareModel, decoded.attestation.hardwareModel)
        XCTAssertEqual(signed.signature, decoded.signature)

        // Decoded should still verify
        XCTAssertTrue(AttestationService.verify(decoded),
                      "Decoded attestation should still verify")
    }

    // MARK: - Optional Fields

    func testAttestationWithEncryptionKey() throws {
        try XCTSkipIf(!SecureEnclave.isAvailable, "Secure Enclave not available")

        let identity = try SecureEnclaveIdentity()
        let service = AttestationService(identity: identity)

        // Create a dummy X25519 key for testing
        let x25519Key = Curve25519.KeyAgreement.PrivateKey()
        let encKeyB64 = x25519Key.publicKey.rawRepresentation.base64EncodedString()

        let signed = try service.createAttestation(encryptionPublicKey: encKeyB64)

        XCTAssertEqual(signed.attestation.encryptionPublicKey, encKeyB64)
        XCTAssertTrue(AttestationService.verify(signed))
    }

    func testAttestationWithBinaryHash() throws {
        try XCTSkipIf(!SecureEnclave.isAvailable, "Secure Enclave not available")

        let identity = try SecureEnclaveIdentity()
        let service = AttestationService(identity: identity)

        let hash = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        let signed = try service.createAttestation(binaryHash: hash)

        XCTAssertEqual(signed.attestation.binaryHash, hash)
        XCTAssertTrue(AttestationService.verify(signed))
    }

    func testAttestationWithoutOptionalFields() throws {
        try XCTSkipIf(!SecureEnclave.isAvailable, "Secure Enclave not available")

        let identity = try SecureEnclaveIdentity()
        let service = AttestationService(identity: identity)
        let signed = try service.createAttestation()

        // Without arguments, optional fields should be nil
        XCTAssertNil(signed.attestation.encryptionPublicKey)
        XCTAssertNil(signed.attestation.binaryHash)
        XCTAssertTrue(AttestationService.verify(signed))
    }
}
