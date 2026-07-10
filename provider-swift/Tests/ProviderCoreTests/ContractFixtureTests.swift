import Foundation
import Testing
@testable import ProviderCore

private struct ProtocolContractFile: Decodable {
    let schemaVersion: Int
    let direction: String
    let cases: [ProtocolContractCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case direction
        case cases
    }
}

private struct ProtocolContractCase: Decodable {
    let name: String
    let messageType: String
    let wire: String
    let exactBytes: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case messageType = "message_type"
        case wire
        case exactBytes = "exact_bytes"
    }
}

@Test func coordinatorProtocolV1ContractFixturesDecodeInSwift() throws {
    let fixture = try loadProtocolContract("coordinator_to_provider.json")
    #expect(fixture.schemaVersion == 1)
    #expect(fixture.direction == "coordinator_to_provider")

    for contract in fixture.cases {
        let decoded = try ProviderProtocolCodec.decodeCoordinatorMessage(from: contract.wire)
        let encoded = try ProviderProtocolCodec.encodeCoordinatorMessage(decoded)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["type"] as? String == contract.messageType)
    }
}

@Test func providerProtocolV1ContractInventoryCoversSwiftMessages() throws {
    let fixture = try loadProtocolContract("provider_to_coordinator.json")
    #expect(fixture.schemaVersion == 1)
    #expect(fixture.direction == "provider_to_coordinator")

    let fixtureTypes = Set(fixture.cases.map(\.messageType))
    let requiredTypes: Set<String> = [
        "register",
        "heartbeat",
        "inference_accepted",
        "inference_response_chunk",
        "inference_complete",
        "inference_error",
        "attestation_response",
        "code_attestation_response",
        "load_model_status",
        "prefetch_model_status",
        "models_update",
    ]
    #expect(fixtureTypes == requiredTypes)

    for contract in fixture.cases {
        let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: contract.wire)
        let encoded = try ProviderProtocolCodec.encodeProviderMessage(decoded)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["type"] as? String == contract.messageType)

        if contract.exactBytes {
            guard case .register(let register) = decoded else {
                Issue.record("\(contract.name) marks exact bytes on a non-register message")
                continue
            }
            #expect(
                register.attestation?.string
                    == #"{"signature":"sig","attestation":{"z":1,"a":[true,false]}}"#
            )
        }
    }
}

private struct CryptoContract: Decodable {
    let schemaVersion: Int
    let plaintextBase64: String
    let recipientPrivateKeyBase64: String
    let payload: CryptoPayload
    let tamperedPayload: CryptoPayload
    let statusCanonical: StatusCanonicalFixture

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case plaintextBase64 = "plaintext_base64"
        case recipientPrivateKeyBase64 = "recipient_private_key_base64"
        case payload
        case tamperedPayload = "tampered_payload"
        case statusCanonical = "status_canonical"
    }
}

private struct StatusCanonicalFixture: Decodable {
    let currentBase64: String
    let legacyHypervisorFalseBase64: String
    let explicitSecurityFalseBase64: String

    enum CodingKeys: String, CodingKey {
        case currentBase64 = "current_base64"
        case legacyHypervisorFalseBase64 = "legacy_hypervisor_false_base64"
        case explicitSecurityFalseBase64 = "explicit_security_false_base64"
    }
}

private struct CryptoPayload: Decodable {
    let ephemeralPublicKey: String
    let ciphertext: String

    enum CodingKeys: String, CodingKey {
        case ephemeralPublicKey = "ephemeral_public_key"
        case ciphertext
    }
}

@Test func swiftDecryptsGoNaClContractAndRejectsTamper() throws {
    let fixture = try JSONDecoder().decode(
        CryptoContract.self,
        from: Data(contentsOf: contractURL("crypto/nacl_box.json"))
    )
    #expect(fixture.schemaVersion == 1)
    let privateKey = try #require(Data(base64Encoded: fixture.recipientPrivateKeyBase64))
    let expected = try #require(Data(base64Encoded: fixture.plaintextBase64))
    let keyPair = try NodeKeyPair(rawSecret: privateKey)
    let payload = EncryptedPayload(
        ephemeralPublicKey: fixture.payload.ephemeralPublicKey,
        ciphertext: fixture.payload.ciphertext
    )
    #expect(try keyPair.decryptPayload(payload) == expected)

    let tampered = EncryptedPayload(
        ephemeralPublicKey: fixture.tamperedPayload.ephemeralPublicKey,
        ciphertext: fixture.tamperedPayload.ciphertext
    )
    do {
        _ = try keyPair.decryptPayload(tampered)
        Issue.record("tampered NaCl contract decrypted successfully")
    } catch {
        // Authentication failure is required.
    }

    let currentExpected = try #require(
        Data(base64Encoded: fixture.statusCanonical.currentBase64)
    )
    let current = try StatusCanonical.build(StatusCanonicalInput(
        nonce: "test-nonce",
        timestamp: "2026-04-16T12:00:00Z",
        rdmaDisabled: true,
        sipEnabled: true,
        secureBootEnabled: true,
        binaryHash: "binhash",
        activeModelHash: "activemodel",
        pythonHash: "pyhash",
        runtimeHash: "rthash",
        templateHashes: ["chatml": "tmplhash1", "gemma": "tmplhash2"],
        modelHashes: ["qwen": "modelhash1", "trinity": "modelhash2"]
    ))
    #expect(current == currentExpected)

    let explicitFalseExpected = try #require(
        Data(base64Encoded: fixture.statusCanonical.explicitSecurityFalseBase64)
    )
    let explicitFalse = try StatusCanonical.build(StatusCanonicalInput(
        nonce: "n",
        timestamp: "t",
        sipEnabled: false
    ))
    #expect(explicitFalse == explicitFalseExpected)

    let legacy = try #require(
        Data(base64Encoded: fixture.statusCanonical.legacyHypervisorFalseBase64)
    )
    let legacyObject = try #require(
        JSONSerialization.jsonObject(with: legacy) as? [String: Any]
    )
    #expect(legacyObject["hypervisor_active"] as? Bool == false)
}

private func loadProtocolContract(_ name: String) throws -> ProtocolContractFile {
    let url = contractURL("protocol/v1/\(name)")
    return try JSONDecoder().decode(ProtocolContractFile.self, from: Data(contentsOf: url))
}

private func contractURL(_ relative: String) -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 {
        root.deleteLastPathComponent()
    }
    return root.appendingPathComponent("tests/contracts").appendingPathComponent(relative)
}
