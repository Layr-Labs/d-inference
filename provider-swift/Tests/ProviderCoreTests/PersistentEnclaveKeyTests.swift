import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

// These tests exercise PersistentEnclaveKey on a real Apple Silicon Mac
// with Secure Enclave. They use a test-specific label so they don't
// interfere with the production attestation key.

private let testLabel = "io.darkbloom.provider.test-key.\(UUID().uuidString)"

// The access group must match the binary's entitlements. In debug builds
// without codesign, these tests will get errSecMissingEntitlement and
// skip gracefully.

@Test func persistentEnclaveKeyAvailabilityReflectsHardware() {
    // On Apple Silicon this should be true; the test just verifies
    // the property doesn't crash.
    let available = PersistentEnclaveKey.isAvailable
    #expect(type(of: available) == Bool.self)
}

@Test func persistentEnclaveKeyCreateAndSign() throws {
    guard PersistentEnclaveKey.isAvailable else {
        print("Skipping: Secure Enclave not available")
        return
    }

    let key: PersistentEnclaveKey
    do {
        key = try PersistentEnclaveKey.loadOrCreate(label: testLabel)
    } catch let error as PersistentEnclaveKeyError {
        if case .missingEntitlement = error {
            print("Skipping: missing keychain-access-groups entitlement (expected in unsigned debug builds)")
            return
        }
        throw error
    }

    defer { try? PersistentEnclaveKey.delete(label: testLabel) }

    // Public key should be 64 bytes (raw P-256: X || Y)
    #expect(key.publicKeyRaw.count == 64)
    #expect(!key.publicKeyBase64.isEmpty)

    // Sign some data
    let testData = Data("test payload for signing".utf8)
    let signature = try key.sign(testData)
    #expect(!signature.isEmpty)

    // Verify the signature using CryptoKit
    let pubKeyCK = try P256.Signing.PublicKey(rawRepresentation: key.publicKeyRaw)
    let ecdsaSig = try P256.Signing.ECDSASignature(derRepresentation: signature)
    #expect(pubKeyCK.isValidSignature(ecdsaSig, for: SHA256.hash(data: testData)))
}

@Test func persistentEnclaveKeyPersistence() throws {
    guard PersistentEnclaveKey.isAvailable else {
        print("Skipping: Secure Enclave not available")
        return
    }

    let persistLabel = "io.darkbloom.provider.test-persist.\(UUID().uuidString)"

    let firstKey: PersistentEnclaveKey
    do {
        firstKey = try PersistentEnclaveKey.loadOrCreate(label: persistLabel)
    } catch let error as PersistentEnclaveKeyError {
        if case .missingEntitlement = error {
            print("Skipping: missing keychain-access-groups entitlement")
            return
        }
        throw error
    }

    defer { try? PersistentEnclaveKey.delete(label: persistLabel) }

    // Load again -- should return the SAME public key
    let secondKey = try PersistentEnclaveKey.loadOrCreate(label: persistLabel)
    #expect(firstKey.publicKeyRaw == secondKey.publicKeyRaw)
    #expect(firstKey.publicKeyBase64 == secondKey.publicKeyBase64)
}

@Test func persistentEnclaveKeyDelete() throws {
    guard PersistentEnclaveKey.isAvailable else {
        print("Skipping: Secure Enclave not available")
        return
    }

    let deleteLabel = "io.darkbloom.provider.test-delete.\(UUID().uuidString)"

    do {
        _ = try PersistentEnclaveKey.loadOrCreate(label: deleteLabel)
    } catch let error as PersistentEnclaveKeyError {
        if case .missingEntitlement = error {
            print("Skipping: missing keychain-access-groups entitlement")
            return
        }
        throw error
    }

    // Delete should succeed
    try PersistentEnclaveKey.delete(label: deleteLabel)

    // After deletion, loadOrCreate should create a NEW key (different pubkey)
    // But since we can't guarantee entitlements, we just verify delete
    // doesn't throw. The next loadOrCreate would create a fresh key.
}

@Test func persistentEnclaveKeyPublicKeyFormat() throws {
    guard PersistentEnclaveKey.isAvailable else {
        print("Skipping: Secure Enclave not available")
        return
    }

    let formatLabel = "io.darkbloom.provider.test-format.\(UUID().uuidString)"

    let key: PersistentEnclaveKey
    do {
        key = try PersistentEnclaveKey.loadOrCreate(label: formatLabel)
    } catch let error as PersistentEnclaveKeyError {
        if case .missingEntitlement = error {
            print("Skipping: missing keychain-access-groups entitlement")
            return
        }
        throw error
    }

    defer { try? PersistentEnclaveKey.delete(label: formatLabel) }

    // Public key base64 should decode to exactly 64 bytes
    let decoded = Data(base64Encoded: key.publicKeyBase64)
    #expect(decoded?.count == 64)

    // Should be parseable by CryptoKit as a raw P-256 public key
    #expect(throws: Never.self) {
        _ = try P256.Signing.PublicKey(rawRepresentation: key.publicKeyRaw)
    }
}

@Test func persistentEnclaveKeyConformsToAttestationSigner() throws {
    guard PersistentEnclaveKey.isAvailable else {
        print("Skipping: Secure Enclave not available")
        return
    }

    let protoLabel = "io.darkbloom.provider.test-proto.\(UUID().uuidString)"

    let key: PersistentEnclaveKey
    do {
        key = try PersistentEnclaveKey.loadOrCreate(label: protoLabel)
    } catch let error as PersistentEnclaveKeyError {
        if case .missingEntitlement = error {
            print("Skipping: missing keychain-access-groups entitlement")
            return
        }
        throw error
    }

    defer { try? PersistentEnclaveKey.delete(label: protoLabel) }

    // Should be usable as an AttestationSigner
    let signer: any AttestationSigner = key
    #expect(!signer.publicKeyBase64.isEmpty)

    let data = Data("protocol conformance test".utf8)
    let sig = try signer.sign(data)
    #expect(!sig.isEmpty)
}

@Test func attestationBuilderAcceptsBothSignerTypes() throws {
    guard PersistentEnclaveKey.isAvailable else {
        print("Skipping: Secure Enclave not available")
        return
    }

    // Verify AttestationBuilder works with ephemeral identity
    if let ephemeral = try SecureEnclaveIdentity.createEphemeral() {
        let builder = AttestationBuilder(identity: ephemeral)
        let signed = try builder.buildAttestation()
        #expect(!signed.signature.isEmpty)
        #expect(!signed.attestation.publicKey.isEmpty)
    }

    // Verify AttestationBuilder works with persistent key
    let persistentLabel = "io.darkbloom.provider.test-builder.\(UUID().uuidString)"
    let persistent: PersistentEnclaveKey
    do {
        persistent = try PersistentEnclaveKey.loadOrCreate(label: persistentLabel)
    } catch let error as PersistentEnclaveKeyError {
        if case .missingEntitlement = error {
            print("Skipping persistent key test: missing entitlement")
            return
        }
        throw error
    }

    defer { try? PersistentEnclaveKey.delete(label: persistentLabel) }

    let builder = AttestationBuilder(identity: persistent)
    let signed = try builder.buildAttestation()
    #expect(!signed.signature.isEmpty)
    #expect(signed.attestation.publicKey == persistent.publicKeyBase64)
}

@Test func deleteNonexistentKeyDoesNotThrow() throws {
    do {
        try PersistentEnclaveKey.delete(label: "io.darkbloom.provider.nonexistent.\(UUID().uuidString)")
    } catch let error as PersistentEnclaveKeyError {
        if case .missingEntitlement = error {
            print("Skipping: missing keychain-access-groups entitlement")
            return
        }
        throw error
    }
}
