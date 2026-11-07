import Foundation
import LocalAuthentication
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

    // MARK: - A read never waits on a Keychain dialog

    /// A login-keychain item this build may not read without approval (an ad-hoc rebuild changes the binary the item
    /// trusts) would show a dialog, and a request would wait on it. The query's UI keys don't reach legacy items, so
    /// the login-keychain read runs with the legacy keychain's process-wide switch off, put back after: it fails at
    /// once instead. The data-protection read before it doesn't touch the switch.
    @Test func aLoginKeychainReadNeverWaitsOnAKeychainDialog() throws {
        let keychain = FakeKeychain(entitled: false)
        keychain.loginItems["svc.test/acct"] = Data("sk-fake".utf8)
        keychain.loginNeedsApproval = true
        let store = KeychainLocalRouterAccountKeyStore(service: "svc.test", account: "acct", calls: keychain.calls)
        #expect(throws: LocalRouterAccountKeyError.keychain(operation: "read", status: errSecAuthFailed)) {
            try store.load()
        }
        #expect(keychain.prompts == 0)
        #expect(keychain.reads.map(\.keychain) == ["dp", "login"])
        #expect(keychain.reads.map(\.interactionAllowed) == [true, false], "off for the login keychain only")
        #expect(keychain.interactionAllowed, "the switch is put back")
        #expect(keychain.switchChanges == [false, true])
        // The data-protection read carries a context that may not ask either.
        let dataProtection = try #require(keychain.reads.first?.query)
        let context = try #require(dataProtection[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(context.interactionNotAllowed)
    }

    /// A signed build reads the data-protection Keychain only, which the switch doesn't govern: it never reads or sets
    /// the switch, so a request in a signed build never takes its lock either.
    @Test func aSignedBuildsReadNeverTouchesTheSwitch() throws {
        let keychain = FakeKeychain(entitled: true)
        keychain.dataProtectionItems["svc.test/acct"] = Data("sk-fake".utf8)
        keychain.switchFailure = errSecNotAvailable
        let store = KeychainLocalRouterAccountKeyStore(service: "svc.test", account: "acct", calls: keychain.calls)
        #expect(try store.load() == "sk-fake")
        #expect(keychain.switchReads == 0 && keychain.switchChanges.isEmpty)
        #expect(keychain.reads.map(\.keychain) == ["dp"])
    }

    @Test func aSwitchThatIsAlreadyOffIsLeftOff() throws {
        let keychain = FakeKeychain(entitled: false)
        keychain.interactionAllowed = false
        let store = KeychainLocalRouterAccountKeyStore(service: "svc.test", account: "acct", calls: keychain.calls)
        #expect(try store.load() == nil)
        #expect(keychain.reads.map(\.keychain) == ["dp", "login"])
        #expect(keychain.switchChanges.isEmpty)
        #expect(!keychain.interactionAllowed)
    }

    @Test func aLoginKeychainReadWhoseSwitchCantBeTurnedOffDoesNotRun() throws {
        let keychain = FakeKeychain(entitled: false)
        keychain.switchFailure = errSecNotAvailable
        let store = KeychainLocalRouterAccountKeyStore(service: "svc.test", account: "acct", calls: keychain.calls)
        #expect(throws: LocalRouterAccountKeyError.keychain(operation: "read", status: errSecNotAvailable)) {
            try store.load()
        }
        #expect(keychain.reads.map(\.keychain) == ["dp"])
    }

    // MARK: - A change is announced

    /// Saving or removing the key posts the identity's change notification, so a running local API reads it again;
    /// a refused save posts nothing.
    @Test func savingOrRemovingTheKeyAnnouncesIt() throws {
        #expect(KeychainLocalRouterAccountKeyStore().changeNotification
            == BuildEnvironment.current.keychainServicePrefix + ".route-key-changed")
        let keychain = FakeKeychain(entitled: true)
        let store = KeychainLocalRouterAccountKeyStore(service: "svc.test", account: "acct", calls: keychain.calls)
        try store.save("sk-fake")
        #expect(keychain.announced == ["svc.test-key-changed"])
        try store.remove()
        #expect(keychain.announced == ["svc.test-key-changed", "svc.test-key-changed"])
        _ = try store.load()
        #expect(keychain.announced.count == 2, "a read announces nothing")
        let refusing = FakeKeychain(entitled: true, failing: errSecAuthFailed)
        let refused = KeychainLocalRouterAccountKeyStore(service: "svc.test", account: "acct", calls: refusing.calls)
        #expect(throws: LocalRouterAccountKeyError.self) { try refused.save("sk-fake") }
        #expect(throws: LocalRouterAccountKeyError.self) { try refused.remove() }
        #expect(refusing.announced.isEmpty)
    }

    /// `route key` runs at a terminal, where approving a new build is how it gets the key back: saving and removing
    /// may still ask, and never touch the switch.
    @Test func savingAndRemovingAtTheTerminalMayStillAsk() throws {
        let keychain = FakeKeychain(entitled: false)
        keychain.loginItems["svc.test/acct"] = Data("sk-old".utf8)
        keychain.loginNeedsApproval = true
        let store = KeychainLocalRouterAccountKeyStore(service: "svc.test", account: "acct", calls: keychain.calls)
        try store.save("sk-new")
        try store.remove()
        #expect(keychain.prompts == 2)
        #expect(keychain.switchChanges.isEmpty)
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

/// The Keychain calls, in memory: a data-protection Keychain (refused with `errSecMissingEntitlement` unless
/// `entitled`, as for a build without the access-group entitlement) and a login keychain, keyed by service/account,
/// with the legacy keychain's process-wide switch for asking the user.
final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    let entitled: Bool
    /// When set, every data-protection call fails with this status.
    let failing: OSStatus?
    var dataProtectionItems: [String: Data] = [:]
    var loginItems: [String: Data] = [:]
    private(set) var log: [String] = []
    private(set) var added: [[String: Any]] = []
    /// The legacy keychain's switch for asking the user, as `SecKeychainGetUserInteractionAllowed` reads it.
    var interactionAllowed = true
    /// When set, reading or setting the switch fails with this status.
    var switchFailure: OSStatus?
    private(set) var switchReads = 0
    private(set) var switchChanges: [Bool] = []
    /// The change notifications posted.
    private(set) var announced: [String] = []
    /// The login keychain's items need the user's approval for this build, as after an ad-hoc rebuild: with the
    /// switch on, a call asks (`prompts`, and the fake approves); with it off, it fails with `errSecAuthFailed`.
    var loginNeedsApproval = false
    private(set) var prompts = 0
    /// Every read: the keychain it went to, whether the switch allowed asking then, and its query.
    private(set) var reads: [(keychain: String, interactionAllowed: Bool, query: [String: Any])] = []

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

    /// A login item this build needs approval for: asked for when the switch allows it, else refused.
    private func approval(_ name: String) -> OSStatus? {
        guard name == "login", loginNeedsApproval else { return nil }
        guard interactionAllowed else { return errSecAuthFailed }
        prompts += 1
        return nil
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
                    self.reads.append((name, self.interactionAllowed, query))
                    if let refusal { return (refusal, nil) }
                    guard let data = self.items(name)[self.id(query)] else { return (errSecItemNotFound, nil) }
                    if let refusal = self.approval(name) { return (refusal, nil) }
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
                    if let refusal = self.approval(name) { return refusal }
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
                    if let refusal = self.approval(name) { return refusal }
                    self.setItem(name, self.id(query), nil)
                    return errSecSuccess
                }
            },
            userInteractionAllowed: {
                self.lock.withLock {
                    self.switchReads += 1
                    return (self.switchFailure ?? errSecSuccess, self.interactionAllowed)
                }
            },
            setUserInteractionAllowed: { allowed in
                self.lock.withLock {
                    if let failure = self.switchFailure { return failure }
                    self.switchChanges.append(allowed)
                    self.interactionAllowed = allowed
                    return errSecSuccess
                }
            },
            announceChange: { name in self.lock.withLock { self.announced.append(name) } })
    }
}
