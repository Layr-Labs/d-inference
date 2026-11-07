import Foundation
import Security
import Testing
@testable import ProviderCore

/// The account key store. The Keychain round trip runs only with `DARKBLOOM_TEST_KEYCHAIN=1`, under a service name
/// of its own (never an install's `.route` item), and removes what it made.
@Suite("Local router account key")
struct LocalRouterAccountKeyTests {
    @Test func eachInstallKeepsItsKeyUnderItsOwnService() {
        #expect(KeychainLocalRouterAccountKeyStore.defaultService
            == BuildEnvironment.current.keychainServicePrefix + ".route")
        #expect(KeychainLocalRouterAccountKeyStore.defaultAccount == "account-api-key")
    }

    @Test func theInMemoryStoreSavesReplacesAndRemoves() throws {
        let store = InMemoryLocalRouterAccountKeyStore()
        #expect(try store.load() == nil)
        try store.save("sk-one")
        try store.save("sk-two")
        #expect(try store.load() == "sk-two")
        try store.remove()
        try store.remove()
        #expect(try store.load() == nil)
    }

    @Test func aKeychainFailureNamesNoKey() {
        let error = LocalRouterAccountKeyError.keychain(operation: "read", status: errSecInteractionNotAllowed)
        #expect(error.description == "the Keychain could not read the account key (OSStatus \(errSecInteractionNotAllowed))")
    }

    // MARK: - The Keychain store's own logic, behind a fake (no real Keychain call)

    @Test func aBuildWithoutTheKeychainEntitlementUsesTheLoginKeychain() throws {
        let keychain = FakeKeychain(entitled: false)
        let store = KeychainLocalRouterAccountKeyStore(service: "svc.test", account: "acct", calls: keychain.calls)
        #expect(try store.load() == nil)
        try store.save("sk-fake-one")
        #expect(try store.load() == "sk-fake-one")
        try store.save("sk-fake-two")
        #expect(try store.load() == "sk-fake-two")
        try store.remove()
        #expect(try store.load() == nil)
        // Every call tried the data-protection Keychain first, then the login keychain.
        #expect(keychain.log.allSatisfy { $0.hasSuffix("dp") || $0.hasSuffix("login") })
        #expect(keychain.log.prefix(2) == ["copy dp", "copy login"])
        #expect(keychain.log.contains("add login") && !keychain.log.contains("add dp"))
        #expect(keychain.loginItems.isEmpty && keychain.dataProtectionItems.isEmpty)
    }

    @Test func aSignedBuildKeepsTheKeyInTheDataProtectionKeychainOnly() throws {
        let keychain = FakeKeychain(entitled: true)
        let store = KeychainLocalRouterAccountKeyStore(service: "svc.test", account: "acct", calls: keychain.calls)
        try store.save("sk-fake")
        #expect(try store.load() == "sk-fake")
        #expect(keychain.dataProtectionItems["svc.test/acct"] == Data("sk-fake".utf8))
        #expect(!keychain.log.contains { $0.hasSuffix("login") })
    }

    @Test func aNewItemStaysOnThisMacUnsynchronisedAndLabelled() throws {
        let keychain = FakeKeychain(entitled: true)
        let store = KeychainLocalRouterAccountKeyStore(service: "svc.test", account: "acct", calls: keychain.calls)
        try store.save("sk-fake")
        let added = try #require(keychain.added.first)
        #expect(added[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(added[kSecAttrService as String] as? String == "svc.test")
        #expect(added[kSecAttrAccount as String] as? String == "acct")
        #expect(added[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(added[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(added[kSecAttrLabel as String] as? String == "Darkbloom account API key (local router)")
        #expect(added[kSecUseDataProtectionKeychain as String] as? Bool == true)
        // A second save updates the item in place.
        try store.save("sk-fake-2")
        #expect(keychain.added.count == 1 && keychain.log.last == "update dp")
    }

    @Test func onlyAMissingEntitlementFallsBackToTheLoginKeychain() throws {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            let keychain = FakeKeychain(entitled: true, failing: status)
            let store = KeychainLocalRouterAccountKeyStore(service: "svc.test", account: "acct", calls: keychain.calls)
            #expect(throws: LocalRouterAccountKeyError.keychain(operation: "read", status: status)) { try store.load() }
            #expect(throws: LocalRouterAccountKeyError.keychain(operation: "save", status: status)) { try store.save("k") }
            #expect(throws: LocalRouterAccountKeyError.keychain(operation: "remove", status: status)) { try store.remove() }
            #expect(!keychain.log.contains { $0.hasSuffix("login") }, "\(status)")
        }
    }

    @Test func anEmptyItemReadsAsNoKey() throws {
        let keychain = FakeKeychain(entitled: true)
        keychain.dataProtectionItems["svc.test/acct"] = Data()
        let store = KeychainLocalRouterAccountKeyStore(service: "svc.test", account: "acct", calls: keychain.calls)
        #expect(try store.load() == nil)
        try store.remove()
        try store.remove()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_KEYCHAIN"] == "1"))
    func theKeychainStoreRoundTripsUnderATestService() throws {
        let store = KeychainLocalRouterAccountKeyStore(service: "io.darkbloom.test.local-router.\(UUID().uuidString)",
                                                       account: "account-api-key")
        defer { try? store.remove() }
        #expect(try store.load() == nil)
        try store.save("sk-keychain-fixture-one")
        #expect(try store.load() == "sk-keychain-fixture-one")
        try store.save("sk-keychain-fixture-two")
        #expect(try store.load() == "sk-keychain-fixture-two")
        try store.remove()
        #expect(try store.load() == nil)
    }
}

/// The four Keychain calls, in memory: a data-protection Keychain (refused with `errSecMissingEntitlement` unless
/// `entitled`, as for a build without the access-group entitlement) and a login keychain, keyed by service/account.
final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    let entitled: Bool
    /// When set, every data-protection call fails with this status.
    let failing: OSStatus?
    var dataProtectionItems: [String: Data] = [:]
    var loginItems: [String: Data] = [:]
    private(set) var log: [String] = []
    private(set) var added: [[String: Any]] = []

    init(entitled: Bool, failing: OSStatus? = nil) {
        self.entitled = entitled
        self.failing = failing
    }

    private func keychain(_ query: [String: Any]) -> (name: String, refusal: OSStatus?) {
        if query[kSecUseDataProtectionKeychain as String] as? Bool == true {
            return ("dp", failing ?? (entitled ? nil : errSecMissingEntitlement))
        }
        return ("login", nil)
    }

    private func id(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String] as? String ?? "")/\(query[kSecAttrAccount as String] as? String ?? "")"
    }

    private func items(_ name: String) -> [String: Data] { name == "dp" ? dataProtectionItems : loginItems }
    private func setItem(_ name: String, _ id: String, _ data: Data?) {
        if name == "dp" { dataProtectionItems[id] = data } else { loginItems[id] = data }
    }

    var calls: KeychainItemCalls {
        KeychainItemCalls(
            copyMatching: { query in
                self.lock.withLock {
                    let (name, refusal) = self.keychain(query)
                    self.log.append("copy \(name)")
                    if let refusal { return (refusal, nil) }
                    guard let data = self.items(name)[self.id(query)] else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, data)
                }
            },
            add: { item in
                self.lock.withLock {
                    let (name, refusal) = self.keychain(item)
                    self.log.append("add \(name)")
                    if let refusal { return refusal }
                    guard self.items(name)[self.id(item)] == nil else { return errSecDuplicateItem }
                    self.added.append(item)
                    self.setItem(name, self.id(item), item[kSecValueData as String] as? Data)
                    return errSecSuccess
                }
            },
            update: { query, attributes in
                self.lock.withLock {
                    let (name, refusal) = self.keychain(query)
                    self.log.append("update \(name)")
                    if let refusal { return refusal }
                    guard self.items(name)[self.id(query)] != nil else { return errSecItemNotFound }
                    self.setItem(name, self.id(query), attributes[kSecValueData as String] as? Data)
                    return errSecSuccess
                }
            },
            delete: { query in
                self.lock.withLock {
                    let (name, refusal) = self.keychain(query)
                    self.log.append("delete \(name)")
                    if let refusal { return refusal }
                    guard self.items(name)[self.id(query)] != nil else { return errSecItemNotFound }
                    self.setItem(name, self.id(query), nil)
                    return errSecSuccess
                }
            })
    }
}
