/// PersistentEnclaveKey -- persistent Secure Enclave P-256 signing key
/// backed by the macOS data protection keychain.
///
/// Unlike `SecureEnclaveIdentity` (ephemeral, CryptoKit), this key persists
/// across launches and is bound to the signing team's keychain access group.
/// Only binaries signed by the same Developer ID team can access it --
/// enforced by securityd at the kernel level. A patched binary re-signed
/// with `codesign -s -` gets `errSecMissingEntitlement`.

import CryptoKit
import Foundation
import Security
import os

private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "persistent-enclave-key")

// MARK: - Errors

public enum PersistentEnclaveKeyError: Error, CustomStringConvertible {
    case secureEnclaveUnavailable
    case accessControlCreationFailed(status: OSStatus)
    case keyCreationFailed(status: OSStatus)
    case keyLookupFailed(status: OSStatus)
    case deletionFailed(status: OSStatus)
    case signingFailed(status: OSStatus, message: String)
    case publicKeyExtractionFailed
    case publicKeySerializationFailed(status: OSStatus)
    case missingEntitlement

    public var description: String {
        switch self {
        case .secureEnclaveUnavailable:
            return "Secure Enclave is not available on this device"
        case .accessControlCreationFailed(let status):
            return "Failed to create access control: OSStatus \(status)"
        case .keyCreationFailed(let status):
            if status == -34018 {
                return "Key creation failed: missing keychain-access-groups entitlement (OSStatus -34018)"
            }
            return "Key creation failed: OSStatus \(status)"
        case .keyLookupFailed(let status):
            return "Key lookup failed: OSStatus \(status)"
        case .deletionFailed(let status):
            return "Key deletion failed: OSStatus \(status)"
        case .signingFailed(let status, let message):
            return "Signing failed (OSStatus \(status)): \(message)"
        case .publicKeyExtractionFailed:
            return "Failed to extract public key from private key"
        case .publicKeySerializationFailed(let status):
            return "Failed to serialize public key: OSStatus \(status)"
        case .missingEntitlement:
            return "Binary is missing the keychain-access-groups entitlement for the configured access group"
        }
    }
}

// MARK: - Helpers

/// Extract an OSStatus from a CFError produced by Security framework APIs.
private func osStatus(from cfError: Unmanaged<CFError>?) -> OSStatus {
    guard let cfError else { return errSecInternalError }
    let nsError = cfError.takeRetainedValue() as Error as NSError
    return OSStatus(nsError.code)
}

// MARK: - PersistentEnclaveKey

public final class PersistentEnclaveKey: @unchecked Sendable {
    private let privateKey: SecKey
    private let _publicKeyRaw: Data

    /// Default access group. The team ID prefix is hardcoded because codesign
    /// does NOT expand $(AppIdentifierPrefix) -- that's Xcode-only.
    public static let defaultAccessGroup = "SLDQ2GJ6TL.io.darkbloom.provider"

    public static let defaultLabel = "io.darkbloom.provider.attestation-signing.v1"

    /// Raw P-256 public key (64 bytes: X || Y, without the 0x04 prefix).
    public var publicKeyRaw: Data { _publicKeyRaw }

    /// Base64-encoded public key.
    public var publicKeyBase64: String { _publicKeyRaw.base64EncodedString() }

    // MARK: - Private init

    private init(privateKey: SecKey) throws {
        self.privateKey = privateKey

        guard let pubKey = SecKeyCopyPublicKey(privateKey) else {
            throw PersistentEnclaveKeyError.publicKeyExtractionFailed
        }

        var serError: Unmanaged<CFError>?
        guard let pubData = SecKeyCopyExternalRepresentation(pubKey, &serError) as Data? else {
            throw PersistentEnclaveKeyError.publicKeySerializationFailed(
                status: osStatus(from: serError)
            )
        }

        // X9.62 uncompressed format: 0x04 || X (32 bytes) || Y (32 bytes)
        guard pubData.count == 65, pubData[0] == 0x04 else {
            throw PersistentEnclaveKeyError.publicKeyExtractionFailed
        }
        self._publicKeyRaw = Data(pubData.dropFirst())
    }

    // MARK: - Load or Create

    /// Load an existing persistent key from the keychain, or create one if not found.
    public static func loadOrCreate(
        accessGroup: String? = nil,
        label: String? = nil
    ) throws -> PersistentEnclaveKey {
        let group = resolveAccessGroup(accessGroup)
        let keyLabel = label ?? defaultLabel

        // Only fall through to creation on errSecItemNotFound. Auth failures,
        // locked-keychain errors, and missing-entitlement must surface so the
        // caller can fall back instead of racing with createNew.
        do {
            let existing = try findExisting(accessGroup: group, label: keyLabel)
            logger.info("Loaded existing persistent Secure Enclave key")
            return existing
        } catch PersistentEnclaveKeyError.keyLookupFailed(status: errSecItemNotFound) {
            // No existing key — proceed to creation.
        }

        return try createNew(accessGroup: group, label: keyLabel)
    }

    // MARK: - Find Existing

    private static func findExisting(
        accessGroup: String,
        label: String
    ) throws -> PersistentEnclaveKey {
        // kSecUseDataProtectionKeychain forces the iOS-style keychain on macOS,
        // which is the only one that enforces kSecAttrAccessGroup membership.
        // Without it, the query may hit the legacy file-based keychain where
        // the access-group constraint is silently ignored.
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: label,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnRef as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            // Force-unwrap safe: errSecSuccess guarantees a result.
            let key = result as! SecKey
            return try PersistentEnclaveKey(privateKey: key)
        case errSecItemNotFound:
            throw PersistentEnclaveKeyError.keyLookupFailed(status: errSecItemNotFound)
        case -34018:
            throw PersistentEnclaveKeyError.missingEntitlement
        default:
            throw PersistentEnclaveKeyError.keyLookupFailed(status: status)
        }
    }

    // MARK: - Create New

    private static func createNew(
        accessGroup: String,
        label: String
    ) throws -> PersistentEnclaveKey {
        guard isAvailable else {
            throw PersistentEnclaveKeyError.secureEnclaveUnavailable
        }

        var acError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &acError
        ) else {
            throw PersistentEnclaveKeyError.accessControlCreationFailed(
                status: osStatus(from: acError)
            )
        }

        let privateKeyAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrAccessControl as String: accessControl,
            kSecAttrLabel as String: label,
            kSecAttrAccessGroup as String: accessGroup,
        ]

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: privateKeyAttrs,
        ]

        var createError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
            let status = osStatus(from: createError)

            if status == -34018 {
                throw PersistentEnclaveKeyError.missingEntitlement
            }
            // -25299 = errSecDuplicateItem: race between check and create
            if status == errSecDuplicateItem {
                logger.info("Key already exists (race condition), loading existing")
                return try findExisting(accessGroup: accessGroup, label: label)
            }

            throw PersistentEnclaveKeyError.keyCreationFailed(status: status)
        }

        logger.info("Created new persistent Secure Enclave key (access group: \(accessGroup))")
        return try PersistentEnclaveKey(privateKey: privateKey)
    }

    // MARK: - Sign

    /// Sign data using the Secure Enclave private key.
    ///
    /// Returns a DER-encoded ECDSA signature (ASN.1 SEQUENCE of two INTEGERs),
    /// compatible with Go's crypto/ecdsa and the coordinator's verification.
    public func sign(_ data: Data) throws -> Data {
        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &signError
        ) else {
            if let cfErr = signError {
                let nsErr = cfErr.takeRetainedValue() as Error as NSError
                throw PersistentEnclaveKeyError.signingFailed(
                    status: OSStatus(nsErr.code),
                    message: nsErr.localizedDescription
                )
            }
            throw PersistentEnclaveKeyError.signingFailed(
                status: errSecInternalError,
                message: "unknown error"
            )
        }
        return signature as Data
    }

    // MARK: - Delete

    /// Remove the persistent key from the keychain.
    public static func delete(
        accessGroup: String? = nil,
        label: String? = nil
    ) throws {
        let group = resolveAccessGroup(accessGroup)
        let keyLabel = label ?? defaultLabel

        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: keyLabel,
            kSecAttrAccessGroup as String: group,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
        ]

        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        case -34018:
            // No entitlement = no key could have been created by this binary.
            throw PersistentEnclaveKeyError.missingEntitlement
        default:
            throw PersistentEnclaveKeyError.deletionFailed(status: status)
        }
    }

    // MARK: - Availability

    /// Whether the Secure Enclave is available on this device.
    ///
    /// Probes actual hardware capability via CryptoKit. Returns false on Intel
    /// Macs without T2, macOS VMs without virtualized SE, and the iOS Simulator.
    ///
    /// - Note: This does NOT check whether the binary has the
    ///   `keychain-access-groups` entitlement. Even when `isAvailable` returns
    ///   true, `loadOrCreate()` can still throw `.missingEntitlement` on
    ///   unsigned debug builds. The entitlement is gated by the provisioning
    ///   profile embedded in the signed app bundle.
    public static var isAvailable: Bool {
        SecureEnclave.isAvailable
    }

    // MARK: - Access Group Resolution

    private static func resolveAccessGroup(_ override: String?) -> String {
        if let override { return override }
        if let envGroup = ProcessInfo.processInfo.environment["DARKBLOOM_KEYCHAIN_ACCESS_GROUP"],
           !envGroup.isEmpty {
            return envGroup
        }
        return defaultAccessGroup
    }
}
