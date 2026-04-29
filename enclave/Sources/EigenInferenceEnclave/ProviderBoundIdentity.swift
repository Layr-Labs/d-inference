import Foundation
import Security

/// Persistent provider identity scoped to the Darkbloom keychain access group.
///
/// This is distinct from the per-launch attestation key. It is created as a
/// permanent Secure Enclave private key, stored by Security.framework in the
/// keychain access group embedded in the signed provider entitlement. A fork
/// signed outside the Darkbloom Team ID cannot load or use this key.
public final class ProviderBoundIdentity {
    private static let defaultAccessGroup = "SLDQ2GJ6TL.io.darkbloom.provider"
    private static let applicationTag = "io.darkbloom.provider.identity.v1".data(using: .utf8)!

    private let privateKey: SecKey

    public init() throws {
        if let existing = try Self.findIdentityKey() {
            self.privateKey = existing
            return
        }
        self.privateKey = try Self.createIdentityKey()
    }

    public var publicKeyBase64: String {
        get throws {
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw ProviderBoundIdentityError.publicKeyUnavailable
            }
            var error: Unmanaged<CFError>?
            guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
                throw ProviderBoundIdentityError.securityError(error?.takeRetainedValue())
            }
            return publicKeyData.base64EncodedString()
        }
    }

    public func sign(_ data: Data) throws -> Data {
        let algorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
            throw ProviderBoundIdentityError.unsupportedAlgorithm
        }

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, data as CFData, &error) as Data? else {
            throw ProviderBoundIdentityError.securityError(error?.takeRetainedValue())
        }
        return signature
    }

    private static func findIdentityKey() throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw ProviderBoundIdentityError.osStatus(status)
        }
        guard let key = item else {
            throw ProviderBoundIdentityError.publicKeyUnavailable
        }
        return (key as! SecKey)
    }

    private static func createIdentityKey() throws -> SecKey {
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &accessError
        ) else {
            throw ProviderBoundIdentityError.securityError(accessError?.takeRetainedValue())
        }

        let privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrAccessControl as String: accessControl,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrApplicationTag as String: applicationTag,
        ]

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]

        var createError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
            throw ProviderBoundIdentityError.securityError(createError?.takeRetainedValue())
        }
        return key
    }

    private static var accessGroup: String { defaultAccessGroup }
}

public enum ProviderBoundIdentityError: Error {
    case osStatus(OSStatus)
    case publicKeyUnavailable
    case unsupportedAlgorithm
    case securityError(CFError?)
}
