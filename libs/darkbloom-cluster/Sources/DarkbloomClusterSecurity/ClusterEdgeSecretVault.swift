import Foundation
import Security

/// One pairing's edge secret as the Keychain keeps it: the 32 bytes, and which ceremony made them (`binding`, public:
/// the pairing's link epoch and edge), so an item left from an earlier pairing with the same Mac is never taken for a
/// newer one. The bytes are never printed.
public struct ClusterEdgeSecretItem: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let secret: Data
    public let binding: String

    public init(secret: Data, binding: String) {
        self.secret = secret; self.binding = binding
    }

    public var description: String { "ClusterEdgeSecretItem(\(binding), secret redacted)" }
    public var debugDescription: String { description }
}

/// Why the Keychain gave no answer. Statuses only, never an item's data.
public enum ClusterEdgeSecretVaultFailure: Error, Equatable, Sendable {
    /// `errSecInteractionNotAllowed`: the data-protection Keychain stays locked after a restart until someone logs in
    /// to this Mac (its items are readable after the first unlock).
    case locked
    /// `errSecMissingEntitlement`: this build may not use the app's access group (ad-hoc and local builds, tests).
    case notEntitled
    case status(Int32)
}

public enum ClusterEdgeSecretVaultRead: Equatable, Sendable {
    case found(ClusterEdgeSecretItem)
    case absent
    case failed(ClusterEdgeSecretVaultFailure)
}

public enum ClusterEdgeSecretVaultWrite: Equatable, Sendable {
    case done
    /// `add` found an item there already (another process stored it first); nothing was changed.
    case exists
    /// `replace` found no item; nothing was changed.
    case absent
    case failed(ClusterEdgeSecretVaultFailure)
}

/// How the Keychain protects an item, as it reports it (no data): for `darkbloom cluster pair --status` and checks.
public struct ClusterEdgeSecretItemProtection: Equatable, Sendable {
    public let accessGroup: String?
    /// The `kSecAttrAccessible` class (`ck` = after first unlock, this device only).
    public let accessible: String?
    public let synchronizable: Bool
    public let binding: String?

    public init(accessGroup: String?, accessible: String?, synchronizable: Bool, binding: String?) {
        self.accessGroup = accessGroup; self.accessible = accessible; self.synchronizable = synchronizable
        self.binding = binding
    }

    /// After first unlock, this device only: a background service reads it once the Mac was unlocked since it
    /// started, and it never leaves this Mac (no backup restore, no migration, no iCloud).
    public var afterFirstUnlockThisDeviceOnly: Bool {
        accessible == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) && !synchronizable
    }
}

/// Where a pairing store keeps edge secrets, by the other Mac's pin. Every call answers at once and never asks the
/// user: a locked Keychain is `locked`, not a dialog.
public protocol ClusterEdgeSecretVault: Sendable {
    func read(peerPin: String) -> ClusterEdgeSecretVaultRead
    /// Stores `item` only when no item is there for `peerPin` (`exists` otherwise; nothing is overwritten).
    func add(peerPin: String, _ item: ClusterEdgeSecretItem) -> ClusterEdgeSecretVaultWrite
    /// Replaces the item there for `peerPin` (`absent` when there is none).
    func replace(peerPin: String, _ item: ClusterEdgeSecretItem) -> ClusterEdgeSecretVaultWrite
    /// Deleting nothing is not an error.
    func delete(peerPin: String) -> ClusterEdgeSecretVaultWrite
    /// The item's protection without its data; nil when there is no item.
    func protection(peerPin: String) -> Result<ClusterEdgeSecretItemProtection?, ClusterEdgeSecretVaultFailure>
}

/// Edge secrets as generic passwords in the data-protection Keychain: the app's access group (the signed CLI and its
/// LaunchAgent share it, without a prompt), after first unlock, this device only, never synchronised. One item per
/// other Mac: service `<install's keychain prefix>.cluster-pairing.edge-secret`, account the other Mac's pin.
public struct ClusterKeychainEdgeSecretVault: ClusterEdgeSecretVault, CustomStringConvertible {
    public let service: String
    public let accessGroup: String
    /// The `SecItem` calls; a recorder in tests.
    let calls: ClusterKeychainCalls

    public init(service: String, accessGroup: String) {
        self.init(service: service, accessGroup: accessGroup, calls: .system)
    }

    init(service: String, accessGroup: String, calls: ClusterKeychainCalls) {
        self.service = service; self.accessGroup = accessGroup; self.calls = calls
    }

    public var description: String { "ClusterKeychainEdgeSecretVault(\(service), \(accessGroup))" }

    static let label = "Darkbloom cluster link key"

    /// Every call names the access group: without it an unentitled build reads "not found" instead of
    /// `errSecMissingEntitlement`.
    func identity(_ peerPin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: peerPin,
         kSecAttrAccessGroup as String: accessGroup,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    public func read(peerPin: String) -> ClusterEdgeSecretVaultRead {
        var query = identity(peerPin)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, attributes) = calls.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let attributes, let secret = attributes[kSecValueData as String] as? Data,
                  let binding = (attributes[kSecAttrGeneric as String] as? Data).flatMap({ String(data: $0, encoding: .utf8) })
            else { return .failed(.status(errSecDecode)) }
            return .found(ClusterEdgeSecretItem(secret: secret, binding: binding))
        case errSecItemNotFound:
            return .absent
        default:
            return .failed(Self.failure(status))
        }
    }

    public func add(peerPin: String, _ item: ClusterEdgeSecretItem) -> ClusterEdgeSecretVaultWrite {
        var attributes = identity(peerPin)
        attributes[kSecValueData as String] = item.secret
        attributes[kSecAttrGeneric as String] = Data(item.binding.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = Self.label
        switch calls.add(attributes) {
        case errSecSuccess: return .done
        case errSecDuplicateItem: return .exists
        case let status: return .failed(Self.failure(status))
        }
    }

    public func replace(peerPin: String, _ item: ClusterEdgeSecretItem) -> ClusterEdgeSecretVaultWrite {
        let changes: [String: Any] = [kSecValueData as String: item.secret,
                                      kSecAttrGeneric as String: Data(item.binding.utf8),
                                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        switch calls.update(identity(peerPin), changes) {
        case errSecSuccess: return .done
        case errSecItemNotFound: return .absent
        case let status: return .failed(Self.failure(status))
        }
    }

    public func delete(peerPin: String) -> ClusterEdgeSecretVaultWrite {
        switch calls.delete(identity(peerPin)) {
        case errSecSuccess, errSecItemNotFound: return .done
        case let status: return .failed(Self.failure(status))
        }
    }

    public func protection(peerPin: String) -> Result<ClusterEdgeSecretItemProtection?, ClusterEdgeSecretVaultFailure> {
        var query = identity(peerPin)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, attributes) = calls.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let attributes else { return .failure(.status(errSecDecode)) }
            let synchronizable = (attributes[kSecAttrSynchronizable as String] as? Bool)
                ?? ((attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false)
            return .success(ClusterEdgeSecretItemProtection(
                accessGroup: attributes[kSecAttrAccessGroup as String] as? String,
                accessible: attributes[kSecAttrAccessible as String] as? String,
                synchronizable: synchronizable,
                binding: (attributes[kSecAttrGeneric as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }))
        case errSecItemNotFound:
            return .success(nil)
        default:
            return .failure(Self.failure(status))
        }
    }

    static func failure(_ status: OSStatus) -> ClusterEdgeSecretVaultFailure {
        switch status {
        case errSecInteractionNotAllowed: return .locked
        case errSecMissingEntitlement: return .notEntitled
        default: return .status(status)
        }
    }
}

/// The four `SecItem` calls the Keychain vault makes, so tests check its queries and its answers to each status
/// against a recorder instead of a real Keychain.
struct ClusterKeychainCalls: Sendable {
    var copyMatching: @Sendable ([String: Any]) -> (OSStatus, [String: Any]?)
    var add: @Sendable ([String: Any]) -> OSStatus
    var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
    var delete: @Sendable ([String: Any]) -> OSStatus

    static let system = ClusterKeychainCalls(
        copyMatching: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? [String: Any])
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) })
}
