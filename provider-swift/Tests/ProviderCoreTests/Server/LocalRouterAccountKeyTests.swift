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
