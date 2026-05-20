import Foundation
import Security

// MARK: - ClusterPeerKeychain
//
// Stores each cluster peer's SE public key in the macOS Keychain, keyed by
// the peer's Thunderbolt IP address. Using the Keychain (vs a plain file)
// means modifying the pin requires SE access — root alone is not sufficient.
//
// Items are stored as kSecClassGenericPassword with:
//   service = "io.darkbloom.cluster.peer-sekey"
//   account = peer Thunderbolt IP (e.g. "169.254.58.74")
//   value   = raw 64-byte P-256 public key (X ∥ Y, no prefix byte)
//   accessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
//                (never syncs to iCloud, tied to this hardware)

public enum ClusterPeerKeychain {

    private static let service = "io.darkbloom.cluster.peer-sekey"

    /// Store (or replace) the pinned SE public key for a peer IP.
    public static func store(peerSEKey: Data, peerIP: String) throws {
        // Remove any stale entry first — SecItemAdd rejects duplicates.
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: peerIP,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: peerIP,
            kSecValueData: peerSEKey,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ClusterPeerKeychainError.storeFailed(status)
        }
    }

    /// Load the pinned SE public key for a peer IP.
    /// Throws `ClusterPeerKeychainError.keyNotPinned` if none is stored.
    public static func load(peerIP: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: peerIP,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClusterPeerKeychainError.keyNotPinned
        }
        return data
    }

    /// Remove the pinned key for a peer IP (e.g. during cluster teardown).
    public static func delete(peerIP: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: peerIP,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Errors

public enum ClusterPeerKeychainError: Error, CustomStringConvertible {
    case keyNotPinned
    case storeFailed(OSStatus)

    public var description: String {
        switch self {
        case .keyNotPinned:
            return "No cluster peer SE key pinned for this IP. Run `darkbloom cluster setup --peer-serial <serial> --peer-ip <ip>` first."
        case .storeFailed(let status):
            return "Keychain write failed (OSStatus \(status)). Check that the process has keychain access entitlements."
        }
    }
}
