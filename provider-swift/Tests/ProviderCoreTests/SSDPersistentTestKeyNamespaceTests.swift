import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// All persistent calls are intercepted before Security/Keychain APIs.
/// These tests prove selection and refusal, not hardware persistence.
@Suite("Standalone SSD persistent test namespace")
struct SSDPersistentTestKeyNamespaceTests {
    private func namespace() throws -> SSDPersistentTestKeyNamespace {
        try .init(identifier: UUID(), accessGroup: "TESTTEAM.io.darkbloom.test")
    }

    private func environment(root: URL? = nil) -> [String: String] {
        [
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
            "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY": "1",
            SSDPrefixCacheFactory.testRootEnvironmentKey: (root ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("ssd-persistent-test-\(UUID().uuidString)", isDirectory: true)).path,
        ]
    }

    @Test("one UUID binds every key selector and survives value reconstruction")
    func selectorsAreCompleteAndStable() throws {
        let first = try namespace()
        let restored = try SSDPersistentTestKeyNamespace(
            identifier: #require(UUID(uuidString: first.identifier.uuidString)), accessGroup: first.accessGroup)
        let other = try namespace()
        #expect(first == restored)
        #expect(first.enclaveLabel == restored.enclaveLabel)
        #expect(first.wrappedKEKService == restored.wrappedKEKService)
        #expect(first.wrappedKEKAccount == restored.wrappedKEKAccount)
        #expect(first.enclaveLabel != PersistentEnclaveKey.defaultLabel)
        #expect(first.wrappedKEKService != KeychainWrappedKEKStorage.defaultService)
        #expect(first.wrappedKEKAccount != KeychainWrappedKEKStorage.defaultAccount)
        #expect(first.enclaveLabel != other.enclaveLabel)
        #expect(first.wrappedKEKService != other.wrappedKEKService)
        #expect(first.wrappedKEKAccount != other.wrappedKEKAccount)
    }

    @Test("access group must be concrete; validation does not confer entitlement", arguments: [
        "", " ", "TESTTEAM", "TESTTEAM.*", "TESTTEAM..cache", " TESTTEAM.cache", "TESTTEAM.cache\n",
    ])
    func malformedAccessGroupIsRefused(group: String) {
        #expect(throws: SSDPersistentTestKeyNamespace.Failure.invalidAccessGroup) {
            try SSDPersistentTestKeyNamespace(identifier: UUID(), accessGroup: group)
        }
    }

    @Test("partial mode and unsafe roots are refused before any key call")
    func invalidContextsDoNotReachKeys() async throws {
        let selected = try namespace()
        let complete = environment()
        var cases = [[String: String]]()
        for flag in ["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL", "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY",
                     SSDPrefixCacheFactory.testRootEnvironmentKey] {
            var missing = complete
            missing.removeValue(forKey: flag)
            cases.append(missing)
        }
        let normal = SSDPrefixCacheFactory.cacheRootDirectory(environment: [:])
        let unsafe = ["", "relative/root", "/", normal.path, normal.path.uppercased(),
                      normal.appendingPathComponent("test").path,
                      normal.deletingLastPathComponent().path,
                      normal.deletingLastPathComponent().appendingPathComponent("kv").path]
        for root in unsafe {
            var changed = complete
            changed[SSDPrefixCacheFactory.testRootEnvironmentKey] = root
            cases.append(changed)
        }
        for context in cases {
            let spy = PersistentKeyLoaderSpy()
            await #expect(throws: SSDPersistentTestKeyNamespace.Failure.self) {
                try await SSDPrefixCacheFactory.loadKeyMaterial(
                    environment: context, persistentTestNamespace: selected,
                    persistentLoader: { try await spy.load($0) })
            }
            #expect(await spy.selections.isEmpty)
        }
        #expect(throws: SSDPersistentTestKeyNamespace.Failure.persistentModeRequired) {
            try selected.validate(environment: complete, requirePersistentKey: false)
        }
    }

    @Test("a symlink alias into the normal cache hierarchy is refused")
    func aliasedProductionRootIsRefused() throws {
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssd-namespace-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: owned) }
        let normal = SSDPrefixCacheFactory.cacheRootDirectory(environment: [:])
        let caches = normal.deletingLastPathComponent().deletingLastPathComponent()
        let alias = owned.appendingPathComponent("cache-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: caches)
        let root = alias.appendingPathComponent(SSDPrefixCacheFactory.ssdRootDirectoryName, isDirectory: true)
        #expect(throws: SSDPersistentTestKeyNamespace.Failure.unsafeIsolatedRoot) {
            try namespace().validate(environment: environment(root: root))
        }
    }

    @Test("missing leaves cannot conceal candidate or protected ancestor aliases")
    func missingLeavesResolveBothSides() throws {
        let owned = try ownedFixture()
        defer { try? FileManager.default.removeItem(at: owned) }
        let real = owned.appendingPathComponent("real", isDirectory: true)
        let alias = owned.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let unresolved = alias.appendingPathComponent("missing/payload", isDirectory: true)
        let protected = real.appendingPathComponent("missing/payload", isDirectory: true)
        for (candidate, protectedRoot) in [
            (unresolved, protected),
            (unresolved.appendingPathComponent("child"), protected),
            (protected, unresolved.appendingPathComponent("child")),
            (protected, unresolved),
        ] {
            #expect(throws: SSDPersistentTestKeyNamespace.Failure.unsafeIsolatedRoot) {
                try SSDPersistentTestKeyNamespace.validateIsolatedRoot(
                    candidate.path, protectedRoots: [protectedRoot])
            }
        }
        #expect(!FileManager.default.fileExists(atPath: protected.path))
    }

    @Test("an isolated missing descendant is accepted without directory creation")
    func safeMissingRootStaysUncreated() throws {
        let owned = try ownedFixture()
        defer { try? FileManager.default.removeItem(at: owned) }
        let real = owned.appendingPathComponent("real", isDirectory: true)
        let alias = owned.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let candidate = alias.appendingPathComponent("new/root", isDirectory: true)
        try SSDPersistentTestKeyNamespace.validateIsolatedRoot(
            candidate.path, protectedRoots: [owned.appendingPathComponent("protected/root")])
        #expect(!FileManager.default.fileExists(atPath: real.appendingPathComponent("new").path))
    }

    @Test("dangling, cyclic and non-directory ancestors refuse before key loading")
    func invalidFilesystemAncestorsDoNotReachKeys() async throws {
        let owned = try ownedFixture()
        defer { try? FileManager.default.removeItem(at: owned) }
        let dangling = owned.appendingPathComponent("dangling")
        let cycleA = owned.appendingPathComponent("cycle-a")
        let cycleB = owned.appendingPathComponent("cycle-b")
        let file = owned.appendingPathComponent("regular-file")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: owned.appendingPathComponent("absent"))
        try FileManager.default.createSymbolicLink(at: cycleA, withDestinationURL: cycleB)
        try FileManager.default.createSymbolicLink(at: cycleB, withDestinationURL: cycleA)
        try Data().write(to: file)
        for root in [dangling, dangling.appendingPathComponent("child"),
                     cycleA, cycleA.appendingPathComponent("child"),
                     file, file.appendingPathComponent("child")] {
            let spy = PersistentKeyLoaderSpy()
            await #expect(throws: SSDPersistentTestKeyNamespace.Failure.unsafeIsolatedRoot) {
                try await SSDPrefixCacheFactory.loadKeyMaterial(
                    environment: environment(root: root), persistentTestNamespace: namespace(),
                    persistentLoader: { try await spy.load($0) })
            }
            #expect(await spy.selections.isEmpty)
            #expect(throws: SSDPersistentTestKeyNamespace.Failure.unsafeIsolatedRoot) {
                try SSDPersistentTestKeyNamespace.validateIsolatedRoot(
                    owned.appendingPathComponent("safe").path, protectedRoots: [root])
            }
        }
    }

    @Test("raw traversal components refuse before URL normalization or key loading")
    func rawTraversalDoNotReachKeys() async throws {
        let owned = try ownedFixture()
        defer { try? FileManager.default.removeItem(at: owned) }
        for suffix in ["/./root", "/child/../root", "/../root"] {
            var context = environment()
            context[SSDPrefixCacheFactory.testRootEnvironmentKey] = owned.path + suffix
            let spy = PersistentKeyLoaderSpy()
            await #expect(throws: SSDPersistentTestKeyNamespace.Failure.unsafeIsolatedRoot) {
                try await SSDPrefixCacheFactory.loadKeyMaterial(
                    environment: context, persistentTestNamespace: namespace(),
                    persistentLoader: { try await spy.load($0) })
            }
            #expect(await spy.selections.isEmpty)
        }
    }

    private func ownedFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssd-namespace-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("both SSD factories reject before creating the payload root")
    func factoriesValidateBeforeRootCreation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssd-namespace-no-io-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var context = environment(root: root)
        context.removeValue(forKey: "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY")
        let selected = try namespace()
        let layers = [CBv2LayerKind(attention: .full, headDim: 8, kvHeads: 2, queryHeads: 4)]
        let capability = PrefixCachePolicy.prefixReuseCapability(layerKinds: layers, backendSelection: .paged)
        #expect(capability.isSupported)
        let blocks = await SSDPrefixCacheFactory.make(
            modelId: "namespace-test", promptContractID: "test-contract", weightHash: "test-weights",
            layerKinds: layers, prefixReuseCapability: capability, kvBudget: nil,
            environment: context, persistentTestNamespace: selected)
        #expect(blocks == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let complete = await SSDHybridCheckpointStoreFactory.make(
            modelId: "namespace-test", identity: .init(modelAggregateHash: "test-weights",
                promptContractID: "test-contract", buildID: "test-build", numericsFingerprint: "test-numerics"),
            kvBudget: nil, environment: context, persistentTestNamespace: selected)
        #expect(complete == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("valid persistent test forwards the complete namespace")
    func selectedNamespaceReachesPersistentLoader() async throws {
        let selected = try namespace()
        let spy = PersistentKeyLoaderSpy()
        let material = try await SSDPrefixCacheFactory.loadKeyMaterial(
            environment: environment(), persistentTestNamespace: selected,
            persistentLoader: { try await spy.load($0) })
        #expect(!material.ephemeral)
        #expect(material.key.bitCount == 256)
        #expect(await spy.selections == [selected])
    }

    @Test("namespaced failure refuses ephemeral fallback despite the root opt-in")
    func persistentTestFailureIsClosed() async throws {
        let selected = try namespace()
        let spy = PersistentKeyLoaderSpy(fail: true)
        await #expect(throws: SSDCacheKeyMaterial.Failure.self) {
            try await SSDPrefixCacheFactory.loadKeyMaterial(
                environment: environment(), persistentTestNamespace: selected,
                persistentLoader: { try await spy.load($0) })
        }
        #expect(await spy.selections == [selected])
        let forcedSpy = PersistentKeyLoaderSpy()
        var ephemeralContext = environment()
        ephemeralContext.removeValue(forKey: "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY")
        await #expect(throws: SSDPersistentTestKeyNamespace.Failure.persistentModeRequired) {
            try await SSDCacheKeyMaterial.load(
                environment: ephemeralContext, persistentTestNamespace: selected,
                persistentLoader: { try await forcedSpy.load($0) })
        }
        #expect(await forcedSpy.selections.isEmpty)
    }

    @Test("nil namespace retains production selection and explicit fallback behavior")
    func productionSelectionIsUnchanged() async throws {
        let production = PersistentKeyLoaderSpy()
        let normal = try await SSDPrefixCacheFactory.loadKeyMaterial(
            environment: [:], persistentLoader: { try await production.load($0) })
        #expect(!normal.ephemeral)
        #expect(await production.selections == [nil])
        let unavailable = PersistentKeyLoaderSpy(fail: true)
        await #expect(throws: SSDCacheKeyMaterial.Failure.self) {
            try await SSDPrefixCacheFactory.loadKeyMaterial(
                environment: [:], persistentLoader: { try await unavailable.load($0) })
        }
        #expect(await unavailable.selections.count == 1)
        let allowed = PersistentKeyLoaderSpy(fail: true)
        let fallback = try await SSDPrefixCacheFactory.loadKeyMaterial(
            environment: ["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1"],
            persistentLoader: { try await allowed.load($0) })
        #expect(fallback.ephemeral)
        #expect(await allowed.selections.count == 1)
    }

    @Test("ordinary isolated tests still bypass the persistent hierarchy")
    func ordinaryTestRootStaysEphemeral() async throws {
        var context = environment()
        context.removeValue(forKey: "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY")
        let spy = PersistentKeyLoaderSpy()
        let material = try await SSDPrefixCacheFactory.loadKeyMaterial(
            environment: context, persistentLoader: { try await spy.load($0) })
        #expect(material.ephemeral)
        #expect(await spy.selections.isEmpty)
    }
}

private actor PersistentKeyLoaderSpy {
    enum Failure: Error { case unavailable }
    let fail: Bool
    private(set) var selections = [SSDPersistentTestKeyNamespace?]()

    init(fail: Bool = false) { self.fail = fail }

    func load(_ namespace: SSDPersistentTestKeyNamespace?) throws -> SymmetricKey {
        selections.append(namespace)
        if fail { throw Failure.unavailable }
        return SymmetricKey(size: .bits256)
    }
}
