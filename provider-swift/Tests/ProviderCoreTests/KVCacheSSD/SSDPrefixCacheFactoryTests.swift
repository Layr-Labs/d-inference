import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Records every construction failure that the factory reports.
private final class ConstructionFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SSDPrefixCacheConstructionFailure] = []

    func record(_ failure: SSDPrefixCacheConstructionFailure) {
        lock.withLock { values.append(failure) }
    }

    var snapshot: [SSDPrefixCacheConstructionFailure] { lock.withLock { values } }
}

/// A parent folder under the temporary directory. The test root sits inside
/// it and is not created, so each test can check what the factory creates.
private func factoryParent(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("ssd-factory-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Isolated test root plus the ephemeral-key opt-in. No persistent key flag,
/// so key loading stays in memory and never reaches the Keychain.
private func isolatedEnvironment(
    root: URL, extra: [String: String] = [:]
) -> [String: String] {
    var environment = [
        "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
        SSDPrefixCacheFactory.testRootEnvironmentKey: root.path,
    ]
    for (key, value) in extra { environment[key] = value }
    return environment
}

private let fullLayers = [
    CBv2LayerKind(attention: .full, headDim: 8, kvHeads: 2, queryHeads: 4)
]

private let windowedLayers = [
    CBv2LayerKind(attention: .slidingWindow(256), headDim: 8, kvHeads: 2, queryHeads: 4),
    CBv2LayerKind(attention: .full, headDim: 8, kvHeads: 2, queryHeads: 4),
]

@Suite("SSD prefix cache factory: paths and flags")
struct SSDPrefixCacheFactoryPathTests {

    @Test("ephemeral opt-in accepts only the documented true words")
    func ephemeralAllowedWords() {
        let key = "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"
        for accepted in ["1", "true", "TRUE", "yes", "Yes", "on", " on ", "\ttrue\t"] {
            #expect(SSDPrefixCacheFactory.ephemeralAllowed(environment: [key: accepted]), "\(accepted)")
        }
        for refused in ["", "0", "false", "no", "off", "enabled", "2", "on\n"] {
            #expect(!SSDPrefixCacheFactory.ephemeralAllowed(environment: [key: refused]), "\(refused)")
        }
        #expect(!SSDPrefixCacheFactory.ephemeralAllowed(environment: [:]))
    }

    @Test("model folder name is the first 12 hex digits of the model id hash")
    func cacheDirectoryUsesHashPrefix() throws {
        let parent = try factoryParent("model-dir")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("kv3", isDirectory: true)
        let environment = isolatedEnvironment(root: root)

        let abc = SSDPrefixCacheFactory.cacheDirectory(modelId: "abc", environment: environment)
        #expect(abc.lastPathComponent == "ba7816bf8f01")
        #expect(abc.deletingLastPathComponent().path == root.standardizedFileURL.path)

        let empty = SSDPrefixCacheFactory.cacheDirectory(modelId: "", environment: environment)
        #expect(empty.lastPathComponent == "e3b0c44298fc")

        let modelId = "example/model-7b"
        let expected = SHA256.hash(data: Data(modelId.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(12)
        let dir = SSDPrefixCacheFactory.cacheDirectory(modelId: modelId, environment: environment)
        #expect(dir.lastPathComponent == String(expected))
        #expect(dir.lastPathComponent.count == 12)
        #expect(
            SSDPrefixCacheFactory.cacheDirectory(modelId: modelId, environment: environment)
                == dir)
        #expect(
            SSDPrefixCacheFactory.cacheDirectory(modelId: "other-model", environment: environment)
                != dir)
        // Path computation alone creates nothing.
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("without the isolated root the cache root is the user caches folder")
    func normalRootIsCachesFolder() throws {
        let caches = try #require(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let expected = caches.appendingPathComponent(
            SSDPrefixCacheFactory.ssdRootDirectoryName, isDirectory: true)
        #expect(SSDPrefixCacheFactory.cacheRootDirectory(environment: [:]).path == expected.path)
        #expect(SSDPrefixCacheFactory.cacheRootDirectory(environment: [:]).path.hasSuffix("/darkbloom/kv3"))
        // A blank test root falls back to the normal root.
        let blank = [
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
            SSDPrefixCacheFactory.testRootEnvironmentKey: "  \n",
        ]
        #expect(SSDPrefixCacheFactory.cacheRootDirectory(environment: blank).path == expected.path)
        #expect(!SSDPrefixCacheFactory.forceEphemeralKey(environment: blank))
        // The test root is ignored when the ephemeral opt-in is off.
        let notAllowed = [
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "0",
            SSDPrefixCacheFactory.testRootEnvironmentKey: "/private/tmp/ssd-factory-ignored",
        ]
        #expect(SSDPrefixCacheFactory.cacheRootDirectory(environment: notAllowed).path == expected.path)
        #expect(!SSDPrefixCacheFactory.forceEphemeralKey(environment: notAllowed))
    }

    @Test("isolated root is trimmed and standardized")
    func isolatedRootIsTrimmedAndStandardized() {
        let environment = [
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "yes",
            SSDPrefixCacheFactory.testRootEnvironmentKey: "  /ssd-factory-missing/b/../c/./kv3 \n",
        ]
        #expect(
            SSDPrefixCacheFactory.cacheRootDirectory(environment: environment).path
                == "/ssd-factory-missing/c/kv3")
        #expect(
            SSDPrefixCacheFactory.cacheDirectory(modelId: "abc", environment: environment).path
                == "/ssd-factory-missing/c/kv3/ba7816bf8f01")
    }

    @Test("isolated root forces the in-memory key unless the persistent flag is exactly 1")
    func forceEphemeralKeyMatrix() {
        let base = [
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "on",
            SSDPrefixCacheFactory.testRootEnvironmentKey: "/private/tmp/ssd-factory-force",
        ]
        #expect(SSDPrefixCacheFactory.forceEphemeralKey(environment: base))
        for value in ["true", "yes", "0", " 1", ""] {
            var environment = base
            environment["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"] = value
            #expect(SSDPrefixCacheFactory.forceEphemeralKey(environment: environment), "\(value)")
        }
        var persistent = base
        persistent["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"] = "1"
        #expect(!SSDPrefixCacheFactory.forceEphemeralKey(environment: persistent))
        #expect(!SSDPrefixCacheFactory.forceEphemeralKey(environment: [:]))
        #expect(!SSDPrefixCacheFactory.forceEphemeralKey(
            environment: ["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1"]))
    }

    @Test("weight hash is trimmed and blank values are refused")
    func verifiedWeightHashNormalization() {
        #expect(SSDPrefixCacheFactory.verifiedWeightHash(nil) == nil)
        #expect(SSDPrefixCacheFactory.verifiedWeightHash("") == nil)
        #expect(SSDPrefixCacheFactory.verifiedWeightHash("\n\t \r\n") == nil)
        #expect(SSDPrefixCacheFactory.verifiedWeightHash("abc") == "abc")
        #expect(SSDPrefixCacheFactory.verifiedWeightHash("\tabc def\n") == "abc def")
    }

    @Test("isolated root key loading is in memory and gives a 256-bit key")
    func isolatedKeyLoadingIsEphemeral() async throws {
        let parent = try factoryParent("key")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("kv3", isDirectory: true)
        let material = try await SSDPrefixCacheFactory.loadKeyMaterial(
            environment: isolatedEnvironment(root: root))
        #expect(material.ephemeral)
        #expect(material.key.bitCount == 256)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

@Suite("SSD prefix cache factory: refusals")
struct SSDPrefixCacheFactoryRefusalTests {

    @Test("missing or blank weight hash disables the tier before any disk work")
    func missingWeightHashRefuses() async throws {
        let parent = try factoryParent("no-hash")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("kv3", isDirectory: true)
        let capability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: fullLayers, backendSelection: .paged)
        #expect(capability.isSupported)
        for hash in [nil, "", "  \n"] as [String?] {
            let recorder = ConstructionFailureRecorder()
            let cache = await SSDPrefixCacheFactory.make(
                modelId: "no-hash-model", promptContractID: "test-contract", weightHash: hash,
                layerKinds: fullLayers, prefixReuseCapability: capability, kvBudget: nil,
                environment: isolatedEnvironment(root: root),
                onConstructionFailure: { recorder.record($0) })
            #expect(cache == nil)
            #expect(recorder.snapshot == [.missingWeightHash])
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("unsupported prefix reuse plan disables the tier before any disk work")
    func unsupportedPlanRefuses() async throws {
        let parent = try factoryParent("unsupported")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("kv3", isDirectory: true)
        let empty = CBv2PrefixReuseCapability.derive(
            layerKinds: [], backend: .contiguousUnquantized)
        #expect(!empty.isSupported)
        #expect(empty.unsupportedReason == .emptyLayout)
        let unknown = CBv2PrefixReuseCapability.derive(
            layerKinds: fullLayers, backend: .unknown)
        #expect(!unknown.isSupported)
        for capability in [empty, unknown] {
            let recorder = ConstructionFailureRecorder()
            let cache = await SSDPrefixCacheFactory.make(
                modelId: "unsupported-model", promptContractID: "test-contract",
                weightHash: "test-weights", layerKinds: fullLayers,
                prefixReuseCapability: capability, kvBudget: nil,
                environment: isolatedEnvironment(root: root),
                onConstructionFailure: { recorder.record($0) })
            #expect(cache == nil)
            #expect(recorder.snapshot == [.unsupportedPlan])
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("a persistent namespace without persistent mode reports key unavailable")
    func namespaceValidationRefuses() async throws {
        let parent = try factoryParent("namespace")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("kv3", isDirectory: true)
        let namespace = try SSDPersistentTestKeyNamespace(
            identifier: UUID(), accessGroup: "TESTTEAM.io.darkbloom.test")
        let capability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: fullLayers, backendSelection: .paged)
        let recorder = ConstructionFailureRecorder()
        let cache = await SSDPrefixCacheFactory.make(
            modelId: "namespace-model", promptContractID: "test-contract",
            weightHash: "test-weights", layerKinds: fullLayers,
            prefixReuseCapability: capability, kvBudget: nil,
            environment: isolatedEnvironment(root: root),
            persistentTestNamespace: namespace,
            onConstructionFailure: { recorder.record($0) })
        #expect(cache == nil)
        #expect(recorder.snapshot == [.keyUnavailable])
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("a regular file at the cache root reports an unsafe path")
    func fileAtRootRefuses() async throws {
        let parent = try factoryParent("unsafe")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("kv3", isDirectory: false)
        try Data("not a folder".utf8).write(to: root)
        let capability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: fullLayers, backendSelection: .paged)
        let recorder = ConstructionFailureRecorder()
        let cache = await SSDPrefixCacheFactory.make(
            modelId: "unsafe-model", promptContractID: "test-contract",
            weightHash: "test-weights", layerKinds: fullLayers,
            prefixReuseCapability: capability, kvBudget: nil,
            environment: isolatedEnvironment(root: root),
            onConstructionFailure: { recorder.record($0) })
        #expect(cache == nil)
        #expect(recorder.snapshot == [.unsafePath])
        var isDirectory: ObjCBool = true
        #expect(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
        #expect(!isDirectory.boolValue)
        #expect(try Data(contentsOf: root) == Data("not a folder".utf8))
    }

    @Test("a folder in place of the epoch record reports epoch unavailable")
    func epochRecordFolderRefuses() async throws {
        let parent = try factoryParent("epoch")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("kv3", isDirectory: true)
        let environment = isolatedEnvironment(root: root)
        let modelId = "epoch-model"
        let dir = SSDPrefixCacheFactory.cacheDirectory(modelId: modelId, environment: environment)
        let record = dir.appendingPathComponent("cache-epoch.json", isDirectory: true)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
        let capability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: fullLayers, backendSelection: .paged)
        let recorder = ConstructionFailureRecorder()
        let cache = await SSDPrefixCacheFactory.make(
            modelId: modelId, promptContractID: "test-contract",
            weightHash: "test-weights", layerKinds: fullLayers,
            prefixReuseCapability: capability, kvBudget: nil,
            environment: environment,
            onConstructionFailure: { recorder.record($0) })
        #expect(cache == nil)
        #expect(recorder.snapshot == [.epochUnavailable])
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: record.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}

@Suite("SSD prefix cache factory: construction")
struct SSDPrefixCacheFactoryConstructionTests {

    @Test("the complete-checkpoint factory gives its store the disk budget's basis: fixed for an operator override, half of the free bytes otherwise",
          arguments: [true, false])
    func hybridStoreReceivesDiskBudgetBasis(override: Bool) async throws {
        let parent = try factoryParent("basis")
        let root = parent.appendingPathComponent("kv3", isDirectory: true)
        let environment = isolatedEnvironment(
            root: root, extra: override ? [PrefixCachePolicy.diskBudgetEnvironmentFlag: "2"] : [:])
        let wholeRoot = SSDPrefixCacheFactory.cacheRootDirectory(environment: environment)
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: wholeRoot)
            try? FileManager.default.removeItem(at: parent)
        }
        let store = try #require(await SSDHybridCheckpointStoreFactory.make(
            modelId: "basis-model",
            identity: .init(modelAggregateHash: "w", promptContractID: "c", buildID: "b", numericsFingerprint: "n"),
            kvBudget: nil, environment: environment))
        defer { store.close() }
        // The pass the store runs after every write is the production one,
        // which resolves the budget inside the pass.
        let passes = SSDPrefixCacheFactory.wholeRootPasses
        let before = passes.count(root: wholeRoot)
        #expect(before >= 1, "the factory's own pass, after its scan")
        // That pass is what makes the root's occupancy known; before it
        // every first-sight write would be declined.
        #expect(SSDDiskBudget.shared.isOccupancyKnown(wholeRootKey: SSDDiskBudget.rootKey(wholeRoot)))
        store.config.maintainWholeRoot()
        #expect(passes.count(root: wholeRoot) == before + 1)
        #expect(passes.lastVolumeProbe(root: wholeRoot) == wholeRoot.standardizedFileURL.path)
        // Without this wiring the store treats its budget as fixed, and a
        // first-sight file admitted at half of free lowers the budget under itself.
        let resolve = try #require(store.config.diskBudgetBasis)
        let basis = resolve()
        if override {
            #expect(basis == .fixed(2 << 30))
        } else if PrefixCachePolicy.volumeFreeBytes(at: wholeRoot) != nil {
            guard case .halfOfFree(let free) = basis else {
                Issue.record("expected half of the free bytes, got \(basis)")
                return
            }
            #expect(free > 0)
        } else {
            #expect(basis == .fixed(PrefixCachePolicy.fallbackSSDDiskBudgetBytes))
        }
    }

    @Test("the block-tier factory gives its writer the disk budget's basis and its owning cache, and starts the periodic pass with the basis")
    func blockCacheReceivesDiskBudgetBasis() async throws {
        let parent = try factoryParent("block-basis")
        let root = parent.appendingPathComponent("kv3", isDirectory: true)
        let environment = isolatedEnvironment(root: root)
        let wholeRoot = SSDPrefixCacheFactory.cacheRootDirectory(environment: environment)
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: wholeRoot)
            try? FileManager.default.removeItem(at: parent)
        }
        let capability = PrefixCachePolicy.prefixReuseCapability(layerKinds: fullLayers, backendSelection: .paged)
        let cache = try #require(await SSDPrefixCacheFactory.make(
            modelId: "block-basis-model", promptContractID: "test-contract", weightHash: "test-weights",
            layerKinds: fullLayers, prefixReuseCapability: capability, kvBudget: nil, environment: environment))
        defer { cache.close() }
        // Both closures read the process environment and the live volume,
        // as the budget itself does.
        let expected = PrefixCachePolicy.ssdDiskBudgetBasis(
            freeBytes: PrefixCachePolicy.volumeFreeBytes(at: wholeRoot))
        func sameKind(_ basis: SSDDiskBudgetBasis) -> Bool {
            switch (basis, expected) {
            case (.fixed(let a), .fixed(let b)): return a == b
            case (.halfOfFree, .halfOfFree): return true
            default: return false
            }
        }
        // Without it a block that no longer fits beside a first-sight
        // write in flight does not tell that write to give way.
        let writerBasis = try #require(cache.writer.config.diskBudgetBasis)
        #expect(sameKind(writerBasis()))
        #expect(cache.writer.ownerStore === cache, "a block indexed after the cache closed is counted as unowned")
        // The pass after every block-tier donation is the production one.
        let passes = SSDPrefixCacheFactory.wholeRootPasses
        let before = passes.count(root: wholeRoot)
        let pass = try #require(cache.writer.config.maintainWholeRoot)
        pass()
        #expect(passes.count(root: wholeRoot) == before + 1)
        #expect(passes.lastVolumeProbe(root: wholeRoot) == cache.config.root.standardizedFileURL.path)
        // A donation waiting in the writer's queue is reported by the cache
        // itself, which is what the disk budget reads.
        func job(_ byte: UInt8) -> (SSDDonationJob, URL) {
            let tag = Data(repeating: byte, count: 16)
            let write = SSDBlockWrite(
                tag16: tag, tag16Hex: SSDLookupKeys.hex(tag),
                metadata: SSDBlockMetadata(
                    lookupTag: String(repeating: "ab", count: 32), weightHash: "w", layoutEpoch: "layout",
                    blockSize: 8, layerCount: 1, chunks: [], chunkPlaintextSizes: [], createdAt: 10_000),
                chunks: [], plaintextBytes: 1)
            return (.init(blocks: [write], totalBytes: 1),
                    SSDBlockStore.fileURL(root: cache.config.root, tag16Hex: write.tag16Hex))
        }
        let (running, runningFile) = job(1)
        let (waiting, _) = job(2)
        let lease = try #require(SSDCheckpointFileCoordinator.shared.tryAcquire(to: runningFile))
        defer { lease.release() }
        #expect(cache.queuedWriteBytes == 0)
        #expect(cache.writer.submit(running))
        try await SSDCheckpointCoordinationTestSupport.waitUntil {
            SSDCheckpointFileCoordinator.shared.pendingCount(for: runningFile) == 1
        }
        #expect(cache.writer.submit(waiting))
        #expect(cache.queuedWriteBytes == 1 + (1 << 20))
        lease.release()
        await cache.writer.waitUntilDrained()
        #expect(cache.queuedWriteBytes == 0)
        // Without it the 60-second pass evicts against a limit that a
        // first-sight write's own bytes have lowered.
        let periodic = try #require(SSDWholeRootMaintainer.shared.periodicBudgetBasis(root: wholeRoot))
        #expect(sameKind(periodic()))
    }

    @Test("isolated root builds a cache with the environment knobs applied")
    func buildsCacheUnderIsolatedRoot() async throws {
        let parent = try factoryParent("build")
        let root = parent.appendingPathComponent("kv3", isDirectory: true)
        let environment = isolatedEnvironment(root: root, extra: [
            SSDPrefixCachePolicy.ttlEnvironmentFlag: "600",
            SSDPrefixCachePolicy.maxStageMBFlag: "8",
            SSDPrefixCachePolicy.maxStageMillisFlag: "250",
            SSDPrefixCachePolicy.minEffectiveTokensFlag: "2048",
        ])
        let wholeRoot = SSDPrefixCacheFactory.cacheRootDirectory(environment: environment)
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: wholeRoot)
            try? FileManager.default.removeItem(at: parent)
        }
        let modelId = "build-model"
        let dir = SSDPrefixCacheFactory.cacheDirectory(modelId: modelId, environment: environment)
        let capability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: fullLayers, backendSelection: .paged)
        #expect(capability.isSupported)
        let recorder = ConstructionFailureRecorder()

        let cache = try #require(await SSDPrefixCacheFactory.make(
            modelId: modelId, promptContractID: "test-contract",
            weightHash: "  test-weights \n", layerKinds: fullLayers,
            prefixReuseCapability: capability, kvBudget: nil,
            environment: environment,
            onConstructionFailure: { recorder.record($0) }))

        #expect(recorder.snapshot.isEmpty)
        #expect(cache.config.modelId == modelId)
        #expect(cache.config.promptContractID == "test-contract")
        #expect(cache.config.weightHash == "test-weights")
        #expect(cache.config.blockSize == PrefixCachePolicy.blockSize)
        #expect(cache.config.blockSize == 256)
        #expect(cache.config.root.path == dir.path)
        #expect(cache.config.dedicatedRoot.path == wholeRoot.path)
        #expect(cache.config.adoptionBoundTokens == capability.conservativeReplayBoundTokens)
        #expect(cache.config.nominalFullKVBytesPerToken == capability.fullKVBytesPerToken)
        #expect(
            cache.config.layoutEpoch
                == SSDBlockStore.layoutEpoch(blockSize: 256, layerKinds: fullLayers))
        #expect(cache.config.ttlSeconds == 600)
        #expect(cache.config.maxStageBytes == 8 * 1_048_576)
        #expect(cache.config.maxStageMillis == 250)
        #expect(cache.config.minEffectiveTokens == 2048)
        #expect(cache.config.windowSidecar == nil)
        #expect(cache.config.epochStore?.current != nil)
        #expect(!cache.isClosed)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("cache-epoch.json").path))

        await cache.closeAndWait()
        #expect(cache.isClosed)
    }

    @Test("default knobs apply when the environment sets none")
    func defaultKnobs() async throws {
        let parent = try factoryParent("defaults")
        let root = parent.appendingPathComponent("kv3", isDirectory: true)
        let environment = isolatedEnvironment(root: root)
        let wholeRoot = SSDPrefixCacheFactory.cacheRootDirectory(environment: environment)
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: wholeRoot)
            try? FileManager.default.removeItem(at: parent)
        }
        let capability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: fullLayers, backendSelection: .contiguous)
        #expect(capability.isSupported)
        let cache = try #require(await SSDPrefixCacheFactory.make(
            modelId: "defaults-model", promptContractID: "test-contract",
            weightHash: "test-weights", layerKinds: fullLayers,
            prefixReuseCapability: capability, kvBudget: nil,
            environment: environment))
        #expect(cache.config.ttlSeconds == SSDPrefixCachePolicy.defaultTTLSeconds)
        #expect(cache.config.maxStageBytes == SSDPrefixCachePolicy.defaultMaxStageBytes)
        #expect(cache.config.maxStageMillis == SSDPrefixCachePolicy.defaultMaxStageMillis)
        #expect(cache.config.minEffectiveTokens >= SSDPrefixCachePolicy.defaultMinEffectiveTokens)
        #expect(cache.config.windowSidecar == nil)
        await cache.closeAndWait()
    }

    @Test("window sidecar flag derives the sidecar geometry for a whole-block window")
    func windowSidecarGeometry() async throws {
        let parent = try factoryParent("sidecar")
        let root = parent.appendingPathComponent("kv3", isDirectory: true)
        let environment = isolatedEnvironment(root: root, extra: [
            SSDPrefixCachePolicy.windowSidecarFlag: "1"
        ])
        let wholeRoot = SSDPrefixCacheFactory.cacheRootDirectory(environment: environment)
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: wholeRoot)
            try? FileManager.default.removeItem(at: parent)
        }
        let capability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: windowedLayers, backendSelection: .contiguous)
        #expect(capability.isSupported)
        #expect(capability.conservativeReplayBoundTokens == 256)
        let cache = try #require(await SSDPrefixCacheFactory.make(
            modelId: "sidecar-model", promptContractID: "test-contract",
            weightHash: "test-weights", layerKinds: windowedLayers,
            prefixReuseCapability: capability, kvBudget: nil,
            environment: environment))
        #expect(cache.config.adoptionBoundTokens == 256)
        let sidecar = try #require(cache.config.windowSidecar)
        #expect(sidecar.windowTokens == 256)
        #expect(sidecar.blockSize == 256)
        #expect(sidecar.blocksPerWindow == 1)
        #expect(sidecar.layers.map(\.index) == [0])
        #expect(sidecar.layers.map(\.kvHeads) == [2])
        #expect(sidecar.layers.map(\.headDim) == [8])
        #expect(sidecar.layerCount == 2)
        #expect(
            cache.config.layoutEpoch
                == SSDBlockStore.layoutEpoch(blockSize: 256, layerKinds: windowedLayers))
        await cache.closeAndWait()
    }

    @Test("a new in-memory key on the same root starts a new cache epoch")
    func newKeyRotatesEpoch() async throws {
        let parent = try factoryParent("rotate")
        let root = parent.appendingPathComponent("kv3", isDirectory: true)
        let environment = isolatedEnvironment(root: root)
        let wholeRoot = SSDPrefixCacheFactory.cacheRootDirectory(environment: environment)
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: wholeRoot)
            try? FileManager.default.removeItem(at: parent)
        }
        let capability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: fullLayers, backendSelection: .paged)

        let first = try #require(await SSDPrefixCacheFactory.make(
            modelId: "rotate-model", promptContractID: "test-contract",
            weightHash: "test-weights", layerKinds: fullLayers,
            prefixReuseCapability: capability, kvBudget: nil,
            environment: environment))
        let firstEpoch = try #require(first.config.epochStore?.current)
        await first.closeAndWait()

        let second = try #require(await SSDPrefixCacheFactory.make(
            modelId: "rotate-model", promptContractID: "test-contract",
            weightHash: "test-weights", layerKinds: fullLayers,
            prefixReuseCapability: capability, kvBudget: nil,
            environment: environment))
        let secondEpoch = try #require(second.config.epochStore?.current)
        #expect(second.config.root.path == first.config.root.path)
        #expect(secondEpoch != firstEpoch)
        #expect(UUID(uuidString: secondEpoch) != nil)
        #expect(secondEpoch == secondEpoch.lowercased())
        await second.closeAndWait()
    }
}

@Suite("SSD prefix cache factory: whole-root maintenance")
struct SSDPrefixCacheFactoryMaintenanceTests {

    @Test("periodic maintenance on the isolated root removes only stale temp files")
    func startRemovesStaleTempFiles() async throws {
        let parent = try factoryParent("maintenance")
        let root = parent.appendingPathComponent("kv3", isDirectory: true)
        let environment = isolatedEnvironment(root: root)
        let wholeRoot = SSDPrefixCacheFactory.cacheRootDirectory(environment: environment)
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: wholeRoot)
            try? FileManager.default.removeItem(at: parent)
        }
        let destination = SSDBlockStore.fileURL(
            root: root.appendingPathComponent("abcdefabcdef", isDirectory: true),
            tag16Hex: "ab00112233445566778899aabbccddee")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stale = SSDBlockStore.temporaryFileURL(
            for: destination,
            uuid: try #require(UUID(uuidString: "21234567-89AB-CDEF-0123-456789ABCDEF")))
        let young = SSDBlockStore.temporaryFileURL(
            for: destination,
            uuid: try #require(UUID(uuidString: "31234567-89AB-CDEF-0123-456789ABCDEF")))
        try Data("stale".utf8).write(to: stale)
        try Data("young".utf8).write(to: young)
        let now = Date().timeIntervalSince1970
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970:
                now - TimeInterval(2 * SSDBlockStore.crashTempTTLSeconds))],
            ofItemAtPath: stale.path)

        SSDPrefixCacheFactory.startWholeRootMaintenance(
            environment: environment, intervalSeconds: 3600)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline,
            FileManager.default.fileExists(atPath: stale.path)
        {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: young.path))
    }
}
