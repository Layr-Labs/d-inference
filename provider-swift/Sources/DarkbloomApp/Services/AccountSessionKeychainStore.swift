import Foundation
import Security

/// Data-protection keychain persistence for the account session token.
///
/// The data-protection keychain pattern mirrors
/// ProviderCore/Security/PersistentEnclaveKey.swift (`kSecUseDataProtectionKeychain`
/// plus an access group), but the item itself is an app-local minimal
/// generic-password entry — no Secure Enclave, no shared crypto.
///
/// Partition probing: the store prefers the data-protection keychain with
/// the shared access group (release signing), but the dev bundle built by
/// `script/build_and_run.sh` ships unsigned and gets
/// `errSecMissingEntitlement` (-34018) for that partition. So the partition
/// is resolved once by probing reads — data-protection + access group, then
/// data-protection app-scoped, then the legacy file-based keychain — and the
/// first partition that doesn't report a missing entitlement wins for the
/// lifetime of the process. Signing the bundle with the documented
/// `keychain-access-groups` entitlement flips it back to the shared
/// partition (a formerly app/legacy-scoped token is simply not found there;
/// the user signs in once more — no migration is worth that code).
final class KeychainSessionStore: AccountSessionStoring, @unchecked Sendable {
    static let service = "dev.darkbloom.app.privy-session"
    static let account = "privy-access-token"

    /// Shared keychain access group. Shipping bundles must add
    /// `$(AppIdentifierPrefix)dev.darkbloom.app.shared` to their
    /// `keychain-access-groups` entitlement (see the comment in
    /// Resources/DarkbloomApp/Info.plist — the app scaffold has no
    /// .entitlements file yet, and we don't invent one in this slice).
    static let accessGroup = "dev.darkbloom.app.shared"

    private enum Partition: Sendable {
        /// Data-protection keychain, group-scoped (signed release builds).
        case sharedGroup
        /// Data-protection keychain, app-scoped (signed, group missing).
        case appScoped
        /// Legacy file-based keychain (unsigned dev bundle / swift build).
        case legacy
    }

    private let lock = NSLock()
    private var resolvedPartition: Partition?

    init() {}

    func loadToken() -> String? {
        for partition in candidatePartitions() {
            var query = baseQuery(partition: partition)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                settle(partition)
                guard let data = item as? Data else { return nil }
                return String(data: data, encoding: .utf8)
            case errSecItemNotFound:
                // Partition works, item absent — stay here for this process.
                settle(partition)
                return nil
            case errSecMissingEntitlement:
                continue // partition unsupported by this signature; try next
            default:
                settle(partition)
                return nil
            }
        }
        return nil
    }

    @discardableResult
    func saveToken(_ token: String) -> Bool {
        let data = Data(token.utf8)
        for partition in candidatePartitions() {
            var attributes = baseQuery(partition: partition)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(attributes as CFDictionary, nil)
            switch status {
            case errSecSuccess:
                settle(partition)
                return true
            case errSecDuplicateItem:
                // Upsert: a duplicate means the partition is usable —
                // settle, then overwrite the existing item's value.
                settle(partition)
                let query = baseQuery(partition: partition)
                let update: [String: Any] = [kSecValueData as String: data]
                return SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess
            case errSecMissingEntitlement:
                continue
            default:
                return false
            }
        }
        return false
    }

    func clearToken() {
        for partition in candidatePartitions() {
            let status = SecItemDelete(baseQuery(partition: partition) as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                settle(partition)
                return
            }
            if status != errSecMissingEntitlement {
                return
            }
        }
    }

    // MARK: - Partition resolution

    private func candidatePartitions() -> [Partition] {
        lock.lock()
        defer { lock.unlock() }
        if let resolvedPartition {
            return [resolvedPartition]
        }
        return [.sharedGroup, .appScoped, .legacy]
    }

    private func settle(_ partition: Partition) {
        lock.lock()
        resolvedPartition = partition
        lock.unlock()
    }

    private func baseQuery(partition: Partition) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        switch partition {
        case .sharedGroup:
            // kSecUseDataProtectionKeychain is the flag from the
            // PersistentEnclaveKey pattern: without it the query hits the
            // legacy file-based keychain where access-group membership is
            // silently ignored.
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = Self.accessGroup
        case .appScoped:
            query[kSecUseDataProtectionKeychain as String] = true
        case .legacy:
            break
        }
        return query
    }
}
