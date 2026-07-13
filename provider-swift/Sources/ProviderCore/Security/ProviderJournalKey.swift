/// Per-installation encryption key for durable provider journals.
///
/// Production keys are 256 random bits stored as a non-synchronizable,
/// ThisDeviceOnly generic-password item in the macOS data-protection Keychain.
/// `SecItemAdd` is the cross-process create-if-absent primitive: concurrent
/// first launches either create the key or receive `errSecDuplicateItem` and
/// load the winner. The key is never written to the journal filesystem.

import CryptoKit
import Foundation
import Security

public enum ProviderJournalKeyError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidInstallationAccount
    case invalidKeyLength(Int)
    case randomGenerationFailed(OSStatus)
    case readFailed(OSStatus)
    case writeFailed(OSStatus)
    case deleteFailed(OSStatus)
    case missingEntitlement
    case keychainContractViolation

    public var description: String {
        switch self {
        case .invalidInstallationAccount:
            return "journal key installation account must be non-empty and bounded"
        case .invalidKeyLength(let length):
            return "journal key must contain 32 bytes, got \(length)"
        case .randomGenerationFailed(let status):
            return "journal key random generation failed: OSStatus \(status)"
        case .readFailed(let status):
            return "journal key read failed: OSStatus \(status)"
        case .writeFailed(let status):
            return "journal key write failed: OSStatus \(status)"
        case .deleteFailed(let status):
            return "journal key deletion failed: OSStatus \(status)"
        case .missingEntitlement:
            return "journal key requires the provider keychain entitlement"
        case .keychainContractViolation:
            return "Keychain reported success without journal key data"
        }
    }
}

/// Key retrieval is the only key-material injection boundary used by the
/// journal. Filesystem format, encryption, authentication, and durability are
/// always exercised by the production journal implementation.
public protocol ProviderJournalKeySource: Sendable {
    func loadOrCreateKey() throws -> SymmetricKey
}

/// Process- and thread-safe Keychain-backed source.
public final class ProviderJournalKey: ProviderJournalKeySource, @unchecked Sendable {
    public static let defaultService = "io.darkbloom.provider.terminal-journal-key.v1"
    /// One stable account for the installation. Connection-assigned provider
    /// IDs are intentionally never part of Keychain key lookup.
    public static let defaultInstallationAccount = "installation"

    private let service: String
    public let installationAccount: String
    private let accessGroup: String?
    private let lock = NSLock()
    private var cached: SymmetricKey?

    public init(
        service: String = ProviderJournalKey.defaultService,
        installationAccount: String = ProviderJournalKey.defaultInstallationAccount,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.installationAccount = installationAccount
        self.accessGroup = accessGroup
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        try Self.validate(installationAccount: installationAccount)

        lock.lock()
        defer { lock.unlock() }

        if let key = cached {
            return key
        }
        if let bytes = try load() {
            let key = try Self.makeKey(bytes)
            cached = key
            return key
        }

        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return errSecAllocate
            }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            throw ProviderJournalKeyError.randomGenerationFailed(randomStatus)
        }

        let status = SecItemAdd(addQuery(bytes: bytes) as CFDictionary, nil)
        let authoritative: Data
        switch status {
        case errSecSuccess:
            authoritative = bytes
        case errSecDuplicateItem:
            // Another process won first-install creation. Adopt exactly the
            // persisted key; never overwrite it and strand durable records.
            guard let existing = try load() else {
                throw ProviderJournalKeyError.keychainContractViolation
            }
            authoritative = existing
        case -34018:
            throw ProviderJournalKeyError.missingEntitlement
        default:
            throw ProviderJournalKeyError.writeFailed(status)
        }

        let key = try Self.makeKey(authoritative)
        cached = key
        return key
    }

    /// Idempotent removal for uninstall/credential-reset flows and focused
    /// Keychain integration tests. Deleting this key makes existing journals
    /// intentionally unreadable; normal provider startup must never call it.
    public func deleteKey() throws {
        try Self.validate(installationAccount: installationAccount)
        lock.lock()
        defer { lock.unlock() }

        var query = baseQuery()
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            cached = nil
        case -34018:
            throw ProviderJournalKeyError.missingEntitlement
        default:
            throw ProviderJournalKeyError.deleteFailed(status)
        }
    }

    private func load() throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery() as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let bytes = result as? Data else {
                throw ProviderJournalKeyError.keychainContractViolation
            }
            return bytes
        case errSecItemNotFound:
            return nil
        case -34018:
            throw ProviderJournalKeyError.missingEntitlement
        default:
            throw ProviderJournalKeyError.readFailed(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: installationAccount,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func addQuery(bytes: Data) -> [String: Any] {
        var query = baseQuery()
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        query[kSecValueData as String] = bytes
        return query
    }

    private static func validate(installationAccount: String) throws {
        guard !installationAccount.isEmpty, installationAccount.utf8.count <= 256 else {
            throw ProviderJournalKeyError.invalidInstallationAccount
        }
    }

    private static func makeKey(_ bytes: Data) throws -> SymmetricKey {
        guard bytes.count == 32 else {
            throw ProviderJournalKeyError.invalidKeyLength(bytes.count)
        }
        return SymmetricKey(data: bytes)
    }
}
