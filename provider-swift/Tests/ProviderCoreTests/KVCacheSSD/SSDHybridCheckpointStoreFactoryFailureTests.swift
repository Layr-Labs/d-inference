import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Every refusal returns a typed reason instead of a bare nil. Key loading is
/// intercepted before Security/Keychain APIs; roots are isolated temporaries.
@Suite("Complete-checkpoint store factory reports typed refusals")
struct SSDHybridCheckpointStoreFactoryFailureTests {
    private let identity = CBv2CompleteCheckpointIdentity(modelAggregateHash: "test-weights",
        promptContractID: "test-contract", buildID: "test-build", numericsFingerprint: "test-numerics")

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ssd-complete-failure-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func refusal(_ result: Result<SSDHybridCheckpointStore, SSDHybridCheckpointStoreFactory.ConstructionFailure>)
        -> SSDHybridCheckpointStoreFactory.ConstructionFailure?
    {
        guard case .failure(let failure) = result else { return nil }
        return failure
    }

    @Test("a persistent key failure is reported as key_unavailable with its typed cause")
    func keyFailureIsTyped() async throws {
        let root = temporaryRoot("key")
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
            try? FileManager.default.removeItem(at: root)
        }
        // A namespace refuses the ephemeral fallback that the test root opt-in
        // would otherwise permit, so the loader failure reaches the factory.
        let selected = try SSDPersistentTestKeyNamespace(identifier: UUID(), accessGroup: "TESTTEAM.io.darkbloom.test")
        let environment = [
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
            "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY": "1",
            SSDPrefixCacheFactory.testRootEnvironmentKey: root.path,
        ]
        let loader = FailingKeyLoader()
        let result = await SSDHybridCheckpointStoreFactory.build(
            modelId: "key-failure", identity: identity, kvBudget: nil, environment: environment,
            persistentTestNamespace: selected, persistentKeyLoader: { try await loader.load($0) })
        let failure = try #require(refusal(result))
        #expect(failure.reason == .keyUnavailable)
        #expect(failure.detail == "persistent key unavailable: \(PersistentEnclaveKeyError.missingEntitlement)")
        #expect(await loader.calls == 1)
    }

    @Test("an unusable payload root is reported as unsafe_path before key loading")
    func directoryRefusalIsTyped() async throws {
        let parent = temporaryRoot("path")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: file)
        let loader = FailingKeyLoader()
        let result = await SSDHybridCheckpointStoreFactory.build(
            modelId: "path-failure", identity: identity, kvBudget: nil,
            environment: ["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
                          SSDPrefixCacheFactory.testRootEnvironmentKey: file.path],
            persistentKeyLoader: { try await loader.load($0) })
        #expect(refusal(result)?.reason == .unsafePath)
        #expect(await loader.calls == 0)
    }

    @Test("identity and layout refusals are typed and touch no storage")
    func contractRefusalsAreTyped() async {
        let root = temporaryRoot("contract")
        let environment = ["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
                           SSDPrefixCacheFactory.testRootEnvironmentKey: root.path]
        let blank = CBv2CompleteCheckpointIdentity(modelAggregateHash: "", promptContractID: "test-contract",
            buildID: "test-build", numericsFingerprint: "test-numerics")
        let blankIdentity = await SSDHybridCheckpointStoreFactory.build(
            modelId: "contract", identity: blank, kvBudget: nil, environment: environment)
        let unknownLayout = await SSDHybridCheckpointStoreFactory.build(
            modelId: "contract", identity: identity, backendLayout: "unregistered-layout-v0",
            kvBudget: nil, environment: environment)
        let unbudgetedDiffusion = await SSDHybridCheckpointStoreFactory.build(
            modelId: "contract", identity: identity,
            backendLayout: CBv2CompleteCheckpointManifest.diffusionBlockLayout,
            kvBudget: nil, environment: environment)
        #expect(refusal(blankIdentity) == .init(reason: .identityUnavailable, detail: nil))
        #expect(refusal(unknownLayout) == .init(reason: .layoutUnavailable, detail: nil))
        #expect(refusal(unbudgetedDiffusion) == .init(reason: .layoutUnavailable, detail: nil))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("an error status keeps the wire reason and carries the typed refusal locally")
    func statusCarriesLocalFailure() {
        let box = PrefixCacheConstructionStatusBox()
        box.record(failure: .keyUnavailable, capability: PrefixCachePolicy.prefixReuseCapability(
            layerKinds: [CBv2LayerKind(attention: .full, headDim: 8, kvHeads: 2, queryHeads: 4)],
            backendSelection: .paged))
        let status = box.snapshot
        #expect(status?.state == .error)
        #expect(status?.reason == .cacheInitFailed)
        #expect(status?.failure == .keyUnavailable)
    }
}

private actor FailingKeyLoader {
    private(set) var calls = 0

    func load(_ namespace: SSDPersistentTestKeyNamespace?) throws -> SymmetricKey {
        calls += 1
        throw PersistentEnclaveKeyError.missingEntitlement
    }
}
