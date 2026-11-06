import Foundation
import Security

/// Where the local router keeps the owner's account API key: the one credential that lets this Mac's local API pass
/// a request on to the owner's other Macs (`X-Darkbloom-Route: self`) or the network (`prefer`).
///
/// The key never leaves this store except as the `Authorization` header of the router's own upstream request. It is
/// never printed, logged, written to `local.json` or the TOML, or put in a response; errors carry no key characters.
public protocol LocalRouterAccountKeyStore: Sendable {
    /// The saved key; nil when none is saved.
    func load() throws -> String?
    /// Saves `key`, replacing any saved one.
    func save(_ key: String) throws
    /// Removes the saved key. Removing nothing is not an error.
    func remove() throws
}

public enum LocalRouterAccountKeyError: Error, Equatable, CustomStringConvertible {
    /// A Keychain call failed; the status only, never the item's data.
    case keychain(operation: String, status: OSStatus)

    public var description: String {
        switch self {
        case .keychain(let operation, let status):
            return "the Keychain could not \(operation) the account key (OSStatus \(status))"
        }
    }
}

/// The account key in the macOS Keychain, as a generic password that stays on this Mac (never synchronised).
///
/// Signed builds keep it in the data-protection Keychain under the app's access group, which the CLI that saves it
/// and the service that reads it share without a prompt. Builds without that entitlement (local and ad-hoc builds)
/// use the login keychain, as the App Attest shadow key does.
public struct KeychainLocalRouterAccountKeyStore: LocalRouterAccountKeyStore {
    public static let defaultService = BuildEnvironment.current.keychainServicePrefix + ".route"
    public static let defaultAccount = "account-api-key"

    public let service: String
    public let account: String

    public init(service: String = Self.defaultService, account: String = Self.defaultAccount) {
        self.service = service
        self.account = account
    }

    public func load() throws -> String? {
        try withKeychain { dataProtection in
            var query = identity(dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
                    return .done(nil)
                }
                return .done(key)
            case errSecItemNotFound:
                return .done(nil)
            default:
                return .failed(status)
            }
        } operation: { "read" }
    }

    public func save(_ key: String) throws {
        try withKeychain { dataProtection in
            let query = identity(dataProtection: dataProtection)
            let data = Data(key.utf8)
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                item[kSecAttrLabel as String] = "Darkbloom account API key (local router)"
                status = SecItemAdd(item as CFDictionary, nil)
            }
            return status == errSecSuccess ? .done(()) : .failed(status)
        } operation: { "save" }
    }

    public func remove() throws {
        try withKeychain { dataProtection in
            let status = SecItemDelete(identity(dataProtection: dataProtection) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound ? .done(()) : .failed(status)
        } operation: { "remove" }
    }

    private func identity(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private enum Outcome<T> {
        case done(T)
        case failed(OSStatus)
    }

    /// The data-protection Keychain first; the login keychain when this build lacks the entitlement for it.
    private func withKeychain<T>(_ body: (Bool) -> Outcome<T>, operation: () -> String) throws -> T {
        switch body(true) {
        case .done(let value):
            return value
        case .failed(let status) where status == errSecMissingEntitlement:
            switch body(false) {
            case .done(let value): return value
            case .failed(let status): throw LocalRouterAccountKeyError.keychain(operation: operation(), status: status)
            }
        case .failed(let status):
            throw LocalRouterAccountKeyError.keychain(operation: operation(), status: status)
        }
    }
}

/// An account key held in memory: tests, and callers that must not touch the Keychain.
public final class InMemoryLocalRouterAccountKeyStore: LocalRouterAccountKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(_ key: String? = nil) { self.key = key }

    public func load() throws -> String? { lock.withLock { key } }
    public func save(_ key: String) throws { lock.withLock { self.key = key } }
    public func remove() throws { lock.withLock { key = nil } }
}

/// What a saved account key may look like: the rules `darkbloom route key` checks before it saves one.
public enum LocalRouterAccountKeyFormat {
    public static let maximumLength = 512

    /// Why `key` cannot be an account key, in plain words; nil when it can be one.
    public static func refusal(_ key: String) -> String? {
        if key.isEmpty { return "no key was given" }
        if key.count > maximumLength { return "that is longer than any Darkbloom API key" }
        if key.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value >= 0x7F }) {
            return "an API key has no spaces, line breaks or non-ASCII characters"
        }
        if key.hasPrefix(LocalEndpoint.tokenPrefix) {
            return "that is this Mac's local API key; use an account API key from the Darkbloom console"
        }
        return nil
    }
}
