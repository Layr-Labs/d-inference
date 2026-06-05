/// WrappedKEKStorage — abstraction over the at-rest persistence layer
/// for the (already-wrapped) KEK ciphertext.
///
/// Production uses `KeychainWrappedKEKStorage`, which stores the
/// wrapped-KEK bytes in the macOS data-protection Keychain — adds an
/// extra OS-enforced access layer on top of the ECIES wrap. Tests use
/// `InMemoryWrappedKEKStorage`, which holds the bytes in a dictionary;
/// this is the only way to exercise the full KEK lifecycle on
/// `swift test` builds, which don't carry the keychain-access-groups
/// entitlement.
///
/// The storage layer never sees the unwrapped KEK material — by the
/// time bytes arrive here they're already AES-256-GCM-encrypted under
/// an SE-bound key. Storage compromise alone doesn't leak the KEK.

import Foundation
import Security

// MARK: - Protocol

public protocol WrappedKEKStorage: Sendable {
    /// Read the wrapped KEK bytes for the configured slot, if any.
    /// Returns `nil` when no entry exists (first-run case).
    func load() throws -> Data?

    /// Persist the wrapped KEK bytes, replacing any prior entry.
    func save(_ wrapped: Data) throws

    /// Atomic create-if-absent. Persist `wrapped` ONLY if no
    /// entry exists yet, and return the AUTHORITATIVE bytes now in storage —
    /// the just-saved `wrapped` if we won the create, or the pre-existing entry
    /// if another writer got there first. This closes the first-use KEK race:
    /// two concurrent `KVCacheKEK.loadOrCreate()` calls on a fresh machine each
    /// generate a different KEK; with plain `save` (delete-then-add) the later
    /// one silently overwrote the earlier, stranding files the earlier owner
    /// had already written under its now-orphaned KEK. With saveIfAbsent the
    /// FIRST write wins and the loser adopts it, so a single KEK governs all
    /// files. Never overwrites an existing entry.
    func saveIfAbsent(_ wrapped: Data) throws -> Data

    /// Remove any persisted entry. Idempotent.
    func delete() throws

    /// Short identifier for diagnostics.
    var identifier: String { get }
}

// MARK: - Errors

public enum WrappedKEKStorageError: Error, CustomStringConvertible, Sendable {
    case readFailed(detail: String)
    case writeFailed(detail: String)
    case deleteFailed(detail: String)
    case missingEntitlement

    public var description: String {
        switch self {
        case .readFailed(let m): return "wrapped KEK read failed: \(m)"
        case .writeFailed(let m): return "wrapped KEK write failed: \(m)"
        case .deleteFailed(let m): return "wrapped KEK delete failed: \(m)"
        case .missingEntitlement:
            return "wrapped KEK storage requires the keychain-access-groups entitlement — running an unsigned debug build?"
        }
    }
}

// MARK: - Keychain implementation (production)

/// Stores the wrapped KEK in the macOS data-protection Keychain under
/// the configured service/account. Requires the
/// `keychain-access-groups` entitlement; an unsigned debug build will
/// see `errSecMissingEntitlement` (-34018) on every operation. Use
/// `InMemoryWrappedKEKStorage` in those builds.
public struct KeychainWrappedKEKStorage: WrappedKEKStorage {

    public static let defaultService = "io.darkbloom.kv.kek.v1"
    public static let defaultAccount = "default"

    private let service: String
    private let account: String
    public let identifier: String

    public init(
        service: String = KeychainWrappedKEKStorage.defaultService,
        account: String = KeychainWrappedKEKStorage.defaultAccount
    ) {
        self.service = service
        self.account = account
        self.identifier = "keychain(\(service)/\(account))"
    }

    public func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case -34018:
            throw WrappedKEKStorageError.missingEntitlement
        default:
            throw WrappedKEKStorageError.readFailed(detail: "OSStatus \(status)")
        }
    }

    public func save(_ wrapped: Data) throws {
        // Delete first to avoid duplicate-item error. Swallow the
        // delete's own failure — the subsequent add surfaces real
        // errors (-34018 etc.) more clearly.
        let preDelete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        _ = SecItemDelete(preDelete as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: wrapped,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case -34018:
            throw WrappedKEKStorageError.missingEntitlement
        default:
            throw WrappedKEKStorageError.writeFailed(detail: "OSStatus \(status)")
        }
    }

    public func saveIfAbsent(_ wrapped: Data) throws -> Data {
        // Atomic create: SecItemAdd fails with errSecDuplicateItem if an entry
        // already exists. No pre-delete (which would make this a clobbering
        // upsert and reopen the race). On duplicate, adopt the existing entry.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: wrapped,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return wrapped
        case errSecDuplicateItem:
            // Another writer created it first. Adopt the persisted value; never
            // overwrite. If the read somehow finds nothing (deleted in between),
            // fall back to our bytes rather than returning stale.
            if let existing = try load() { return existing }
            return wrapped
        case -34018:
            throw WrappedKEKStorageError.missingEntitlement
        default:
            throw WrappedKEKStorageError.writeFailed(detail: "OSStatus \(status)")
        }
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        case -34018:
            throw WrappedKEKStorageError.missingEntitlement
        default:
            throw WrappedKEKStorageError.deleteFailed(detail: "OSStatus \(status)")
        }
    }
}

// MARK: - In-memory implementation (tests + dev)

/// Holds the wrapped KEK bytes in a synchronized in-memory store.
/// Safe to share across `KVCacheKEK` instances within a single
/// process — emulates "persistent" storage for test scenarios that
/// simulate process restarts.
public final class InMemoryWrappedKEKStorage: WrappedKEKStorage, @unchecked Sendable {

    public let identifier: String
    private let lock = NSLock()
    private var stored: Data?

    public init(identifier: String = "in-memory", initial: Data? = nil) {
        self.identifier = identifier
        self.stored = initial
    }

    public func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func save(_ wrapped: Data) throws {
        lock.lock(); defer { lock.unlock() }
        stored = wrapped
    }

    public func saveIfAbsent(_ wrapped: Data) throws -> Data {
        // Atomic under the lock: create only if absent; otherwise adopt the
        // existing value (first writer wins). Mirrors the Keychain semantics.
        lock.lock(); defer { lock.unlock() }
        if let existing = stored { return existing }
        stored = wrapped
        return wrapped
    }

    public func delete() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}
