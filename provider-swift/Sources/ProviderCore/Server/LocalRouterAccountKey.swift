import Foundation
import LocalAuthentication
import Security
import notify

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

    public var changeNotification: String { service + "-key-changed" }

    /// The `SecItem` calls; a fake in tests.
    let calls: KeychainItemCalls

    public init(service: String = Self.defaultService, account: String = Self.defaultAccount) {
        self.init(service: service, account: account, calls: .system)
    }

    init(service: String, account: String, calls: KeychainItemCalls) {
        self.service = service
        self.account = account
        self.calls = calls
    }

    /// Never asks the user: a read that would need a Keychain dialog (a locked keychain, or an item this build may not
    /// read without approval, as after an ad-hoc rebuild) fails at once instead, so a request never waits on one.
    /// Data-protection items follow the query's `LAContext`, which may not ask. Legacy (login keychain) items ignore
    /// the query's UI keys and follow the process-wide `SecKeychainSetUserInteractionAllowed` switch, which is off for
    /// the read and put back after. Saving and removing (`route key`, at a terminal) may still ask.
    public func load() throws -> String? {
        try withoutAskingTheUser {
            try withKeychain(operation: "read") { dataProtection in
                var query = identity(dataProtection: dataProtection)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                if dataProtection { query[kSecUseAuthenticationContext as String] = Self.contextThatMayNotAsk() }
                let (status, data) = calls.copyMatching(query)
                switch status {
                case errSecSuccess:
                    guard let data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
                        return .done(nil)
                    }
                    return .done(key)
                case errSecItemNotFound:
                    return .done(nil)
                default:
                    return .failed(status)
                }
            }
        }
    }

    public func save(_ key: String) throws {
        try withKeychain(operation: "save") { dataProtection in
            let query = identity(dataProtection: dataProtection)
            let data = Data(key.utf8)
            var status = calls.update(query, [kSecValueData as String: data])
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                item[kSecAttrLabel as String] = "Darkbloom account API key (local router)"
                status = calls.add(item)
            }
            return status == errSecSuccess ? .done(()) : .failed(status)
        }
    }

    public func remove() throws {
        try withKeychain(operation: "remove") { dataProtection in
            let status = calls.delete(identity(dataProtection: dataProtection))
            return status == errSecSuccess || status == errSecItemNotFound ? .done(()) : .failed(status)
        }
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

    /// One read at a time turns the switch off, as it is the whole process's.
    private static let userInteractionSwitch = NSLock()

    /// Runs `read` with the legacy keychain's switch for asking the user off, then puts back what was set. A switch
    /// that can't be read or turned off means no read.
    private func withoutAskingTheUser<T>(_ read: () throws -> T) throws -> T {
        try Self.userInteractionSwitch.withLock {
            let (status, allowed) = calls.userInteractionAllowed()
            guard status == errSecSuccess else {
                throw LocalRouterAccountKeyError.keychain(operation: "read", status: status)
            }
            if allowed {
                let turnedOff = calls.setUserInteractionAllowed(false)
                guard turnedOff == errSecSuccess else {
                    throw LocalRouterAccountKeyError.keychain(operation: "read", status: turnedOff)
                }
            }
            defer { if allowed { _ = calls.setUserInteractionAllowed(true) } }
            return try read()
        }
    }

    private static func contextThatMayNotAsk() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private enum Outcome<T> {
        case done(T)
        case failed(OSStatus)
    }

    /// The data-protection Keychain first; the login keychain when this build lacks the entitlement for it.
    private func withKeychain<T>(operation: String, _ body: (Bool) -> Outcome<T>) throws -> T {
        switch body(true) {
        case .done(let value):
            return value
        case .failed(let status) where status == errSecMissingEntitlement:
            switch body(false) {
            case .done(let value): return value
            case .failed(let status): throw LocalRouterAccountKeyError.keychain(operation: operation, status: status)
            }
        case .failed(let status):
            throw LocalRouterAccountKeyError.keychain(operation: operation, status: status)
        }
    }
}

/// The four `SecItem` calls the Keychain store makes, so tests can run its logic (the fallback, the attributes) against
/// a fake instead of a real Keychain.
struct KeychainItemCalls: Sendable {
    var copyMatching: @Sendable ([String: Any]) -> (OSStatus, Data?)
    var add: @Sendable ([String: Any]) -> OSStatus
    var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
    var delete: @Sendable ([String: Any]) -> OSStatus
    /// The legacy keychain's process-wide switch for asking the user, and setting it. Deprecated, but the only one
    /// legacy (login keychain) items follow: the query's UI keys apply to the data-protection keychain only
    /// (`SecItem.h`).
    var userInteractionAllowed: @Sendable () -> (OSStatus, Bool)
    var setUserInteractionAllowed: @Sendable (Bool) -> OSStatus
    var announceChange: @Sendable (String) -> Void

    static let system = KeychainItemCalls(
        copyMatching: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) },
        userInteractionAllowed: {
            var allowed: DarwinBoolean = true
            let status = SecKeychainGetUserInteractionAllowed(&allowed)
            return (status, allowed.boolValue)
        },
        setUserInteractionAllowed: { SecKeychainSetUserInteractionAllowed($0) },
        announceChange: { _ = notify_post($0) })
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
