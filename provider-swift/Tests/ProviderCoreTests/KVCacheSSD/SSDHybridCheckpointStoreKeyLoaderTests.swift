import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// The complete-checkpoint factory's code-only key-loader seam. It lets a
/// qualification test reopen its own isolated SSD files in a second process
/// without the Secure Enclave or Keychain, and must never apply outside the
/// isolated persistent-key test mode (so it can never key the product root).
@Suite("SSD complete-checkpoint store: injected test key loader")
struct SSDHybridCheckpointStoreKeyLoaderTests {
    private static let identity = CBv2CompleteCheckpointIdentity(
        modelAggregateHash: String(repeating: "a", count: 64),
        promptContractID: String(repeating: "c", count: 64),
        buildID: "key-loader-test", numericsFingerprint: "key-loader-test")

    private final class LoaderSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        var calls: Int { lock.withLock { count } }
        func load(_ namespace: SSDPersistentTestKeyNamespace?) throws -> SymmetricKey {
            lock.withLock { count += 1 }
            return key
        }
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ssd-key-loader-\(UUID().uuidString)", isDirectory: true)
    }

    private func environment(root: URL?, persistent: Bool) -> [String: String] {
        var env = ["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1"]
        if persistent { env["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"] = "1" }
        if let root { env[SSDPrefixCacheFactory.testRootEnvironmentKey] = root.path }
        return env
    }

    private func make(env: [String: String], spy: LoaderSpy) async -> SSDHybridCheckpointStore? {
        await SSDHybridCheckpointStoreFactory.make(
            modelId: "key-loader-model", identity: Self.identity,
            backendLayout: CBv2CompleteCheckpointManifest.pagedLayout,
            kvBudget: nil, environment: env,
            persistentLoader: { try spy.load($0) })
    }

    @Test("isolated persistent mode uses the injected key; a reopened store shares its epoch")
    func injectedKeyIsPersistentInIsolatedMode() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = LoaderSpy()
        let env = environment(root: root, persistent: true)
        let first = try #require(await make(env: env, spy: spy))
        #expect(!first.usesEphemeralKey)
        #expect(first.config.root.path.hasPrefix(root.standardizedFileURL.path))
        first.close()
        // Same key + identity + root: the epoch binding (key fingerprint)
        // accepts the reopened store instead of discarding the directory.
        let reopened = try #require(await make(env: env, spy: spy))
        #expect(!reopened.usesEphemeralKey)
        #expect(spy.calls == 2)
        reopened.close()
    }

    @Test("without the persistent-key flag the injected key is refused, never consulted")
    func ephemeralModeRefusesInjectedKey() async {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = LoaderSpy()
        #expect(await make(env: environment(root: root, persistent: false), spy: spy) == nil)
        #expect(spy.calls == 0)
    }

    @Test("without an isolated test root the injected key is refused (product root protected)")
    func productRootRefusesInjectedKey() async {
        let spy = LoaderSpy()
        #expect(await make(env: environment(root: nil, persistent: true), spy: spy) == nil)
        #expect(spy.calls == 0)
    }

    @Test("the default path is unchanged: isolated ephemeral mode stays ephemeral")
    func defaultIsolatedModeStaysEphemeral() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try #require(await SSDHybridCheckpointStoreFactory.make(
            modelId: "key-loader-model", identity: Self.identity,
            backendLayout: CBv2CompleteCheckpointManifest.pagedLayout,
            kvBudget: nil, environment: environment(root: root, persistent: false)))
        #expect(store.usesEphemeralKey)
        store.close()
    }
}
