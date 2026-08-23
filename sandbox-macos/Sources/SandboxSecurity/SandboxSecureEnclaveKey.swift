import CryptoKit
import Foundation
import Security

public enum SandboxSecureEnclaveError: Error, Equatable, Sendable, CustomStringConvertible {
    case unavailable
    case accessControl(status: OSStatus)
    case create(status: OSStatus)
    case lookup(status: OSStatus)
    case delete(status: OSStatus)
    case publicKey
    case wrap(status: OSStatus)
    case unwrap(status: OSStatus)

    public var description: String {
        switch self {
        case .unavailable:
            return "Secure Enclave is unavailable"
        case .accessControl(let status):
            return "Secure Enclave access-control creation failed with OSStatus \(status)"
        case .create(let status):
            return "Secure Enclave key creation failed with OSStatus \(status)"
        case .lookup(let status):
            return "Secure Enclave key lookup failed with OSStatus \(status)"
        case .delete(let status):
            return "Secure Enclave key deletion failed with OSStatus \(status)"
        case .publicKey:
            return "Secure Enclave public-key extraction failed"
        case .wrap(let status):
            return "Secure Enclave key wrap failed with OSStatus \(status)"
        case .unwrap(let status):
            return "Secure Enclave key unwrap failed with OSStatus \(status)"
        }
    }
}

public final class SandboxSecureEnclaveKey: @unchecked Sendable {
    public static let defaultAccessGroup = "SLDQ2GJ6TL.io.darkbloom.sandbox"
    public static let defaultLabel = "io.darkbloom.sandbox.storage-kek.v1"

    private static let algorithm: SecKeyAlgorithm = .eciesEncryptionStandardX963SHA256AESGCM

    private let privateKey: SecKey

    private init(privateKey: SecKey) {
        self.privateKey = privateKey
    }

    public static var isAvailable: Bool {
        SecureEnclave.isAvailable
    }

    public static func loadOrCreate(
        accessGroup: String = defaultAccessGroup,
        label: String = defaultLabel
    ) throws -> SandboxSecureEnclaveKey {
        guard isAvailable else {
            throw SandboxSecureEnclaveError.unavailable
        }

        do {
            return try load(accessGroup: accessGroup, label: label)
        } catch SandboxSecureEnclaveError.lookup(status: errSecItemNotFound) {
            return try createPersistent(accessGroup: accessGroup, label: label)
        }
    }

    public static func makeTransient() throws -> SandboxSecureEnclaveKey {
        guard isAvailable else {
            throw SandboxSecureEnclaveError.unavailable
        }
        let accessControl = try makeAccessControl()
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false,
                kSecAttrAccessControl as String: accessControl,
            ],
        ]
        return try create(attributes: attributes)
    }

    public var publicKeyX963: Data {
        get throws {
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw SandboxSecureEnclaveError.publicKey
            }
            var error: Unmanaged<CFError>?
            guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
                  data.count == 65,
                  data.first == 0x04
            else {
                throw SandboxSecureEnclaveError.publicKey
            }
            return data
        }
    }

    public func wrap(_ plaintext: Data) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              SecKeyIsAlgorithmSupported(publicKey, .encrypt, Self.algorithm)
        else {
            throw SandboxSecureEnclaveError.publicKey
        }

        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(
            publicKey,
            Self.algorithm,
            plaintext as CFData,
            &error
        ) as Data? else {
            throw SandboxSecureEnclaveError.wrap(status: Self.status(from: error))
        }
        return wrapped
    }

    public func unwrap(_ wrapped: Data) throws -> Data {
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, Self.algorithm) else {
            throw SandboxSecureEnclaveError.unwrap(status: errSecParam)
        }

        var error: Unmanaged<CFError>?
        guard let plaintext = SecKeyCreateDecryptedData(
            privateKey,
            Self.algorithm,
            wrapped as CFData,
            &error
        ) as Data? else {
            throw SandboxSecureEnclaveError.unwrap(status: Self.status(from: error))
        }
        return plaintext
    }

    public func selfTest() throws {
        let probe = Data("darkbloom-sandbox-secure-enclave-self-test".utf8)
        let wrapped = try wrap(probe)
        guard try unwrap(wrapped) == probe else {
            throw SandboxSecureEnclaveError.unwrap(status: errSecDecode)
        }
    }

    public static func delete(
        accessGroup: String = defaultAccessGroup,
        label: String = defaultLabel
    ) throws {
        let status = SecItemDelete(query(
            accessGroup: accessGroup,
            label: label,
            returnReference: false
        ) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SandboxSecureEnclaveError.delete(status: status)
        }
    }

    private static func load(
        accessGroup: String,
        label: String
    ) throws -> SandboxSecureEnclaveKey {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query(
                accessGroup: accessGroup,
                label: label,
                returnReference: true
            ) as CFDictionary,
            &result
        )
        guard status == errSecSuccess, let result else {
            throw SandboxSecureEnclaveError.lookup(status: status)
        }
        return SandboxSecureEnclaveKey(privateKey: result as! SecKey)
    }

    private static func createPersistent(
        accessGroup: String,
        label: String
    ) throws -> SandboxSecureEnclaveKey {
        let accessControl = try makeAccessControl()
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrAccessControl as String: accessControl,
                kSecAttrLabel as String: label,
                kSecAttrAccessGroup as String: accessGroup,
            ],
        ]

        do {
            return try create(attributes: attributes)
        } catch SandboxSecureEnclaveError.create(status: errSecDuplicateItem) {
            return try load(accessGroup: accessGroup, label: label)
        }
    }

    private static func create(attributes: [String: Any]) throws -> SandboxSecureEnclaveKey {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SandboxSecureEnclaveError.create(status: status(from: error))
        }
        return SandboxSecureEnclaveKey(privateKey: key)
    }

    private static func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            &error
        ) else {
            throw SandboxSecureEnclaveError.accessControl(status: status(from: error))
        }
        return accessControl
    }

    private static func query(
        accessGroup: String,
        label: String,
        returnReference: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: label,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if returnReference {
            query[kSecReturnRef as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    private static func status(from error: Unmanaged<CFError>?) -> OSStatus {
        guard let error else {
            return errSecInternalError
        }
        let nsError = error.takeRetainedValue() as Error as NSError
        return OSStatus(nsError.code)
    }
}
