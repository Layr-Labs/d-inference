import Foundation
import Testing
@testable import ProviderCore

/// The text of every `PersistentEnclaveKeyError` case. These messages reach
/// provider logs and `doctor` output. No Secure Enclave or Keychain call runs.
@Suite("Persistent enclave key errors")
struct PersistentEnclaveKeyErrorTests {

    @Test("each error case has its own exact message")
    func descriptions() {
        let cases: [(PersistentEnclaveKeyError, String)] = [
            (.secureEnclaveUnavailable, "Secure Enclave is not available on this device"),
            (.accessControlCreationFailed(status: -50), "Failed to create access control: OSStatus -50"),
            (.keyCreationFailed(status: -25293), "Key creation failed: OSStatus -25293"),
            (.keyLookupFailed(status: -25300), "Key lookup failed: OSStatus -25300"),
            (.deletionFailed(status: -25244), "Key deletion failed: OSStatus -25244"),
            (.signingFailed(status: -25308, message: "interaction not allowed"),
             "Signing failed (OSStatus -25308): interaction not allowed"),
            (.publicKeyExtractionFailed, "Failed to extract public key from private key"),
            (.publicKeySerializationFailed(status: -4), "Failed to serialize public key: OSStatus -4"),
            (.missingEntitlement,
             "Binary is missing the keychain-access-groups entitlement for the configured access group"),
        ]
        for (error, expected) in cases {
            #expect(error.description == expected)
        }
    }

    @Test("a key creation failure with status -34018 names the missing entitlement")
    func keyCreationMissingEntitlementStatus() {
        #expect(PersistentEnclaveKeyError.keyCreationFailed(status: -34018).description
            == "Key creation failed: missing keychain-access-groups entitlement (OSStatus -34018)")
    }

    @Test("the default access group carries the team prefix and the provider bundle id")
    func defaultAccessGroup() {
        #expect(PersistentEnclaveKey.defaultAccessGroup.hasSuffix(".io.darkbloom.provider"))
        #expect(PersistentEnclaveKey.defaultAccessGroup.split(separator: ".").first?.count == 10)
    }
}
