// Copyright © 2026 Eigen Labs.
//
// Unit suite for the encrypted SSD KV-offload prefix cache (v0.7.5):
// HMAC name derivation (keyed + salt-scoped), DBK3 round-trip + AAD
// binding, TTL expiry sweep, box-wide LRU eviction, endurance write cap,
// corrupt-block → recompute fallback, tier mode-selection matrix,
// NO-memory-carve invariant, and staging reservation hygiene on
// success / backstop / cancel / refusal paths.
//
// Live-isolated: real files under throwaway temp dirs, real MLX arrays,
// real crypto — no mocks of the store or the cache (per the repo test
// policy). No model weights: layer shapes are tiny fixtures.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

// MARK: - Shared fixtures

private let fixtureBlockSize = 8
private let fixtureKVHeads = 2
private let fixtureHeadDim = 8

/// Layer kinds: layer 0 full-attention (cacheable), layer 1 sliding-window
/// (never cached; adoption bound handled via the explicit config value).
private let fixtureLayerKinds: [CBv2LayerKind] = [
    CBv2LayerKind(attention: .full, headDim: fixtureHeadDim, kvHeads: fixtureKVHeads, queryHeads: 4),
    CBv2LayerKind(
        attention: .slidingWindow(4), headDim: fixtureHeadDim, kvHeads: fixtureKVHeads,
        queryHeads: 4),
]

private func tempDir(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("ssd-prefix-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Deterministic donation snapshot covering `tokenCount` tokens: layer 0
/// carries [1, kvHeads, tokenCount, headDim] f16 arrays whose values are a
/// function of position, layer 1 is nil (windowed).
private func fixtureSnapshots(tokenCount: Int, seed: Float = 1.0)
    -> [(keys: MLXArray, values: MLXArray, offset: Int)?]
{
    // MLX kernels need the metallib colocated with the xctest bundle
    // (same helper every MLX-touching suite uses).
    _ = LiveInferenceFixtures.ensureMetallibColocated()
    let shape = [1, fixtureKVHeads, tokenCount, fixtureHeadDim]
    let count = shape.reduce(1, *)
    let base = MLXArray(0 ..< count).reshaped(shape).asType(.float16)
    let keys = (base * seed).asType(.float16)
    let values = (base * (seed + 0.5)).asType(.float16)
    eval(keys, values)
    return [(keys: keys, values: values, offset: tokenCount), nil]
}

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int64
    init(_ now: Int64) { self._now = now }
    var now: Int64 { lock.withLock { _now } }
    func advance(_ seconds: Int64) { lock.withLock { _now += seconds } }
}

private final class ReadyReceiptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PrefixCacheReadyResult] = []

    func append(_ value: PrefixCacheReadyResult) { lock.withLock { values.append(value) } }
    var snapshot: [PrefixCacheReadyResult] { lock.withLock { values } }

    func waitForCount(_ count: Int, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if snapshot.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return snapshot.count >= count
    }
}

private func makeCache(
    dir: URL,
    kek: SymmetricKey,
    clock: ClockBox,
    blockSize: Int = fixtureBlockSize,
    ttlSeconds: Int64 = 900,
    adoptionBound: Int = 0,
    minEffectiveTokens: Int = fixtureBlockSize,
    maxStageBytes: Int = 1 << 30,
    maxWriteBytesPerDay: Int = 0,
    diskBudgetBytes: Int = 1 << 40,
    kvBudget: GlobalKVCacheBudget? = nil,
    diskBudget: SSDDiskBudget = SSDDiskBudget(),
    epochStore: SSDCacheEpochStore? = nil,
    maintainWholeRoot: (@Sendable () -> Void)? = nil,
    donationRecorder: any PrefixCacheDonationRecording = PrefixCacheDonationTelemetry.shared
) -> SSDPrefixCache {
    let config = SSDPrefixCache.Config(
        modelId: "test-model",
        promptContractID: "test-prompt-contract",
        weightHash: "test-weight-hash",
        blockSize: blockSize,
        adoptionBoundTokens: adoptionBound,
        layoutEpoch: SSDBlockStore.layoutEpoch(
            blockSize: blockSize, layerKinds: fixtureLayerKinds),
        epochStore: epochStore,
        root: dir,
        ttlSeconds: ttlSeconds,
        minEffectiveTokens: minEffectiveTokens,
        maxStageBytes: maxStageBytes,
        maxStageMillis: 1_000_000,
        nowSeconds: { clock.now })
    return SSDPrefixCache(
        config: config, kekKey: kek, kvBudget: kvBudget, diskBudget: diskBudget,
        maxWriteBytesPerDay: maxWriteBytesPerDay, strictFsync: false,
        diskBudgetBytes: { diskBudgetBytes },
        maintainWholeRoot: maintainWholeRoot,
        donationRecorder: donationRecorder)
}

/// Poll until the cache's index holds `count` entries (write-behind is
/// asynchronous by design).
private func waitForIndexCount(
    _ cache: SSDPrefixCache, atLeast count: Int, timeout: Duration = .seconds(20)
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if cache.index.count >= count { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return cache.index.count >= count
}

private func dbk3Files(under root: URL) -> [URL] {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return [] }
    return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "dbk3" }
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: semaphore.wait(timeout: timeout))
        }
    }
}

// MARK: - HMAC name derivation

@Suite("SSD prefix cache: HMAC lookup keys")
struct SSDLookupKeysTests {

    @Test("same input, different install key ⇒ different tag (T-041 leak #2 closed)")
    func keyedTags() {
        let hash = Data(SHA256.hash(data: Data("prefix".utf8)))
        let a = SSDLookupKeys(kek: SymmetricKey(size: .bits256))
        let b = SSDLookupKeys(kek: SymmetricKey(size: .bits256))
        #expect(a.tag(chainHash: hash, cacheSalt: "") != b.tag(chainHash: hash, cacheSalt: ""))
        // Deterministic under one key.
        #expect(a.tag(chainHash: hash, cacheSalt: "") == a.tag(chainHash: hash, cacheSalt: ""))
        #expect(a.tag(chainHash: hash, cacheSalt: "").count == 32)
        #expect(a.tag16(chainHash: hash, cacheSalt: "").count == 16)
    }

    @Test("salt scoping: different scopes can never share a tag; empty salt is length-prefixed")
    func saltScopedTags() {
        let keys = SSDLookupKeys(kek: SymmetricKey(size: .bits256))
        let hash = Data(SHA256.hash(data: Data("prefix".utf8)))
        let unscoped = keys.tag(chainHash: hash, cacheSalt: "")
        let scopeA = keys.tag(chainHash: hash, cacheSalt: "scope-a")
        let scopeB = keys.tag(chainHash: hash, cacheSalt: "scope-b")
        #expect(unscoped != scopeA)
        #expect(scopeA != scopeB)
        #expect(unscoped != scopeB)
        // Length-prefix unambiguity: salt "ab" ‖ hash H must not collide
        // with salt "a" ‖ ("b" prepended to H).
        let shifted = keys.tag(chainHash: Data("b".utf8) + hash, cacheSalt: "a")
        let joined = keys.tag(chainHash: hash, cacheSalt: "ab")
        #expect(shifted != joined)
    }
}

// MARK: - DBK3 codec

@Suite("SSD prefix cache: DBK3 block store")
struct SSDBlockStoreTests {

    private func fixtureMetadata(sizes: [Int]) -> SSDBlockMetadata {
        SSDBlockMetadata(
            lookupTag: String(repeating: "ab", count: 32),
            weightHash: "w-hash",
            layoutEpoch: "cbv2-frozen-full-3|native-fp|8|deadbeef",
            blockSize: 8,
            layerCount: 2,
            chunks: sizes.enumerated().map { i, _ in
                SSDBlockChunkDescriptor(
                    layerIndex: 0, tensor: i % 2, shape: [1, 2, 8, 8], dtype: "float16")
            },
            chunkPlaintextSizes: sizes,
            createdAt: 1000)
    }

    @Test("round-trip: metadata + chunks survive encrypt/decrypt byte-exactly")
    func roundTrip() throws {
        let dir = tempDir("store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let chunks = [Data((0 ..< 256).map { UInt8($0 % 251) }), Data(repeating: 7, count: 256)]
        let metadata = fixtureMetadata(sizes: chunks.map(\.count))
        let url = SSDBlockStore.fileURL(root: dir, tag16Hex: "aabbccdd00112233445566778899eeff")
        try SSDBlockStore.write(to: url, metadata: metadata, chunks: chunks, kekKey: kek)

        let (readMeta, readChunks) = try SSDBlockStore.read(from: url, kekKey: kek)
        #expect(readMeta == metadata)
        #expect(readChunks == chunks)
        // Header-only read (index scan path).
        #expect(try SSDBlockStore.readMetadataOnly(from: url) == metadata)
        // Wrong KEK fails closed.
        #expect(throws: (any Error).self) {
            _ = try SSDBlockStore.read(from: url, kekKey: SymmetricKey(size: .bits256))
        }
    }

    @Test("legacy DBK2 bytes and pre-frozen epochs are rejected by the DBK3 tier")
    func legacyArtifactsFailClosed() throws {
        let dir = tempDir("legacy-store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let tagHex = "aabbccdd00112233445566778899eeff"
        let url = SSDBlockStore.fileURL(root: dir, tag16Hex: tagHex)
        let chunks = [Data(repeating: 7, count: 32)]
        let metadata = SSDBlockMetadata(
            lookupTag: tagHex + String(repeating: "0", count: 32),
            weightHash: "test-weight-hash",
            layoutEpoch: "cbv2-snap-2|f16|\(fixtureBlockSize)|legacy",
            blockSize: fixtureBlockSize,
            layerCount: fixtureLayerKinds.count,
            chunks: [
                SSDBlockChunkDescriptor(
                    layerIndex: 0, tensor: 0,
                    shape: [1, fixtureKVHeads, fixtureBlockSize, fixtureHeadDim],
                    dtype: "float16")
            ],
            chunkPlaintextSizes: chunks.map(\.count),
            createdAt: 1_000)
        try SSDBlockStore.write(to: url, metadata: metadata, chunks: chunks, kekKey: kek)
        #expect(try SSDBlockStore.readMetadataOnly(from: url).layoutEpoch.hasPrefix("cbv2-snap-2|"))

        let cache = makeCache(
            dir: dir, kek: kek, clock: ClockBox(1_001), ttlSeconds: 0)
        defer { cache.close() }
        cache.scanOnDisk()
        #expect(cache.index.count == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        try SSDBlockStore.write(to: url, metadata: metadata, chunks: chunks, kekKey: kek)
        var dbk2 = try Data(contentsOf: url)
        dbk2[4] = 2
        dbk2[5] = 0
        try dbk2.write(to: url)
        do {
            _ = try SSDBlockStore.readMetadataOnly(from: url)
            Issue.record("DBK2 metadata unexpectedly loaded")
        } catch SSDBlockStoreError.unsupportedVersion(let version) {
            #expect(version == 2)
        } catch {
            Issue.record("DBK2 metadata failed with the wrong error: \(error)")
        }
        do {
            _ = try SSDBlockStore.read(from: url, kekKey: kek)
            Issue.record("DBK2 block unexpectedly loaded")
        } catch SSDBlockStoreError.unsupportedVersion(let version) {
            #expect(version == 2)
        } catch {
            Issue.record("DBK2 block failed with the wrong error: \(error)")
        }
        cache.scanOnDisk()
        #expect(cache.index.count == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("header length fields decode correctly across sizes (unaligned-safe byte decode)")
    func headerLengthFieldsDecode() throws {
        // Regression (Codex, v0.7.5 SSD review — SSDBlockStore DBK3 header
        // parsing): the wrapped-DEK / metadata / chunk-length fields are
        // parsed from sliced `Data` with no alignment guarantee. The decode
        // must be alignment-agnostic AND correct for values that exercise
        // every byte of the little-endian u16/u32 fields (including the high
        // bytes, i.e. lengths > 0xFFFF). A per-byte decoder that dropped a
        // byte, or an unaligned `load(as:)` that trapped, would fail here.
        let dir = tempDir("store-lenfields")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        // Chunk sizes chosen to make chunkPlaintextSize / ciphertext-length
        // fields span 1-, 2-, and 3-byte magnitudes (255, 65_537, 200_003).
        let sizeMatrix: [[Int]] = [
            [1, 255],
            [65_537, 4],
            [200_003, 200_004],
        ]
        for (n, sizes) in sizeMatrix.enumerated() {
            let chunks = sizes.map { Data((0 ..< $0).map { UInt8($0 % 251) }) }
            let metadata = fixtureMetadata(sizes: sizes)
            let hex = String(format: "%032x", n) // valid 32-hex tag16
            let url = SSDBlockStore.fileURL(root: dir, tag16Hex: hex)
            try SSDBlockStore.write(to: url, metadata: metadata, chunks: chunks, kekKey: kek)

            let (readMeta, readChunks) = try SSDBlockStore.read(from: url, kekKey: kek)
            #expect(readMeta == metadata, "metadata length field mis-decoded for sizes \(sizes)")
            #expect(readChunks == chunks, "chunk length field mis-decoded for sizes \(sizes)")
            #expect(try SSDBlockStore.readMetadataOnly(from: url) == metadata)
        }
    }

    @Test("AAD binding: tampering body or metadata bytes breaks authentication")
    func tamperFailsClosed() throws {
        let dir = tempDir("tamper")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let chunks = [Data(repeating: 3, count: 512)]
        let metadata = fixtureMetadata(sizes: [512])
        let url = SSDBlockStore.fileURL(root: dir, tag16Hex: "00112233445566778899aabbccddeeff")
        try SSDBlockStore.write(to: url, metadata: metadata, chunks: chunks, kekKey: kek)
        let original = try Data(contentsOf: url)

        // Flip one ciphertext byte (near the end = chunk body).
        var body = original
        body[body.count - 20] ^= 0xFF
        try body.write(to: url)
        #expect(throws: (any Error).self) { _ = try SSDBlockStore.read(from: url, kekKey: kek) }

        // Flip one metadata byte (plaintext JSON region — it is the AAD, so
        // the DEK unwrap and every chunk must fail even though the JSON
        // still parses). Locate a metadata byte: header prefix is 24 bytes
        // + wrapped DEK; the metadata JSON contains the schema string.
        var meta = original
        if let range = meta.range(of: Data("darkbloom.kv.v3".utf8)) {
            meta[range.lowerBound] ^= 0x01
            try meta.write(to: url)
            #expect(throws: (any Error).self) { _ = try SSDBlockStore.read(from: url, kekKey: kek) }
        } else {
            Issue.record("metadata marker not found in encoded file")
        }
    }

    @Test("layout epoch: layer-kind changes produce a different epoch (fail-closed binding)")
    func layoutEpochBinding() {
        let a = SSDBlockStore.layoutEpoch(blockSize: 8, layerKinds: fixtureLayerKinds)
        var mutated = fixtureLayerKinds
        mutated[1] = CBv2LayerKind(
            attention: .slidingWindow(8), headDim: fixtureHeadDim, kvHeads: fixtureKVHeads,
            queryHeads: 4)
        let b = SSDBlockStore.layoutEpoch(blockSize: 8, layerKinds: mutated)
        let c = SSDBlockStore.layoutEpoch(blockSize: 16, layerKinds: fixtureLayerKinds)
        #expect(a != b)
        #expect(a != c)
        #expect(a.hasPrefix("cbv2-frozen-full-3|native-fp|8|"))
    }

    @Test("atomic writer uses the exact Darkbloom-owned crash-temp grammar")
    func exactTempName() throws {
        let uuid = try #require(UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef"))
        let destination = URL(fileURLWithPath: "/tmp/ab/ab00112233445566778899aabbccddee.dbk3")
        let temp = SSDBlockStore.temporaryFileURL(for: destination, uuid: uuid)
        #expect(
            temp.lastPathComponent
                == "ab00112233445566778899aabbccddee.dbk3.darkbloom-tmp.01234567-89AB-CDEF-0123-456789ABCDEF")
        #expect(SSDBlockStore.isOwnedTempFileName(temp.lastPathComponent, fanout: "ab"))
        #expect(!SSDBlockStore.isOwnedTempFileName(
            "ab00112233445566778899aabbccddee.dbk3.darkbloom-tmp.11234567-89ab-cdef-0123-456789abcdef",
            fanout: "ab"))
        #expect(!SSDBlockStore.isOwnedTempFileName(
            "ab00112233445566778899aabbccddee.dbk3.darkbloom-tmp.21234567-89AB-cDEF-0123-456789ABCDef",
            fanout: "ab"))
    }

    @Test("startup temp sweep preserves young writes and removes stale crash orphans")
    func startupTempSweepUsesAge() throws {
        let root = tempDir("store-temp-age").appendingPathComponent(
            "abcdefabcdef", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let destination = SSDBlockStore.fileURL(
            root: root, tag16Hex: "ab00112233445566778899aabbccddee")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stale = SSDBlockStore.temporaryFileURL(
            for: destination,
            uuid: try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")))
        let young = SSDBlockStore.temporaryFileURL(
            for: destination,
            uuid: try #require(UUID(uuidString: "11234567-89AB-CDEF-0123-456789ABCDEF")))
        try Data("stale".utf8).write(to: stale)
        try Data("young".utf8).write(to: young)
        let now: Int64 = 10_000
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(
                now - SSDBlockStore.crashTempTTLSeconds))],
            ofItemAtPath: stale.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(
                now - SSDBlockStore.crashTempTTLSeconds + 1))],
            ofItemAtPath: young.path)

        #expect(SSDBlockStore.sweepStaleTempFiles(under: root, nowSeconds: now) == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: young.path))
    }

    @Test("active cache I/O rejects symlinked root, model, and fanout paths")
    func activeSymlinkIOFailsClosed() throws {
        let parent = tempDir("active-symlinks")
        defer { try? FileManager.default.removeItem(at: parent) }
        let fm = FileManager.default

        let realDedicated = parent.appendingPathComponent("real", isDirectory: true)
        let linkedDedicated = parent.appendingPathComponent("linked", isDirectory: true)
        try fm.createDirectory(at: realDedicated, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedDedicated, withDestinationURL: realDedicated)
        #expect(throws: (any Error).self) {
            try SSDBlockStore.prepareModelRoot(
                dedicatedRoot: linkedDedicated,
                modelRoot: linkedDedicated.appendingPathComponent("aaaaaaaaaaaa"))
        }

        let outsideModel = parent.appendingPathComponent("outside-model", isDirectory: true)
        try fm.createDirectory(at: outsideModel, withIntermediateDirectories: true)
        let modelLink = realDedicated.appendingPathComponent("aaaaaaaaaaaa", isDirectory: true)
        try fm.createSymbolicLink(at: modelLink, withDestinationURL: outsideModel)
        #expect(throws: (any Error).self) {
            try SSDBlockStore.prepareModelRoot(
                dedicatedRoot: realDedicated,
                modelRoot: modelLink)
        }
        try fm.removeItem(at: modelLink)

        let modelRoot = realDedicated.appendingPathComponent("bbbbbbbbbbbb", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(
            dedicatedRoot: realDedicated,
            modelRoot: modelRoot)
        let outsideFanout = parent.appendingPathComponent("outside-fanout", isDirectory: true)
        try fm.createDirectory(at: outsideFanout, withIntermediateDirectories: true)
        let fanoutLink = modelRoot.appendingPathComponent("aa", isDirectory: true)
        try fm.createSymbolicLink(at: fanoutLink, withDestinationURL: outsideFanout)
        let url = SSDBlockStore.fileURL(
            root: modelRoot,
            tag16Hex: "aabbccdd00112233445566778899eeff")
        #expect(throws: (any Error).self) {
            try SSDBlockStore.write(
                to: url,
                metadata: fixtureMetadata(sizes: [32]),
                chunks: [Data(repeating: 1, count: 32)],
                kekKey: SymmetricKey(size: .bits256))
        }
        #expect((try fm.contentsOfDirectory(atPath: outsideFanout.path)).isEmpty)

        let cache = makeCache(
            dir: modelRoot,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000))
        defer { cache.close() }
        cache.scanOnDisk()
        #expect(cache.index.count == 0)
        let scanStatus = cache.prefixCacheModelStatus(base: PrefixCacheModelStatus(
            modelId: "test-model",
            backend: .contiguous,
            replayStrategy: .direct,
            state: .pending,
            reason: .scanPending))
        #expect(scanStatus.state == .error)
        #expect(scanStatus.reason == .scanFailed)
        let escapedFile = outsideFanout.appendingPathComponent(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.dbk3")
        try Data("must-survive".utf8).write(to: escapedFile)
        cache.index.insert(
            tag16: Data(repeating: 0xaa, count: 16),
            fileBytes: 32,
            lastAccess: 0)
        cache.sweepExpiredEntries()
        #expect(cache.index.count == 0, "unsafe fanout must be dropped from the RAM index")
        #expect(cache.stats().ttlExpired == 0, "an invalid path is not a successful TTL deletion")
        #expect(fm.fileExists(atPath: escapedFile.path))
    }

    @Test("descriptor-relative root creation rejects a concurrent symlink replacement")
    func modelRootCreationRejectsRootSwap() throws {
        let parent = tempDir("root-create-swap")
        defer { try? FileManager.default.removeItem(at: parent) }
        let fm = FileManager.default
        let dedicated = parent.appendingPathComponent("cache", isDirectory: true)
        let detached = parent.appendingPathComponent("detached-cache", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        let model = dedicated.appendingPathComponent("aaaaaaaaaaaa", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try SSDBlockStore.prepareModelRoot(
                dedicatedRoot: dedicated,
                modelRoot: model,
                beforeModelCreation: {
                    try! FileManager.default.moveItem(at: dedicated, to: detached)
                    try! FileManager.default.createSymbolicLink(
                        at: dedicated,
                        withDestinationURL: outside)
                })
        }
        #expect(!fm.fileExists(
            atPath: outside.appendingPathComponent("aaaaaaaaaaaa").path))
        #expect(fm.fileExists(
            atPath: detached.appendingPathComponent("aaaaaaaaaaaa").path))
    }

    @Test("descriptor-relative active I/O cannot be redirected by a fanout symlink race")
    func activeIORenameToSymlinkRace() throws {
        struct Fixture {
            let parent: URL
            let modelRoot: URL
            let file: URL
            let outsideFile: URL
            let hook: @Sendable (SSDActiveIOOperation) -> Void
        }
        var parents: [URL] = []
        defer { for parent in parents { try? FileManager.default.removeItem(at: parent) } }
        let kek = SymmetricKey(size: .bits256)
        let tag = "aabbccdd00112233445566778899eeff"
        let originalChunk = Data(repeating: 3, count: 32)
        let outsideSentinel = Data("outside-must-remain-untouched".utf8)

        func makeFixture(_ label: String) throws -> Fixture {
            let parent = tempDir("nofollow-\(label)")
            parents.append(parent)
            let dedicated = parent.appendingPathComponent("cache", isDirectory: true)
            let modelRoot = dedicated.appendingPathComponent("aaaaaaaaaaaa", isDirectory: true)
            try SSDBlockStore.prepareModelRoot(
                dedicatedRoot: dedicated, modelRoot: modelRoot)
            let file = SSDBlockStore.fileURL(root: modelRoot, tag16Hex: tag)
            _ = try SSDBlockStore.write(
                to: file,
                metadata: fixtureMetadata(sizes: [originalChunk.count]),
                chunks: [originalChunk],
                kekKey: kek)

            let fanout = file.deletingLastPathComponent()
            let detachedFanout = modelRoot.appendingPathComponent("detached-aa")
            let outsideFanout = parent.appendingPathComponent("outside-aa", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outsideFanout, withIntermediateDirectories: true)
            let outsideFile = outsideFanout.appendingPathComponent(file.lastPathComponent)
            try outsideSentinel.write(to: outsideFile)
            let hook: @Sendable (SSDActiveIOOperation) -> Void = { _ in
                try! FileManager.default.moveItem(at: fanout, to: detachedFanout)
                try! FileManager.default.createSymbolicLink(
                    at: fanout, withDestinationURL: outsideFanout)
            }
            return Fixture(
                parent: parent,
                modelRoot: modelRoot,
                file: file,
                outsideFile: outsideFile,
                hook: hook)
        }

        let readFixture = try makeFixture("read")
        let (readMetadata, readChunks) = try SSDBlockStore.read(
            from: readFixture.file,
            kekKey: kek,
            beforeOperation: readFixture.hook)
        #expect(readMetadata.weightHash == "w-hash")
        #expect(readChunks == [originalChunk])
        #expect(try Data(contentsOf: readFixture.outsideFile) == outsideSentinel)

        let writeFixture = try makeFixture("write")
        _ = try SSDBlockStore.write(
            to: writeFixture.file,
            metadata: fixtureMetadata(sizes: [48]),
            chunks: [Data(repeating: 9, count: 48)],
            kekKey: kek,
            beforeOperation: writeFixture.hook)
        #expect(try Data(contentsOf: writeFixture.outsideFile) == outsideSentinel)

        let touchFixture = try makeFixture("touch")
        let outsideDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes(
            [.modificationDate: outsideDate],
            ofItemAtPath: touchFixture.outsideFile.path)
        SSDBlockStore.setAttributesIfSafe(
            [.modificationDate: Date(timeIntervalSince1970: 9_000)],
            at: touchFixture.file,
            under: touchFixture.modelRoot,
            beforeOperation: touchFixture.hook)
        let untouchedDate = try touchFixture.outsideFile.resourceValues(
            forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(untouchedDate == outsideDate)

        let deleteFixture = try makeFixture("delete")
        #expect(SSDBlockStore.removeItemIfSafe(
            at: deleteFixture.file,
            under: deleteFixture.modelRoot,
            beforeOperation: deleteFixture.hook))
        #expect(try Data(contentsOf: deleteFixture.outsideFile) == outsideSentinel)
    }
}

// MARK: - Production gate

@Suite("SSD prefix cache: production gate")
struct SSDPrefixCacheModeTests {

    @Test("SSD defaults on and the single local kill switch disables it")
    func gateMatrix() {
        #expect(PrefixCachePolicy.isEnabled(environment: [:]))
        #expect(PrefixCachePolicy.isEnabled(
            environment: ["DARKBLOOM_PREFIX_CACHE": "1"]))
        #expect(!PrefixCachePolicy.isEnabled(
            environment: ["DARKBLOOM_PREFIX_CACHE": "0"]))
        #expect(!PrefixCachePolicy.isEnabled(
            environment: ["DARKBLOOM_PREFIX_CACHE": "banana"]))
    }

    @Test("reusable SSD cache requires a verified non-empty live weight hash")
    func verifiedWeightBindingRequired() {
        #expect(SSDPrefixCacheFactory.verifiedWeightHash(nil) == nil)
        #expect(SSDPrefixCacheFactory.verifiedWeightHash("") == nil)
        #expect(SSDPrefixCacheFactory.verifiedWeightHash(" \n\t ") == nil)
        #expect(SSDPrefixCacheFactory.verifiedWeightHash("  abcd1234  ") == "abcd1234")
    }

    @Test("test root is isolated and requires the ephemeral-key gate")
    func isolatedTestRoot() {
        let root = tempDir("factory-test-root").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = [
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
            SSDPrefixCacheFactory.testRootEnvironmentKey: root.path,
        ]
        #expect(SSDPrefixCacheFactory.cacheRootDirectory(environment: raw) == root)
        #expect(
            SSDPrefixCacheFactory.cacheDirectory(
                modelId: "isolated-model",
                environment: raw
            ).deletingLastPathComponent() == root)
        #expect(
            SSDPrefixCacheFactory.cacheRootDirectory(environment: [
                SSDPrefixCacheFactory.testRootEnvironmentKey: root.path
            ]) != root)
    }

    @Test("durable-byte stage estimate is positive, conservative, and wire-bounded")
    func durableStageEstimate() {
        #expect(SSDPrefixCachePolicy.estimatedStageMillis(bytes: 1) == 1)
        #expect(SSDPrefixCachePolicy.estimatedStageMillisDouble(bytes: 1) > 0)
        #expect(SSDPrefixCachePolicy.estimatedStageMillisDouble(bytes: Int.max)
            == PrefixCacheReadyResult.maxStageMs)
    }

    @Test("box-wide disk budget: env override wins; default = min(20 GiB, free/2)")
    func diskBudgetResolver() {
        let gib = 1_073_741_824
        #expect(
            PrefixCachePolicy.ssdDiskBudgetBytes(
                environment: ["DARKBLOOM_PREFIX_CACHE_DISK_GB": "5"], freeBytes: 100 * gib)
                == 5 * gib)
        // Default: 20 GiB when free space is plentiful…
        #expect(
            PrefixCachePolicy.ssdDiskBudgetBytes(environment: [:], freeBytes: 100 * gib)
                == 20 * gib)
        // …clamped to free/2 on a tight volume…
        #expect(
            PrefixCachePolicy.ssdDiskBudgetBytes(environment: [:], freeBytes: 10 * gib)
                == 5 * gib)
        // …and the fixed default when free space is unknown.
        #expect(PrefixCachePolicy.ssdDiskBudgetBytes(environment: [:], freeBytes: nil) == 20 * gib)
        // Malformed env degrades to the default (never crashes, never 0).
        #expect(
            PrefixCachePolicy.ssdDiskBudgetBytes(
                environment: ["DARKBLOOM_PREFIX_CACHE_DISK_GB": "inf"], freeBytes: 100 * gib)
                == 20 * gib)
    }

    @Test("SSD knobs: TTL is capped at 15 minutes; write cap parses; stage gates parse")
    func ssdKnobs() {
        #expect(SSDPrefixCachePolicy.ttlSeconds(environment: [:]) == 900)
        #expect(
            SSDPrefixCachePolicy.ttlSeconds(
                environment: ["DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS": "300"]) == 300)
        // The env can only SHORTEN the TTL (15-minute maximum) — raising or
        // disabling attempts fall back to the default.
        #expect(
            SSDPrefixCachePolicy.ttlSeconds(
                environment: ["DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS": "86400"]) == 900)
        #expect(
            SSDPrefixCachePolicy.ttlSeconds(
                environment: ["DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS": "0"]) == 900)
        #expect(
            SSDPrefixCachePolicy.maxWriteBytesPerDay(environment: [:])
                == 150 * 1_000_000_000)
        #expect(
            SSDPrefixCachePolicy.maxWriteBytesPerDay(
                environment: ["DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY": "0"]) == 0)
        #expect(SSDPrefixCachePolicy.minEffectiveTokens(environment: [:]) == 1024)
        #expect(SSDPrefixCachePolicy.maxStageBytes(environment: [:]) == 1024 * 1_048_576)
        #expect(SSDPrefixCachePolicy.maxStageMillis(environment: [:]) == 1000)
        #expect(SSDPrefixCachePolicy.lowDiskFloorBytes(volumeCapacityBytes: 0)
            == 20 * 1_073_741_824)
    }
}

// MARK: - Donate / stage / adopt lifecycle

@Suite("SSD prefix cache: donation, staging, adoption", .serialized)
struct SSDPrefixCacheLifecycleTests {

    private let tokenCount = 64  // 8 whole blocks at blockSize 8

    private func donateFixture(
        _ cache: SSDPrefixCache, tokens: [Int], salt: String? = nil, seed: Float = 1.0
    ) {
        cache.donate(
            tokens: tokens,
            snapshots: fixtureSnapshots(tokenCount: tokens.count, seed: seed),
            layerKinds: fixtureLayerKinds,
            cacheSalt: salt)
    }

    @Test("donate writes encrypted per-block files, dedupes re-donation, frees RAM")
    func donateWritesAndDedupes() async throws {
        let dir = tempDir("donate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let cache = makeCache(dir: dir, kek: kek, clock: clock)
        defer { cache.close() }

        let tokens = Array(0 ..< tokenCount)
        donateFixture(cache, tokens: tokens)
        #expect(await waitForIndexCount(cache, atLeast: 8), "write-behind never landed")
        #expect(cache.index.count == 8)
        let files = dbk3Files(under: dir)
        #expect(files.count == 8)
        // RAM discipline: nothing resident after donation.
        #expect(cache.bytesInUse == 0)

        // No raw chain hashes anywhere on disk (filenames are HMAC tags).
        let hasher = CBv2BlockHasher(
            blockSize: fixtureBlockSize, promptContractID: "test-prompt-contract")
        let chainHexes = hasher.chainHashes(tokens: tokens).map { SSDLookupKeys.hex($0) }
        for file in files {
            for hex in chainHexes {
                #expect(!file.lastPathComponent.contains(hex.prefix(16)))
            }
        }

        // Re-donating the identical prefix writes nothing new.
        let written = cache.stats().blocksWritten
        donateFixture(cache, tokens: tokens)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(cache.stats().blocksWritten == written)
        #expect(dbk3Files(under: dir).count == 8)

        // A one-block extension writes ONLY the tail block.
        donateFixture(cache, tokens: Array(0 ..< (tokenCount + fixtureBlockSize)))
        #expect(await waitForIndexCount(cache, atLeast: 9))
        #expect(dbk3Files(under: dir).count == 9)
    }

    @Test("restart warmth: a FRESH cache over the same dir scans, stages, and adopts byte-exactly")
    func restartWarmthRoundTrip() async throws {
        let dir = tempDir("warmth")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let tokens = Array(0 ..< tokenCount)

        let writer = makeCache(dir: dir, kek: kek, clock: clock)
        donateFixture(writer, tokens: tokens)
        #expect(await waitForIndexCount(writer, atLeast: 8))
        writer.close()

        // "Restart": new instance, same dir + install key; index rebuilt by scan.
        let reader = makeCache(dir: dir, kek: kek, clock: clock)
        defer { reader.close() }
        reader.scanOnDisk()
        #expect(reader.index.count == 8)

        // Stage for a prompt extending the donated prefix.
        let prompt = tokens + Array(1000 ..< 1004)
        let staged = await reader.stage(requestID: "req-1", promptTokens: prompt, cacheScope: "")
        #expect(staged.staged)
        #expect(reader.bytesInUse > 0)

        // Engine-side synchronous lookup hits the staging map.
        let hit = reader.lookup(tokens: prompt, layerKinds: fixtureLayerKinds, cacheSalt: nil)
        let (matched, prefix) = try #require(hit)
        #expect(reader.stats().tokensSaved == 0, "lookup M is not terminal saved-prefill truth")
        reader.recordPrefillTokensSaved(7)
        #expect(reader.stats().tokensSaved == 7)
        #expect(matched == tokenCount)  // 8 whole blocks
        #expect(prefix.count == 2)
        #expect(prefix[1] == nil)  // windowed layer never cached
        let adopted = try #require(prefix[0])
        #expect(adopted.offset == matched)
        #expect(adopted.keys.shape == [1, fixtureKVHeads, matched, fixtureHeadDim])

        // Byte-exact vs the donor arrays (the exactness invariant).
        let donor = fixtureSnapshots(tokenCount: tokens.count)[0]!
        let keyDelta = abs(
            adopted.keys.asType(.float32)
                - donor.keys[.ellipsis, 0 ..< matched, 0...].asType(.float32)
        ).max().item(Float.self)
        let valueDelta = abs(
            adopted.values.asType(.float32)
                - donor.values[.ellipsis, 0 ..< matched, 0...].asType(.float32)
        ).max().item(Float.self)
        #expect(keyDelta == 0)
        #expect(valueDelta == 0)

        // endAdoption (the engine's balanced release) drains the staging map.
        reader.endAdoption(tokens: prompt, matched: matched, cacheSalt: nil)
        #expect(reader.bytesInUse == 0)
        // Backstop after the fact is a no-op.
        reader.completeStaging(requestID: "req-1")
        #expect(reader.stats().hits == 1)
    }

    @Test("real SSD hit and miss p95 stay inside the configured stage deadline")
    func stageLatencyGate() async throws {
        let dir = tempDir("latency")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let cache = makeCache(dir: dir, kek: kek, clock: clock)
        defer { cache.close() }
        let tokens = Array(0 ..< tokenCount)
        let hitPrompt = tokens + [999]
        donateFixture(cache, tokens: tokens)
        #expect(await waitForIndexCount(cache, atLeast: 8))

        var missSamples: [Duration] = []
        for index in 0 ..< 50 {
            let started = ContinuousClock.now
            let result = await cache.stage(
                requestID: "miss-\(index)",
                promptTokens: Array(10_000 ..< (10_000 + tokenCount)) + [index],
                cacheScope: "")
            missSamples.append(started.duration(to: ContinuousClock.now))
            #expect(!result.staged)
            #expect(result.disposition == .missAbsent)
        }

        var hitSamples: [Duration] = []
        for index in 0 ..< 20 {
            let started = ContinuousClock.now
            let result = await cache.stage(
                requestID: "hit-\(index)", promptTokens: hitPrompt, cacheScope: "")
            hitSamples.append(started.duration(to: ContinuousClock.now))
            #expect(result.staged)
            let hit = try #require(
                cache.lookup(tokens: hitPrompt, layerKinds: fixtureLayerKinds, cacheSalt: nil))
            cache.endAdoption(tokens: hitPrompt, matched: hit.matched, cacheSalt: nil)
            cache.completeStaging(requestID: "hit-\(index)")
        }

        missSamples.sort()
        hitSamples.sort()
        let missP95 = missSamples[47]
        let hitP95 = hitSamples[18]
        let policyDeadline = Duration.milliseconds(
            Int64(SSDPrefixCachePolicy.maxStageMillis(environment: [:])))
        print("SSD stage latency: miss_p95=\(missP95) hit_p95=\(hitP95) deadline=\(policyDeadline)")
        #expect(missP95 < policyDeadline)
        #expect(hitP95 < policyDeadline)
    }

    @Test("salt isolation on disk: scoped donation is unfindable by other scopes")
    func saltIsolation() async throws {
        let dir = tempDir("salt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let cache = makeCache(dir: dir, kek: kek, clock: clock)
        defer { cache.close() }

        let tokens = Array(0 ..< tokenCount)
        donateFixture(cache, tokens: tokens, salt: "scope-a")
        #expect(await waitForIndexCount(cache, atLeast: 8))

        let prompt = tokens + [9999]
        #expect(!(await cache.stage(requestID: "r-unscoped", promptTokens: prompt, cacheScope: "")).staged)
        #expect(!(await cache.stage(requestID: "r-b", promptTokens: prompt, cacheScope: "scope-b")).staged)
        #expect((await cache.stage(requestID: "r-a", promptTokens: prompt, cacheScope: "scope-a")).staged)
        // And the staged entry only resolves under the donor's salt.
        #expect(cache.lookup(tokens: prompt, layerKinds: fixtureLayerKinds, cacheSalt: nil) == nil)
        let hit = cache.lookup(
            tokens: prompt, layerKinds: fixtureLayerKinds, cacheSalt: "scope-a")
        #expect(hit != nil)
        if hit != nil {
            cache.endAdoption(tokens: prompt, matched: hit!.matched, cacheSalt: "scope-a")
        }
        cache.completeStaging(requestID: "r-a")
    }

    @Test("corrupt block: auth failure ⇒ file deleted, index dropped, recompute fallback")
    func corruptBlockFallsBack() async throws {
        let dir = tempDir("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        // High benefit floor (7 blocks) so corruption forces total fallback
        // (reads fail at block 1, so no shorter run can ever satisfy it) —
        // while the 8-block donation still clears the per-donation gate
        // (floor = bound 0 + 56 < 64 donated tokens).
        let cache = makeCache(
            dir: dir, kek: kek, clock: clock,
            minEffectiveTokens: tokenCount - fixtureBlockSize)
        defer { cache.close() }

        let tokens = Array(0 ..< tokenCount)
        donateFixture(cache, tokens: tokens)
        #expect(await waitForIndexCount(cache, atLeast: 8))

        // Flip a byte in every block file (deterministic total corruption).
        for file in dbk3Files(under: dir) {
            var bytes = try Data(contentsOf: file)
            bytes[bytes.count - 10] ^= 0xFF
            try bytes.write(to: file)
        }
        let prompt = tokens + [12345]
        let staged = await cache.stage(requestID: "r-c", promptTokens: prompt, cacheScope: "")
        #expect(!staged.staged, "corrupt blocks must fall back to recompute, not stage")
        #expect(staged.disposition == .missCorrupt)
        #expect(cache.stats().corruptDropped >= 1)
        // The poisoned file was deleted and de-indexed.
        #expect(cache.index.count < 8)
        #expect(cache.bytesInUse == 0)
    }

    @Test("TTL: expired entries are swept (files unlinked) and never adopted")
    func ttlExpirySweep() async throws {
        let dir = tempDir("ttl")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let cache = makeCache(dir: dir, kek: kek, clock: clock, ttlSeconds: 900)
        defer { cache.close() }

        let tokens = Array(0 ..< tokenCount)
        donateFixture(cache, tokens: tokens)
        #expect(await waitForIndexCount(cache, atLeast: 8))

        // Cross the 15-minute TTL, then sweep (the write path + periodic
        // task call exactly this).
        clock.advance(901)
        cache.sweepExpiredEntries()
        #expect(cache.index.count == 0)
        #expect(dbk3Files(under: dir).isEmpty)
        #expect(cache.stats().ttlExpired == 8)
        // Nothing left to adopt.
        let prompt = tokens + [1]
        let expiredResult = await cache.stage(
            requestID: "r-t", promptTokens: prompt, cacheScope: "")
        #expect(!expiredResult.staged)
        #expect(expiredResult.disposition == .missAbsent)
    }

    @Test("TTL slides on hit: a staged (hit) entry survives what an untouched one doesn't")
    func ttlSlidesOnHit() async throws {
        let dir = tempDir("ttl-slide")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let cache = makeCache(dir: dir, kek: kek, clock: clock, ttlSeconds: 900)
        defer { cache.close() }

        let hot = Array(0 ..< tokenCount)
        let cold = Array(5000 ..< (5000 + tokenCount))
        donateFixture(cache, tokens: hot, seed: 1.0)
        donateFixture(cache, tokens: cold, seed: 2.0)
        #expect(await waitForIndexCount(cache, atLeast: 16))

        // 600 s later, HIT the hot prefix (stage bumps lastAccess).
        clock.advance(600)
        #expect((await cache.stage(requestID: "r-hot", promptTokens: hot + [7], cacheScope: "")).staged)
        cache.completeStaging(requestID: "r-hot")

        // 600 s more: the cold prefix (1,200 s idle) expires; the hot one
        // (600 s since its hit) survives.
        clock.advance(600)
        cache.sweepExpiredEntries()
        #expect(cache.index.count == 8)
        #expect((await cache.stage(requestID: "r-hot2", promptTokens: hot + [8], cacheScope: "")).staged)
        cache.completeStaging(requestID: "r-hot2")
        #expect(!(await cache.stage(requestID: "r-cold", promptTokens: cold + [9], cacheScope: "")).staged)
    }

    @Test("LRU eviction at the box-wide budget: oldest-by-last-hit unlinked first")
    func lruEvictionAtBudget() async throws {
        let dir = tempDir("lru")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let budget = SSDDiskBudget()
        let cache = makeCache(dir: dir, kek: kek, clock: clock, diskBudget: budget)
        defer { cache.close() }

        let old = Array(0 ..< tokenCount)
        donateFixture(cache, tokens: old, seed: 1.0)
        #expect(await waitForIndexCount(cache, atLeast: 8))
        let perBlockBytes = cache.index.totalBytes / 8

        clock.advance(60)  // the second prefix is strictly newer
        let fresh = Array(9000 ..< (9000 + tokenCount))
        donateFixture(cache, tokens: fresh, seed: 2.0)
        #expect(await waitForIndexCount(cache, atLeast: 16))

        // Synthetic tiny budget: room for 8 blocks ⇒ the 8 OLDEST (the
        // entire older prefix — strictly older lastAccess) are unlinked.
        // (Evicting only part of the older prefix would be
        // nondeterministic: its blocks share one lastAccess, and any
        // surviving prefix-contiguous run could still stage.)
        budget.enforce(budgetBytes: perBlockBytes * 8)
        #expect(cache.index.totalBytes <= perBlockBytes * 8)
        #expect(cache.stats().evictions >= 8)
        // The NEWER prefix must still be fully adoptable; the older one not.
        #expect((await cache.stage(requestID: "r-new", promptTokens: fresh + [1], cacheScope: "")).staged)
        cache.completeStaging(requestID: "r-new")
        #expect(!(await cache.stage(requestID: "r-old", promptTokens: old + [1], cacheScope: "")).staged)
    }

    @Test("active capacity eviction persists a new epoch before unlink")
    func activeEvictionRotatesEpoch() async throws {
        let dir = tempDir("active-epoch-eviction")
        defer { try? FileManager.default.removeItem(at: dir) }
        let layoutEpoch = SSDBlockStore.layoutEpoch(
            blockSize: fixtureBlockSize, layerKinds: fixtureLayerKinds)
        let binding = SSDCacheEpochStore.Binding(
            modelId: "test-model",
            modelAggregateHash: "test-weight-hash",
            promptContractId: "test-prompt-contract",
            blockHashVersion: CBv2BlockHasher.version,
            blockSize: fixtureBlockSize,
            layoutEpoch: layoutEpoch,
            keyFingerprint: String(repeating: "e", count: 64))
        let epochStore = try SSDCacheEpochStore(root: dir, binding: binding)
        let originalEpoch = try #require(epochStore.current)
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            epochStore: epochStore)
        defer { cache.close() }

        donateFixture(cache, tokens: Array(0 ..< tokenCount), seed: 1)
        #expect(await waitForIndexCount(cache, atLeast: 1))
        #expect(cache.evictOldestEntry() > 0)
        let rotatedEpoch = try #require(epochStore.current)
        #expect(rotatedEpoch != originalEpoch)
        #expect(try SSDCacheEpochStore(root: dir, binding: binding).current == rotatedEpoch)
    }

    @Test("capability publication waits for destructive mutation completion")
    func destructiveMutationBracketsCapabilityPublication() async throws {
        let dir = tempDir("epoch-publication-bracket")
        defer { try? FileManager.default.removeItem(at: dir) }
        let binding = SSDCacheEpochStore.Binding(
            modelId: "test-model",
            modelAggregateHash: "test-weight-hash",
            promptContractId: "test-prompt-contract",
            blockHashVersion: CBv2BlockHasher.version,
            blockSize: fixtureBlockSize,
            layoutEpoch: SSDBlockStore.layoutEpoch(
                blockSize: fixtureBlockSize, layerKinds: fixtureLayerKinds),
            keyFingerprint: String(repeating: "e", count: 64))
        let epochStore = try SSDCacheEpochStore(root: dir, binding: binding)
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            epochStore: epochStore)
        defer { cache.close() }

        cache.startBackgroundTasks(sweepIntervalSeconds: 3_600)
        var advertised: PrefixCacheV2Capability?
        for _ in 0 ..< 100 {
            advertised = cache.prefixCacheV2Capability()
            if advertised != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let original = try #require(advertised)
        let (entered, enteredContinuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let release = DispatchSemaphore(value: 0)
        let mutation = Task.detached {
            cache.holdDestructiveEpochForTesting {
                enteredContinuation.yield(())
                release.wait()
            }
        }
        var enteredIterator = entered.makeAsyncIterator()
        _ = await enteredIterator.next()

        let mutationAdvertisement = cache.prefixCacheAdvertisement(
            base: PrefixCacheModelStatus(
                modelId: "test-model",
                backend: .contiguous,
                replayStrategy: .direct,
                state: .pending,
                reason: .scanPending))
        #expect(mutationAdvertisement.capability == nil)
        #expect(mutationAdvertisement.status.state == .pending)
        #expect(mutationAdvertisement.status.reason == .scanPending)
        #expect(
            cache.takeNextPrefixCacheV2Sequence(expectedEpoch: original.cacheEpoch) == nil)

        release.signal()
        #expect(await mutation.value)
        let current = try #require(cache.prefixCacheV2Capability())
        #expect(current.cacheEpoch != original.cacheEpoch)
    }

    @Test("reconciliation drops a symlink-replaced indexed file without following it")
    func reconciliationDropsSymlinkReplacement() throws {
        let dir = tempDir("reconcile-symlink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000))
        defer { cache.close() }

        let tag = Data(repeating: 0xaa, count: 16)
        let url = SSDBlockStore.fileURL(
            root: dir, tag16Hex: SSDLookupKeys.hex(tag))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outside = dir.deletingLastPathComponent().appendingPathComponent(
            "ssd-reconcile-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside-must-survive".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: url, withDestinationURL: outside)
        cache.index.insert(tag16: tag, fileBytes: 32, lastAccess: 1)

        cache.reconcileExternalRemovals()

        #expect(cache.index.count == 0)
        #expect(try Data(contentsOf: outside) == Data("outside-must-survive".utf8))
        #expect(SSDBlockStore.indexedBlockFileStatus(at: url, under: dir) == .invalid)
    }

    @Test("budget eviction skips an undeletable oldest file and removes another victim")
    func budgetEvictionContinuesPastUndeletableOldest() throws {
        let dir = tempDir("lru-undeletable")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = SSDDiskBudget()
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            diskBudget: budget)
        defer { cache.close() }

        let oldTag = Data(repeating: 0xaa, count: 16)
        let newerTag = Data(repeating: 0xbb, count: 16)
        let oldURL = SSDBlockStore.fileURL(
            root: dir, tag16Hex: SSDLookupKeys.hex(oldTag))
        let newerURL = SSDBlockStore.fileURL(
            root: dir, tag16Hex: SSDLookupKeys.hex(newerTag))
        try FileManager.default.createDirectory(
            at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: newerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: oldURL)
        try Data(repeating: 2, count: 64).write(to: newerURL)
        cache.index.insert(tag16: oldTag, fileBytes: 64, lastAccess: 1)
        cache.index.insert(tag16: newerTag, fileBytes: 64, lastAccess: 2)

        let oldFanout = oldURL.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: oldFanout.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: oldFanout.path)
        }

        #expect(budget.enforce(budgetBytes: 64) == 1)
        #expect(cache.stats().evictions == 1)
        #expect(cache.index.count == 1)
        #expect(cache.index.contains(tag16: oldTag))
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        #expect(!FileManager.default.fileExists(atPath: newerURL.path))
    }

    @Test("TTL telemetry counts only successful owned-file removals")
    func ttlTelemetryExcludesInvalidIndexDrops() throws {
        let dir = tempDir("ttl-success-count")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            ttlSeconds: 1)
        defer { cache.close() }

        let symlinkTag = Data(repeating: 0xaa, count: 16)
        let regularTag = Data(repeating: 0xbb, count: 16)
        let symlinkURL = SSDBlockStore.fileURL(
            root: dir, tag16Hex: SSDLookupKeys.hex(symlinkTag))
        let regularURL = SSDBlockStore.fileURL(
            root: dir, tag16Hex: SSDLookupKeys.hex(regularTag))
        try FileManager.default.createDirectory(
            at: symlinkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: regularURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outside = dir.deletingLastPathComponent().appendingPathComponent(
            "ssd-ttl-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside-must-survive".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: symlinkURL, withDestinationURL: outside)
        try Data(repeating: 3, count: 64).write(to: regularURL)
        cache.index.insert(tag16: symlinkTag, fileBytes: 64, lastAccess: 1)
        cache.index.insert(tag16: regularTag, fileBytes: 64, lastAccess: 1)

        cache.sweepExpiredEntries()

        #expect(cache.index.count == 0)
        #expect(cache.stats().ttlExpired == 1)
        #expect(!FileManager.default.fileExists(atPath: regularURL.path))
        #expect(try Data(contentsOf: outside) == Data("outside-must-survive".utf8))
    }

    @Test("endurance write cap: an exhausted token bucket drops donations, engine unaffected")
    func writeCapDropsDonations() async throws {
        let dir = tempDir("cap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        // 1-byte/day cap: the first block write already exceeds it.
        let cache = makeCache(dir: dir, kek: kek, clock: clock, maxWriteBytesPerDay: 1)
        defer { cache.close() }

        donateFixture(cache, tokens: Array(0 ..< tokenCount))
        // Deterministic settling: poll until the donation is accounted as
        // dropped (either pre-extraction or in the write consumer).
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, cache.stats().donationsDropped == 0 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(cache.stats().donationsDropped >= 1)
        #expect(cache.stats().blocksWritten == 0)
        #expect(dbk3Files(under: dir).isEmpty)
    }

    @Test("exhausted write cap: donation dropped BEFORE extraction (synchronous), tags settled for retry")
    func writeCapSkipsExtractionSynchronously() async throws {
        let dir = tempDir("cap-sync")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        // 1-byte/day cap: `mightAcceptWrite(perBlockBytes)` is false from
        // the first donation.
        let cache = makeCache(dir: dir, kek: kek, clock: clock, maxWriteBytesPerDay: 1)
        defer { cache.close() }

        donateFixture(cache, tokens: Array(0 ..< tokenCount))
        // The endurance pre-check drops the donation INSIDE donate() —
        // before any device-slice/eval/host-copy and before the write-
        // behind queue — so the drop is visible synchronously, no consumer
        // polling. (Pre-fix, the drop only landed asynchronously at the
        // consumer's per-block tryConsume, after full extraction.)
        #expect(cache.stats().donationsDropped == 8)
        #expect(cache.stats().blocksWritten == 0)
        #expect(dbk3Files(under: dir).isEmpty)

        // The skip settles the in-flight dedupe tags: the SAME prefix can
        // be re-donated later (counted as dropped again) instead of being
        // stranded in `inFlightWrites` until restart.
        donateFixture(cache, tokens: Array(0 ..< tokenCount))
        #expect(cache.stats().donationsDropped == 16)
    }

    @Test("stage pre-floor is overflow-safe: absurd MIN_EFFECTIVE_TOKENS disables staging, never traps")
    func stagePreFloorOverflowSafe() async throws {
        let dir = tempDir("floor-overflow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)

        // Seed real on-disk blocks with a sanely-configured writer.
        let writer = makeCache(dir: dir, kek: kek, clock: clock)
        donateFixture(writer, tokens: Array(0 ..< tokenCount))
        #expect(await waitForIndexCount(writer, atLeast: 8))
        writer.close()

        // Same dir, operator-misconfigured benefit floor: the stage
        // pre-floor sum (adoptionBound + minEffective) would trap on naive
        // addition. It must instead saturate and DISABLE staging.
        let cache = makeCache(
            dir: dir, kek: kek, clock: clock,
            adoptionBound: 1, minEffectiveTokens: Int.max)
        defer { cache.close() }
        cache.scanOnDisk()
        #expect(cache.index.count == 8, "scan must index the seeded blocks")
        #expect(
            !(await cache.stage(
                requestID: "r-overflow",
                promptTokens: Array(0 ..< tokenCount) + [99],
                cacheScope: "")).staged)
    }
}

// MARK: - Provider-confirmed durable-ready receipts

@Suite("SSD prefix cache: durable-ready receipts", .serialized)
struct SSDPrefixCacheReadyReceiptTests {
    private func correlatedDonate(
        _ cache: SSDPrefixCache,
        requestID: CBv2RequestID,
        tokenCount: Int,
        seed: Float = 1
    ) {
        cache.donate(
            requestID: requestID,
            tokens: Array(0 ..< tokenCount),
            snapshots: fixtureSnapshots(tokenCount: tokenCount, seed: seed),
            layerKinds: fixtureLayerKinds,
            cacheSalt: "scope")
    }

    @Test("ready is durable/readable and increases across successive donations")
    func monotonicReady() async throws {
        let dir = tempDir("ready-monotonic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            minEffectiveTokens: fixtureBlockSize)
        defer { cache.close() }
        let box = ReadyReceiptBox()
        let requestID = CBv2RequestID(41)
        cache.registerReadyReceipt(requestID: requestID, callback: box.append)

        correlatedDonate(cache, requestID: requestID, tokenCount: 64)
        #expect(await box.waitForCount(1))
        #expect(box.snapshot[0].readyTokens == 64)
        #expect(box.snapshot[0].requiredRecomputeTokens == 0)
        #expect(box.snapshot[0].expectedPrefillTokensSaved == 64)
        #expect(try #require(box.snapshot[0].stageMs) > 0)
        #expect(try #require(box.snapshot[0].stageMs) <= PrefixCacheReadyResult.maxStageMs)

        correlatedDonate(cache, requestID: requestID, tokenCount: 72)
        #expect(await box.waitForCount(2))
        #expect(box.snapshot.map(\.readyTokens) == [64, 72])

        // Re-donation of the same terminal prefix is durable but must not
        // emit a duplicate/non-increasing receipt.
        correlatedDonate(cache, requestID: requestID, tokenCount: 72)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(box.snapshot.count == 2)
    }

    @Test("too-short, rate-limited, immediate-eviction, corrupt, and shutdown donations emit no ready")
    func noReadyFailureMatrix() async throws {
        func run(
            _ label: String,
            make: (URL, SymmetricKey, ClockBox) -> SSDPrefixCache,
            mutate: ((URL) -> Void)? = nil,
            closeBeforeDonate: Bool = false
        ) async -> [PrefixCacheReadyResult] {
            let dir = tempDir(label)
            defer { try? FileManager.default.removeItem(at: dir) }
            let kek = SymmetricKey(size: .bits256)
            let cache = make(dir, kek, ClockBox(10_000))
            let box = ReadyReceiptBox()
            let id = CBv2RequestID(51)
            cache.registerReadyReceipt(requestID: id, callback: box.append)
            if closeBeforeDonate { cache.close() }
            correlatedDonate(cache, requestID: id, tokenCount: 64)
            mutate?(dir)
            try? await Task.sleep(for: .milliseconds(500))
            cache.close()
            return box.snapshot
        }

        // Exactly at donation floor: no write job exists.
        let tooShortDir = tempDir("ready-short")
        defer { try? FileManager.default.removeItem(at: tooShortDir) }
        let tooShort = makeCache(
            dir: tooShortDir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            minEffectiveTokens: 64)
        let tooShortBox = ReadyReceiptBox()
        tooShort.registerReadyReceipt(requestID: CBv2RequestID(50), callback: tooShortBox.append)
        correlatedDonate(tooShort, requestID: CBv2RequestID(50), tokenCount: 64)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(tooShortBox.snapshot.isEmpty)
        tooShort.close()

        #expect(await run("ready-rate", make: { dir, kek, clock in
            makeCache(
                dir: dir, kek: kek, clock: clock,
                minEffectiveTokens: fixtureBlockSize,
                maxWriteBytesPerDay: 1)
        }).isEmpty)
        #expect(await run("ready-evict", make: { dir, kek, clock in
            makeCache(
                dir: dir, kek: kek, clock: clock,
                minEffectiveTokens: fixtureBlockSize,
                diskBudgetBytes: 0)
        }).isEmpty)
        #expect(await run("ready-shutdown", make: { dir, kek, clock in
            makeCache(
                dir: dir, kek: kek, clock: clock,
                minEffectiveTokens: fixtureBlockSize)
        }, closeBeforeDonate: true).isEmpty)

        // Corrupt every landed file inside the post-write whole-root barrier;
        // settlement's authenticated reread must suppress the receipt.
        let corruptDir = tempDir("ready-corrupt")
        defer { try? FileManager.default.removeItem(at: corruptDir) }
        let corrupt = makeCache(
            dir: corruptDir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            minEffectiveTokens: fixtureBlockSize,
            maintainWholeRoot: {
                for file in dbk3Files(under: corruptDir) {
                    guard var bytes = try? Data(contentsOf: file), bytes.count > 16 else { continue }
                    bytes[bytes.count - 8] ^= 0xff
                    try? bytes.write(to: file)
                }
            })
        let corruptBox = ReadyReceiptBox()
        corrupt.registerReadyReceipt(requestID: CBv2RequestID(52), callback: corruptBox.append)
        correlatedDonate(corrupt, requestID: CBv2RequestID(52), tokenCount: 64)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(corruptBox.snapshot.isEmpty)
        corrupt.close()
    }

    @Test("terminal cleanup retention covers the coordinator two-minute attempt window")
    func receiptRetention() {
        #expect(SSDPrefixCache.readyReceiptRetention == .seconds(120))
    }

    @Test("write-behind maintenance/ready never blocks donation return")
    func responsePathNotDelayed() async throws {
        let dir = tempDir("ready-nonblocking")
        defer { try? FileManager.default.removeItem(at: dir) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            minEffectiveTokens: fixtureBlockSize,
            maintainWholeRoot: {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            })
        defer { cache.close(); release.signal() }
        let id = CBv2RequestID(61)
        cache.registerReadyReceipt(requestID: id, callback: { _ in })
        let returned = Task {
            correlatedDonate(cache, requestID: id, tokenCount: 64)
            return true
        }
        #expect(await returned.value)
        let enteredResult = await waitForSemaphore(entered, timeout: .now() + 5)
        #expect(enteredResult == .success)
        release.signal()
    }
}

@Suite("SSD prefix cache: ready write failure barriers", .serialized)
struct SSDReadyWriteBarrierTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
        func waitForCount(_ expected: Int, timeout: Duration = .seconds(5)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if count >= expected { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return count >= expected
        }
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PrefixCacheDonationOutcome] = []

        func set(_ outcome: PrefixCacheDonationOutcome) {
            lock.withLock { values.append(outcome) }
        }

        var outcome: PrefixCacheDonationOutcome? {
            lock.withLock { values.last }
        }

        var count: Int {
            lock.withLock { values.count }
        }
    }

    private enum InjectedWriteError: Error { case failed }

    private func block(_ byte: UInt8) -> SSDBlockWrite {
        let tag = Data(repeating: byte, count: 16)
        return SSDBlockWrite(
            tag16: tag,
            tag16Hex: SSDLookupKeys.hex(tag),
            metadata: SSDBlockMetadata(
                lookupTag: String(repeating: "ab", count: 32),
                weightHash: "w",
                layoutEpoch: "layout",
                blockSize: 8,
                layerCount: 1,
                chunks: [],
                chunkPlaintextSizes: [],
                createdAt: 10_000),
            chunks: [],
            plaintextBytes: 1)
    }

    private func pipeline(
        dir: URL,
        maxJobs: Int = 2,
        volumeSpace: @escaping @Sendable () -> (free: Int, capacity: Int)? = { nil },
        writeBlock: (@Sendable (SSDBlockWrite, URL) throws -> Int)? = nil,
        onBlockSettled: @escaping @Sendable (Data) -> Void = { _ in }
    ) -> SSDWriteBehind {
        SSDWriteBehind(
            config: .init(
                root: dir,
                kekKey: SymmetricKey(size: .bits256),
                strictFsync: false,
                ttlSeconds: 0,
                maxJobs: maxJobs,
                maxQueuedBytes: 1 << 20,
                diskBudgetBytes: { 1 << 20 },
                volumeSpace: volumeSpace,
                nowSeconds: { 10_000 },
                maintainWholeRoot: nil,
                writeBlock: writeBlock),
            rateLimiter: SSDWriteRateLimiter(capBytesPerDay: 0),
            index: SSDBlockIndex(),
            diskBudget: SSDDiskBudget(),
            stats: SSDPrefixCacheStatsBox(),
            onBlockSettled: onBlockSettled,
            sweepExpired: {})
    }

    @Test("low disk, generic write error, ENOSPC, and shutdown never cross durable barrier")
    func failureMatrix() async throws {
        let dir = tempDir("ready-write-failures")
        defer { try? FileManager.default.removeItem(at: dir) }

        let lowCounter = Counter()
        let lowSettled = Counter()
        let lowOutcome = OutcomeBox()
        let low = pipeline(
            dir: dir,
            volumeSpace: { (free: 0, capacity: 1) },
            onBlockSettled: { _ in lowSettled.increment() })
        #expect(low.submit(.init(
            blocks: [block(1)], totalBytes: 1,
            onDurable: { lowCounter.increment(); return true },
            onOutcome: lowOutcome.set)))
        #expect(await lowSettled.waitForCount(1))
        low.close()
        await low.waitUntilDrained()
        #expect(lowCounter.count == 0)
        #expect(lowOutcome.outcome == .diskUnavailable)

        let errorCounter = Counter()
        let errorSettled = Counter()
        let errorOutcome = OutcomeBox()
        let generic = pipeline(
            dir: dir,
            writeBlock: { _, _ in throw InjectedWriteError.failed },
            onBlockSettled: { _ in errorSettled.increment() })
        #expect(generic.submit(.init(
            blocks: [block(2)], totalBytes: 1,
            onDurable: { errorCounter.increment(); return true },
            onOutcome: errorOutcome.set)))
        #expect(await errorSettled.waitForCount(1))
        generic.close()
        await generic.waitUntilDrained()
        #expect(errorCounter.count == 0)
        #expect(errorOutcome.outcome == .writeFailed)

        let enospcCounter = Counter()
        let enospcSettled = Counter()
        let enospcOutcome = OutcomeBox()
        let enospc = pipeline(
            dir: dir,
            writeBlock: { _, _ in throw POSIXError(.ENOSPC) },
            onBlockSettled: { _ in enospcSettled.increment() })
        #expect(enospc.submit(.init(
            blocks: [block(3)], totalBytes: 1,
            onDurable: { enospcCounter.increment(); return true },
            onOutcome: enospcOutcome.set)))
        #expect(await enospcSettled.waitForCount(1))
        enospc.close()
        await enospc.waitUntilDrained()
        #expect(enospcCounter.count == 0)
        #expect(enospcOutcome.outcome == .diskUnavailable)

        let closedCounter = Counter()
        let closed = pipeline(dir: dir)
        closed.close()
        #expect(closed.submitWithResult(.init(
            blocks: [block(4)], totalBytes: 1,
            onDurable: { closedCounter.increment(); return true })) == .closed)
        #expect(closedCounter.count == 0)
    }

    @Test("in-flight close classifies correlated and uncorrelated durable writes as cache_closed")
    func inFlightCloseOutcome() async throws {
        for correlated in [false, true] {
            let dir = tempDir("inflight-close-\(correlated)")
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let settled = Counter()
            let readyAttempted = Counter()
            let outcome = OutcomeBox()
            let writer = pipeline(
                dir: dir,
                writeBlock: { _, _ in
                    entered.signal()
                    _ = release.wait(timeout: .now() + 5)
                    return 1
                },
                onBlockSettled: { _ in settled.increment() })
            let onDurable: (@Sendable () -> Bool)?
            if correlated {
                onDurable = { @Sendable in
                    readyAttempted.increment()
                    return false
                }
            } else {
                onDurable = nil
            }

            #expect(writer.submit(.init(
                blocks: [block(correlated ? 0xA1 : 0xB2)],
                totalBytes: 1,
                onDurable: onDurable,
                onOutcome: outcome.set)))
            #expect(await waitForSemaphore(entered, timeout: .now() + 5) == .success)
            writer.close()
            release.signal()
            await writer.waitUntilDrained()

            #expect(settled.count == 1)
            #expect(readyAttempted.count == (correlated ? 1 : 0))
            #expect(outcome.outcome == .cacheClosed)
            #expect(outcome.count == 1)
            try? FileManager.default.removeItem(at: dir)
        }

        let failedDir = tempDir("inflight-close-write-failure")
        let failedEntered = DispatchSemaphore(value: 0)
        let failedRelease = DispatchSemaphore(value: 0)
        let failedOutcome = OutcomeBox()
        let failedWriter = pipeline(
            dir: failedDir,
            writeBlock: { _, _ in
                failedEntered.signal()
                _ = failedRelease.wait(timeout: .now() + 5)
                throw InjectedWriteError.failed
            })
        #expect(failedWriter.submit(.init(
            blocks: [block(0xC3)],
            totalBytes: 1,
            onOutcome: failedOutcome.set)))
        #expect(await waitForSemaphore(failedEntered, timeout: .now() + 5) == .success)
        failedWriter.close()
        failedRelease.signal()
        await failedWriter.waitUntilDrained()
        #expect(failedOutcome.outcome == .writeFailed)
        #expect(failedOutcome.count == 1)
        try? FileManager.default.removeItem(at: failedDir)
    }

    @Test("queue overflow drops the new receipt job without blocking")
    func queueDrop() async throws {
        let dir = tempDir("ready-queue-drop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let settled = Counter()
        let pipeline = pipeline(dir: dir, maxJobs: 1, writeBlock: { block, _ in
            if block.tag16.first == 1 {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            return 1
        }, onBlockSettled: { _ in settled.increment() })
        defer { release.signal(); pipeline.close() }
        #expect(pipeline.submit(.init(blocks: [block(1)], totalBytes: 1)))
        let enteredResult = await waitForSemaphore(entered, timeout: .now() + 5)
        #expect(enteredResult == .success)
        #expect(pipeline.submit(.init(blocks: [block(2)], totalBytes: 1)))
        let dropped = Counter()
        #expect(pipeline.submitWithResult(.init(
            blocks: [block(3)], totalBytes: 1,
            onDurable: { dropped.increment(); return true })) == .queueFull)
        #expect(dropped.count == 0)
        release.signal()
        #expect(await settled.waitForCount(2))
        pipeline.close()
        await pipeline.waitUntilDrained()
    }
}

// MARK: - Staging reservation hygiene

private final class BudgetAvailableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) { self.value = value }

    func set(_ value: UInt64) {
        lock.withLock { self.value = value }
    }

    var current: UInt64 {
        lock.withLock { value }
    }
}

@Suite("SSD prefix cache: staging reservations", .serialized)
struct SSDPrefixCacheReservationTests {

    private let tokenCount = 64

    private func makeBudget(headroomGiB: UInt64 = 64) -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(
            capFraction: 0.9,
            activationReserveBytes: 0,
            configReserveBytes: 0,
            memorySnapshot: {
                GlobalKVCacheBudget.MemorySnapshot(
                    total: headroomGiB * 1_073_741_824, active: 0, cache: 0,
                    systemAvailable: headroomGiB * 1_073_741_824)
            })
    }

    private func makeStagedCache(
        dir: URL, kek: SymmetricKey, clock: ClockBox, kvBudget: GlobalKVCacheBudget
    ) async -> SSDPrefixCache {
        let cache = makeCache(dir: dir, kek: kek, clock: clock, kvBudget: kvBudget)
        cache.donate(
            tokens: Array(0 ..< tokenCount),
            snapshots: fixtureSnapshots(tokenCount: tokenCount),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
        _ = await waitForIndexCount(cache, atLeast: 8)
        return cache
    }

    private func waitForZeroOutstanding(
        _ budget: GlobalKVCacheBudget, timeout: Duration = .seconds(10)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await budget.outstandingReservedBytes() == 0 { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await budget.outstandingReservedBytes() == 0
    }

    @Test("success path: reserve before read, release at endAdoption")
    func successPathReleases() async throws {
        let dir = tempDir("res-ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        let cache = await makeStagedCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock, kvBudget: budget)
        defer { cache.close() }

        let prompt = Array(0 ..< tokenCount) + [1]
        #expect((await cache.stage(requestID: "req-ok", promptTokens: prompt, cacheScope: "")).staged)
        #expect(await budget.outstandingReservedBytes() > 0)
        let hit = try #require(
            cache.lookup(tokens: prompt, layerKinds: fixtureLayerKinds, cacheSalt: nil))
        cache.endAdoption(tokens: prompt, matched: hit.matched, cacheSalt: nil)
        #expect(await waitForZeroOutstanding(budget), "endAdoption must release the reservation")
        #expect(cache.bytesInUse == 0)
    }

    @Test("corrupt tail block: reservation + accounting shrink to the SHORTENED run")
    func shortenedRunShrinksReservation() async throws {
        let dir = tempDir("res-shortened")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        let kek = SymmetricKey(size: .bits256)
        let cache = await makeStagedCache(
            dir: dir, kek: kek, clock: clock, kvBudget: budget)
        defer { cache.close() }

        // Identify the LAST chain block's file via the production name
        // derivation (chain hash -> HMAC tag under K_lookup) and corrupt it,
        // so stage() reads 7 good blocks and then hits the auth failure.
        let tokens = Array(0 ..< tokenCount)
        let hasher = CBv2BlockHasher(
            blockSize: fixtureBlockSize, promptContractID: "test-prompt-contract")
        let chain = hasher.chainHashes(tokens: tokens)
        let keys = SSDLookupKeys(kek: kek)
        let fileURL: (Int) -> URL = { i in
            SSDBlockStore.fileURL(
                root: dir,
                tag16Hex: SSDLookupKeys.hex(
                    keys.tag16(chainHash: chain[i], cacheSalt: "")))
        }
        let lastURL = fileURL(chain.count - 1)
        var bytes = try Data(contentsOf: lastURL)
        bytes[bytes.count - 10] ^= 0xFF
        try bytes.write(to: lastURL)

        let prompt = tokens + [7]
        let stageResult = await cache.stage(
            requestID: "req-short", promptTokens: prompt, cacheScope: "")
        #expect(stageResult.staged)
        #expect(stageResult.disposition == .staged(
            matchedTokens: 7 * fixtureBlockSize,
            expectedPrefillTokensSaved: 7 * fixtureBlockSize,
            shortenedByCorruption: true))
        let expectedBytes = stageResult.deviceBytes
        #expect(expectedBytes > 0)
        #expect(cache.stats().corruptDropped == 1)
        // Regression (Codex, v0.7.5 SSD review): the reservation and the
        // staging accounting must reflect exact rehydrated MLX bytes for the
        // SHORTENED run — never the original run or encrypted file overhead.
        #expect(await budget.outstandingReservedBytes() == UInt64(expectedBytes))
        #expect(cache.bytesInUse == expectedBytes)

        // The shortened run adopts and the balanced release drains fully.
        let hit = try #require(
            cache.lookup(tokens: prompt, layerKinds: fixtureLayerKinds, cacheSalt: nil))
        #expect(hit.matched == (chain.count - 1) * fixtureBlockSize)
        cache.endAdoption(tokens: prompt, matched: hit.matched, cacheSalt: nil)
        #expect(await waitForZeroOutstanding(budget), "endAdoption must release the reservation")
        #expect(cache.bytesInUse == 0)
    }

    @Test("backstop path (lookup never ran): completeStaging releases")
    func backstopReleases() async throws {
        let dir = tempDir("res-backstop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        let cache = await makeStagedCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock, kvBudget: budget)
        defer { cache.close() }

        let prompt = Array(0 ..< tokenCount) + [1]
        #expect((await cache.stage(requestID: "req-b", promptTokens: prompt, cacheScope: "")).staged)
        #expect(await budget.outstandingReservedBytes() > 0)
        cache.completeStaging(requestID: "req-b")
        #expect(await waitForZeroOutstanding(budget))
        #expect(cache.bytesInUse == 0)
        // Idempotent.
        cache.completeStaging(requestID: "req-b")
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("cancel path: a cancelled staging task releases and stages nothing")
    func cancelReleases() async throws {
        let dir = tempDir("res-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        let cache = await makeStagedCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock, kvBudget: budget)
        defer { cache.close() }

        let prompt = Array(0 ..< tokenCount) + [1]
        let task = Task { () -> Bool in
            // Guarantee the cancellation flag is observed before staging
            // starts its read loop.
            while !Task.isCancelled { await Task.yield() }
            return (await cache.stage(requestID: "req-x", promptTokens: prompt, cacheScope: "")).staged
        }
        task.cancel()
        let staged = await task.value
        #expect(!staged)
        #expect(await waitForZeroOutstanding(budget))
        #expect(cache.bytesInUse == 0)
    }

    @Test("refusal path: no shared-budget headroom ⇒ no staging, no leak")
    func refusalUnderPressure() async throws {
        let dir = tempDir("res-refuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        // A budget whose headroom is ~zero: total tiny, everything reserved.
        let budget = GlobalKVCacheBudget(
            capFraction: 0.9,
            activationReserveBytes: 0,
            configReserveBytes: 0,
            memorySnapshot: {
                GlobalKVCacheBudget.MemorySnapshot(
                    total: 1, active: 0, cache: 0, systemAvailable: 1)
            })
        let clock = ClockBox(10_000)
        let cache = await makeStagedCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock, kvBudget: budget)
        defer { cache.close() }

        let prompt = Array(0 ..< tokenCount) + [1]
        let staged = await cache.stage(requestID: "req-p", promptTokens: prompt, cacheScope: "")
        #expect(!staged.staged, "refusal under memory pressure must be a silent recompute")
        #expect(staged.disposition == .skippedCapacity)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(cache.bytesInUse == 0)
    }

    @Test("conversion peak reserves host, per-block MLX, and concatenated arrays")
    func conversionPeakReservationCoversThreeRepresentations() async throws {
        let dir = tempDir("res-conversion-peak")
        defer { try? FileManager.default.removeItem(at: dir) }
        let available = BudgetAvailableBox(64 * 1_073_741_824)
        let budget = GlobalKVCacheBudget(
            capFraction: 0.9,
            activationReserveBytes: 0,
            configReserveBytes: 0,
            memorySnapshot: {
                GlobalKVCacheBudget.MemorySnapshot(
                    total: 64 * 1_073_741_824,
                    active: 0,
                    cache: 0,
                    systemAvailable: available.current)
            })
        let cache = await makeStagedCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            kvBudget: budget)
        defer { cache.close() }
        let fileBytes = try dbk3Files(under: dir).reduce(0) { total, url in
            total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        #expect(fileBytes > 0)
        available.set(UInt64(fileBytes * 5 / 2))

        let refused = await cache.stage(
            requestID: "req-peak",
            promptTokens: Array(0 ..< tokenCount) + [1],
            cacheScope: "")
        #expect(refused.disposition == .skippedCapacity)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(cache.bytesInUse == 0)

        available.set(UInt64(fileBytes * 4))
        let staged = await cache.stage(
            requestID: "req-peak-success",
            promptTokens: Array(0 ..< tokenCount) + [1],
            cacheScope: "")
        #expect(staged.staged)
        #expect(staged.deviceBytes > 0)
        #expect(await budget.outstandingReservedBytes() == UInt64(staged.deviceBytes))
        cache.completeStaging(requestID: "req-peak-success")
        #expect(await waitForZeroOutstanding(budget))
        #expect(cache.bytesInUse == 0)
    }

    @Test("close(): open tickets drained, reservations released, files kept")
    func closeDrainsTickets() async throws {
        let dir = tempDir("res-close")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        let cache = await makeStagedCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock, kvBudget: budget)

        let prompt = Array(0 ..< tokenCount) + [1]
        #expect((await cache.stage(requestID: "req-c", promptTokens: prompt, cacheScope: "")).staged)
        #expect(await budget.outstandingReservedBytes() > 0)
        cache.close()
        #expect(await waitForZeroOutstanding(budget))
        #expect(cache.bytesInUse == 0)
        // On-disk files SURVIVE close — durable warmth is the feature.
        #expect(!dbk3Files(under: dir).isEmpty)
    }

    @Test("concurrent same-prefix requests bind exact tickets to one reserved entry")
    func sharedEntryReservedExactlyOnce() async throws {
        // Regression (Codex, v0.7.5 SSD review — SSDPrefixCache staging
        // ticket accounting): when two concurrent same-prefix requests
        // attach to a single staged entry, the shared KV budget must be
        // charged for that entry's bytes EXACTLY ONCE, and the reservation
        // must persist for the whole residency window. Pre-fix, each
        // attached request took its own per-request reservation (double
        // charge), and `endAdoption` popped an ARBITRARY staging ticket —
        // so one request's adoption could release a still-pinned peer's
        // reservation, leaving the resident staged MLX arrays with NO
        // GlobalKVCacheBudget reservation (an over-admission hole under the
        // memory cap).
        let dir = tempDir("res-shared")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        let cache = await makeStagedCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock, kvBudget: budget)
        defer { cache.close() }

        let prompt = Array(0 ..< tokenCount) + [1]
        let requestA = CBv2RequestID(101)
        let requestB = CBv2RequestID(102)
        // Race both stages. One creates the entry and the other attaches,
        // regardless of which disk read wins.
        async let stageA = cache.stage(
            requestID: requestA, promptTokens: prompt, cacheScope: "")
        async let stageB = cache.stage(
            requestID: requestB, promptTokens: prompt, cacheScope: "")
        let (resultA, resultB) = await (stageA, stageB)
        #expect(resultA.staged)
        #expect(resultB.staged)
        let sharedReservation = await budget.outstandingReservedBytes()
        #expect(sharedReservation > 0)
        // Charged ONCE: attaching adds a residency ticket, not a reservation.
        // (Pre-fix this was 2 × afterA.)
        #expect(
            sharedReservation == UInt64(cache.bytesInUse),
            "attaching to a staged entry must not add a second reservation")
        #expect(cache.bytesInUse == Int(sharedReservation))

        // An unrelated request cannot consume either staged ticket. B can
        // finish while A's lookup is still delayed without stealing A's pin.
        #expect(cache.lookup(
            requestID: CBv2RequestID(999),
            tokens: prompt,
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil) == nil)
        let hitB = try #require(cache.lookup(
            requestID: requestB,
            tokens: prompt,
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil))
        cache.endAdoption(
            requestID: requestB,
            tokens: prompt,
            matched: hitB.matched,
            cacheSalt: nil)
        cache.completeStaging(requestID: requestB)
        #expect(
            await budget.outstandingReservedBytes() == sharedReservation,
            "a resident shared entry must stay reserved until its LAST user leaves")
        #expect(cache.bytesInUse == Int(sharedReservation))

        // A's slower lookup remains valid after B's terminal backstop. Only
        // A can balance A's ticket; then the shared reservation drains.
        let hitA = try #require(cache.lookup(
            requestID: requestA,
            tokens: prompt,
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil))
        cache.endAdoption(
            requestID: requestA,
            tokens: prompt,
            matched: hitA.matched,
            cacheSalt: nil)
        cache.completeStaging(requestID: requestA)
        #expect(await waitForZeroOutstanding(budget), "the last user must drain the entry reservation")
        #expect(cache.bytesInUse == 0)
    }

    @Test("same-prefix attachment needs no spare provisional headroom")
    func attachAtCapacity() async throws {
        let dir = tempDir("res-attach-full")
        defer { try? FileManager.default.removeItem(at: dir) }
        let available = BudgetAvailableBox(64 * 1_073_741_824)
        let budget = GlobalKVCacheBudget(
            capFraction: 0.9,
            activationReserveBytes: 0,
            configReserveBytes: 0,
            memorySnapshot: {
                GlobalKVCacheBudget.MemorySnapshot(
                    total: 64 * 1_073_741_824,
                    active: 0,
                    cache: 0,
                    systemAvailable: available.current)
            })
        let cache = await makeStagedCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            kvBudget: budget)
        defer { cache.close() }
        let prompt = Array(0 ..< tokenCount) + [1]
        let first = await cache.stage(
            requestID: "attach-a",
            promptTokens: prompt,
            cacheScope: "")
        #expect(first.staged)
        let reserved = await budget.outstandingReservedBytes()
        #expect(reserved == UInt64(first.deviceBytes))
        available.set(reserved)

        let second = await cache.stage(
            requestID: "attach-b",
            promptTokens: prompt,
            cacheScope: "")
        #expect(second.staged)
        #expect(second.deviceBytes == first.deviceBytes)
        #expect(await budget.outstandingReservedBytes() == reserved)

        cache.completeStaging(requestID: "attach-a")
        cache.completeStaging(requestID: "attach-b")
        #expect(await waitForZeroOutstanding(budget))
    }

    @Test("two cache instances may reserve the same raw receipt id independently")
    func instanceNamespacesPreventGlobalReservationCollisions() async throws {
        let parent = tempDir("res-instance-namespace")
        defer { try? FileManager.default.removeItem(at: parent) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent("aaaaaaaaaaaa"),
            withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent("bbbbbbbbbbbb"),
            withIntermediateDirectories: false)
        let cacheA = await makeStagedCache(
            dir: parent.appendingPathComponent("aaaaaaaaaaaa"),
            kek: SymmetricKey(size: .bits256),
            clock: clock,
            kvBudget: budget)
        let cacheB = await makeStagedCache(
            dir: parent.appendingPathComponent("bbbbbbbbbbbb"),
            kek: SymmetricKey(size: .bits256),
            clock: clock,
            kvBudget: budget)
        defer { cacheA.close(); cacheB.close() }

        let requestID = CBv2RequestID(1)
        let prompt = Array(0 ..< tokenCount) + [1]
        let resultA = await cacheA.stage(
            requestID: requestID, promptTokens: prompt, cacheScope: "")
        let resultB = await cacheB.stage(
            requestID: requestID, promptTokens: prompt, cacheScope: "")

        #expect(resultA.staged)
        #expect(resultB.staged)
        #expect(await budget.outstandingReservedBytes()
            == UInt64(cacheA.bytesInUse + cacheB.bytesInUse))
        #expect((await budget.reservationIDsForTesting()).count == 2)

        await cacheA.abandonStaging(requestID: requestID)
        await cacheB.abandonStaging(requestID: requestID)
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}

// MARK: - Own-root isolation (legacy upgrade sweeper safety)

@Suite("SSD prefix cache: own root survives the legacy kv sweep")
struct SSDRootIsolationTests {

    @Test("cacheDirectory lives under darkbloom/kv3, never under the legacy darkbloom/kv root")
    func rootIsOutsideLegacyTree() {
        let dir = SSDPrefixCacheFactory.cacheDirectory(modelId: "gpt-oss-20b")
        let path = dir.path
        #expect(path.contains("/darkbloom/kv3/"),
            "SSD tier must use its own root: \(path)")
        // The critical invariant: NOT inside the legacy root the upgrade
        // sweeper sheds (kv3 is a SIBLING of kv, not a subtree).
        #expect(!path.contains("/darkbloom/kv/"),
            "SSD tier must never live under the legacy kv root: \(path)")
        // Stable modelKey derivation (12-hex prefix of SHA256(modelId)).
        #expect(dir.lastPathComponent.count == 12)
    }

    @Test("the REAL legacy sweeper (LegacyKVCacheSweeper.sweep) leaves SSD entries intact and adoptable")
    func legacySweepSurvival() async throws {
        // Layout mirroring production: <caches>/darkbloom/kv (legacy) and
        // <caches>/darkbloom/kv3/<modelKey> (SSD) as SIBLINGS.
        let caches = tempDir("sweep-survival")
        defer { try? FileManager.default.removeItem(at: caches) }
        let legacyRoot = caches.appendingPathComponent("darkbloom/kv", isDirectory: true)
        let ssdDir = caches.appendingPathComponent(
            "darkbloom/kv3/aaaa11112222", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(
            at: legacyRoot.appendingPathComponent("aaaa11112222"),
            withIntermediateDirectories: true)
        try Data([1]).write(
            to: legacyRoot.appendingPathComponent("aaaa11112222/old.darkbloom-kv"))
        try fm.createDirectory(at: ssdDir, withIntermediateDirectories: true)

        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let writer = makeCache(dir: ssdDir, kek: kek, clock: clock)
        let tokens = Array(0 ..< 64)
        writer.donate(
            tokens: tokens,
            snapshots: fixtureSnapshots(tokenCount: 64),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
        #expect(await waitForIndexCount(writer, atLeast: 8))
        writer.close()

        // THE LEGACY SWEEP — the REAL production sweeper (the exact code
        // `ProviderLoop.run()` / the standalone server invoke at startup),
        // pointed at this layout's kv/ root: it sheds the retired tier's
        // ciphertext wholesale. kv3/ (a SIBLING, not a subtree) must be
        // untouched.
        let sweptBytes = LegacyKVCacheSweeper.sweep(kvRoot: legacyRoot)
        #expect(sweptBytes > 0, "the sweeper must have removed the legacy tier's bytes")
        #expect(!fm.fileExists(atPath: legacyRoot.path), "the legacy kv/ root must be gone")

        #expect(dbk3Files(under: ssdDir).count == 8, "SSD entries must survive the legacy sweep")
        // And they remain fully adoptable: fresh cache, scan, stage.
        let reader = makeCache(dir: ssdDir, kek: kek, clock: clock)
        defer { reader.close() }
        reader.scanOnDisk()
        #expect(reader.index.count == 8)
        #expect((await reader.stage(
            requestID: "r-survive", promptTokens: tokens + [1], cacheScope: "")).staged)
        reader.completeStaging(requestID: "r-survive")
    }
}

@Suite("SSD prefix cache: unloaded whole-root maintenance", .serialized)
struct SSDWholeRootMaintenanceTests {
    private func writeOwnedFile(
        root: URL,
        modelKey: String,
        tagHex: String,
        modifiedAt: Int64,
        payloadBytes: Int = 128
    ) throws -> URL {
        let modelRoot = root.appendingPathComponent(modelKey, isDirectory: true)
        try SSDBlockStore.prepareModelRoot(
            dedicatedRoot: root,
            modelRoot: modelRoot)
        let url = SSDBlockStore.fileURL(root: modelRoot, tag16Hex: tagHex)
        let chunk = Data(repeating: 7, count: payloadBytes)
        let metadata = SSDBlockMetadata(
            lookupTag: String(repeating: "ab", count: 32),
            weightHash: "weight",
            layoutEpoch: "layout",
            blockSize: 8,
            layerCount: 1,
            chunks: [.init(
                layerIndex: 0,
                tensor: 0,
                shape: [1, 1, 1, 1],
                dtype: "float16")],
            chunkPlaintextSizes: [chunk.count],
            createdAt: modifiedAt)
        try SSDBlockStore.write(
            to: url,
            metadata: metadata,
            chunks: [chunk],
            kekKey: SymmetricKey(size: .bits256))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(modifiedAt))],
            ofItemAtPath: url.path)
        return url
    }

    private func writeOwnedTemp(
        root: URL,
        modelKey: String,
        tagHex: String,
        uuid: UUID,
        modifiedAt: Int64,
        payloadBytes: Int
    ) throws -> URL {
        let destination = SSDBlockStore.fileURL(
            root: root.appendingPathComponent(modelKey, isDirectory: true),
            tag16Hex: tagHex)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let url = SSDBlockStore.temporaryFileURL(for: destination, uuid: uuid)
        try Data(repeating: 9, count: payloadBytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(modifiedAt))],
            ofItemAtPath: url.path)
        return url
    }

    @Test("startup sweep expires files in unloaded model directories")
    func unloadedTTL() throws {
        let root = tempDir("whole-root-ttl")
        defer { try? FileManager.default.removeItem(at: root) }
        let expired = try writeOwnedFile(
            root: root,
            modelKey: "aaaaaaaaaaaa",
            tagHex: "aa00112233445566778899aabbccddee",
            modifiedAt: 1_000)
        let fresh = try writeOwnedFile(
            root: root,
            modelKey: "bbbbbbbbbbbb",
            tagHex: "bb00112233445566778899aabbccddee",
            modifiedAt: 1_950)

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 900,
            nowSeconds: 2_000,
            budgetBytes: Int.max)
        #expect(result.ttlExpired == 1)
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("20 GiB-style budget is global across unloaded model directories")
    func globalBudget() throws {
        let root = tempDir("whole-root-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try writeOwnedFile(
            root: root,
            modelKey: "111111111111",
            tagHex: "1100112233445566778899aabbccddee",
            modifiedAt: 1_000,
            payloadBytes: 256)
        let fresh = try writeOwnedFile(
            root: root,
            modelKey: "222222222222",
            tagHex: "2200112233445566778899aabbccddee",
            modifiedAt: 2_000,
            payloadBytes: 256)
        let freshBytes = try fresh.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 10_000,
            nowSeconds: 2_100,
            budgetBytes: freshBytes)
        #expect(result.budgetEvicted == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(result.bytesAfter <= freshBytes)
    }

    @Test("whole-root eviction durably rotates the model epoch before unlink")
    func evictionRotatesEpoch() throws {
        let root = tempDir("whole-root-epoch")
        defer { try? FileManager.default.removeItem(at: root) }
        let modelKey = "333333333333"
        let modelRoot = root.appendingPathComponent(modelKey, isDirectory: true)
        let block = try writeOwnedFile(
            root: root,
            modelKey: modelKey,
            tagHex: "3300112233445566778899aabbccddee",
            modifiedAt: 1_000,
            payloadBytes: 256)
        let binding = SSDCacheEpochStore.Binding(
            modelId: "model",
            modelAggregateHash: String(repeating: "a", count: 64),
            promptContractId: String(repeating: "b", count: 64),
            blockHashVersion: CBv2BlockHasher.version,
            blockSize: 256,
            layoutEpoch: "layout",
            keyFingerprint: String(repeating: "c", count: 64))
        let active = try SSDCacheEpochStore(root: modelRoot, binding: binding)
        let original = try #require(active.current)

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 10_000,
            nowSeconds: 2_000,
            budgetBytes: 0)
        #expect(result.budgetEvicted == 1)
        #expect(!FileManager.default.fileExists(atPath: block.path))
        #expect(active.current == nil, "the previously advertised epoch must be disabled")

        let reopened = try SSDCacheEpochStore(root: modelRoot, binding: binding)
        let rotated = try #require(reopened.current)
        #expect(rotated != original)
    }

    @Test("whole-root eviction keeps an active cache on the rotated epoch")
    func activeWholeRootEvictionKeepsCapabilityReady() async throws {
        let root = tempDir("whole-root-active-epoch")
        defer { try? FileManager.default.removeItem(at: root) }
        let modelRoot = root.appendingPathComponent("444444444444", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelRoot, withIntermediateDirectories: true)
        let binding = SSDCacheEpochStore.Binding(
            modelId: "test-model",
            modelAggregateHash: "test-weight-hash",
            promptContractId: "test-prompt-contract",
            blockHashVersion: CBv2BlockHasher.version,
            blockSize: fixtureBlockSize,
            layoutEpoch: SSDBlockStore.layoutEpoch(
                blockSize: fixtureBlockSize, layerKinds: fixtureLayerKinds),
            keyFingerprint: String(repeating: "d", count: 64))
        let epochStore = try SSDCacheEpochStore(root: modelRoot, binding: binding)
        let cache = makeCache(
            dir: modelRoot,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            diskBudget: .shared,
            epochStore: epochStore)
        defer { cache.close() }
        cache.startBackgroundTasks(sweepIntervalSeconds: 3_600)

        var advertised: PrefixCacheV2Capability?
        for _ in 0 ..< 100 {
            advertised = cache.prefixCacheV2Capability()
            if advertised != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let original = try #require(advertised)
        let tokens = Array(0 ..< 64)
        cache.donate(
            tokens: tokens,
            snapshots: fixtureSnapshots(tokenCount: tokens.count),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
        #expect(await waitForIndexCount(cache, atLeast: 1))
        await cache.waitForWritesForTesting()

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 10_000,
            nowSeconds: 10_000,
            budgetBytes: 0)
        #expect(result.budgetEvicted > 0)
        SSDDiskBudget.shared.reconcileAll()

        let rotated = try #require(cache.prefixCacheV2Capability())
        #expect(rotated.cacheEpoch != original.cacheEpoch)
        #expect(cache.index.count == 0)
    }

    @Test("young temp bytes consume global budget without making the active temp evictable")
    func youngTempBudgetAccounting() throws {
        let root = tempDir("whole-root-temp-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = try writeOwnedFile(
            root: root,
            modelKey: "111111111111",
            tagHex: "1100112233445566778899aabbccddee",
            modifiedAt: 1_000,
            payloadBytes: 256)
        let now: Int64 = 10_000
        let temp = try writeOwnedTemp(
            root: root,
            modelKey: "222222222222",
            tagHex: "2200112233445566778899aabbccddee",
            uuid: #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")),
            modifiedAt: now - SSDBlockStore.crashTempTTLSeconds + 1,
            payloadBytes: 257)
        let tempBytes = try #require(
            temp.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 0,
            nowSeconds: now,
            budgetBytes: tempBytes)
        #expect(result.budgetEvicted == 1)
        #expect(!FileManager.default.fileExists(atPath: completed.path))
        #expect(FileManager.default.fileExists(atPath: temp.path))
        #expect(result.bytesAfter == tempBytes)

        let belowTempBudget = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 0,
            nowSeconds: now,
            budgetBytes: tempBytes - 1)
        #expect(belowTempBudget.budgetEvicted == 0)
        #expect(belowTempBudget.bytesAfter == tempBytes)
        #expect(FileManager.default.fileExists(atPath: temp.path))
    }

    @Test("malformed exact-looking files remain untouched without DBK3 ownership proof")
    func malformedLookalikePreserved() throws {
        let root = tempDir("whole-root-lookalike")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("abcdefabcdef", isDirectory: true)
        let fanout = model.appendingPathComponent("ab", isDirectory: true)
        try FileManager.default.createDirectory(at: fanout, withIntermediateDirectories: true)
        let lookalike = fanout.appendingPathComponent(
            "ab00112233445566778899aabbccddee.dbk3")
        try Data("not-a-darkbloom-block".utf8).write(to: lookalike)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: lookalike.path)

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 1,
            nowSeconds: 10_000,
            budgetBytes: 0)
        #expect(result.filesSeen == 0)
        #expect(FileManager.default.fileExists(atPath: lookalike.path))
    }

    @Test("maintenance rejects roots reached through a symlinked ancestor")
    func symlinkedRootIsNeverTraversed() throws {
        let container = tempDir("whole-root-symlink-container")
        let root = container.appendingPathComponent("kv3", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = try writeOwnedTemp(
            root: root,
            modelKey: "abcdefabcdef",
            tagHex: "ab00112233445566778899aabbccddee",
            uuid: try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")),
            modifiedAt: 1_000,
            payloadBytes: 64)
        let alias = container.deletingLastPathComponent().appendingPathComponent(
            "ssd-prefix-root-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: container)
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: container)
        }
        let aliasedRoot = alias.appendingPathComponent("kv3", isDirectory: true)

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: aliasedRoot,
            ttlSeconds: 1,
            nowSeconds: 10_000,
            budgetBytes: 0)
        #expect(result == SSDWholeRootMaintainer.Result())
        #expect(SSDBlockStore.sweepStaleTempFiles(
            under: aliasedRoot.appendingPathComponent("abcdefabcdef", isDirectory: true),
            nowSeconds: 10_000) == 0)
        #expect(FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("whole-root sweep preserves young and near-match temps but removes stale owned temps")
    func tempCleanupUsesAgeAndExactOwnership() throws {
        let root = tempDir("whole-root-temp-ownership")
        defer { try? FileManager.default.removeItem(at: root) }
        let now: Int64 = 10_000
        let uuid = "01234567-89AB-CDEF-0123-456789ABCDEF"
        let tag = "ab00112233445566778899aabbccddee"
        let exactName = "\(tag).dbk3.darkbloom-tmp.\(uuid)"

        func create(
            _ relativeDirectory: String,
            _ name: String,
            modifiedAt: Int64 = 0
        ) throws -> URL {
            let directory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try Data("incomplete".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(modifiedAt))],
                ofItemAtPath: url.path)
            return url
        }

        let stale = try create(
            "abcdefabcdef/ab", exactName,
            modifiedAt: now - SSDBlockStore.crashTempTTLSeconds)
        let young = try create(
            "abcdefabcdef/ab",
            "\(tag).dbk3.darkbloom-tmp.31234567-89AB-CDEF-0123-456789ABCDEF",
            modifiedAt: now - SSDBlockStore.crashTempTTLSeconds + 1)
        let preserved = try [
            young,
            // UUID values differ so case-only near-matches remain distinct on
            // the default case-insensitive macOS filesystem.
            create("abcdefabcdef/ab", "\(tag).dbk3.darkbloom-tmp.11234567-89ab-cdef-0123-456789abcdef"),
            create("abcdefabcdef/ab", "\(tag).dbk3.darkbloom-tmp.21234567-89AB-cDEF-0123-456789ABCDef"),
            create("abcdefabcdef/ab", "AB00112233445566778899aabbccddee.dbk3.darkbloom-tmp.11234567-89AB-CDEF-0123-456789ABCDEF"),
            create("abcdefabcdef/ab", "\(tag).dbk3.darkbloom-tmp.not-a-uuid"),
            create("abcdefabcdef/ab", "\(tag).dbk3.darkbloom-tmp-\(uuid)"),
            create("abcdefabcdef/ab", "\(tag).dbk3.darkbloom-tmp.\(uuid).extra"),
            create("abcdefabcdef/cd", exactName),
            create("not-a-model/ab", exactName),
            create("abcdefabcdef/not-fanout", exactName),
        ]

        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: 0,
            nowSeconds: now,
            budgetBytes: 0)
        #expect(result.tempFilesRemoved == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        for url in preserved {
            #expect(FileManager.default.fileExists(atPath: url.path), "preserved \(url.path)")
        }
    }

    @Test("periodic maintenance sweeps stale unloaded-model temps and can restart")
    func periodicRestartSeam() async throws {
        let root = tempDir("whole-root-periodic")
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
            try? FileManager.default.removeItem(at: root)
        }
        let destination = SSDBlockStore.fileURL(
            root: root.appendingPathComponent("abcdefabcdef", isDirectory: true),
            tag16Hex: "ab00112233445566778899aabbccddee")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = SSDBlockStore.temporaryFileURL(
            for: destination,
            uuid: try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")))
        try Data("incomplete".utf8).write(to: temp)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970:
                TimeInterval(10_000 - SSDBlockStore.crashTempTTLSeconds))],
            ofItemAtPath: temp.path)

        SSDWholeRootMaintainer.shared.startPeriodicMaintenance(
            root: root,
            ttlSeconds: 900,
            intervalSeconds: 3600,
            nowSeconds: { 10_000 },
            budgetBytes: { 1 << 20 })
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline,
            FileManager.default.fileExists(atPath: temp.path)
        {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)

        let restartedTemp = SSDBlockStore.temporaryFileURL(
            for: destination,
            uuid: try #require(UUID(uuidString: "11234567-89AB-CDEF-0123-456789ABCDEF")))
        try Data("second-incomplete".utf8).write(to: restartedTemp)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970:
                TimeInterval(10_000 - SSDBlockStore.crashTempTTLSeconds))],
            ofItemAtPath: restartedTemp.path)
        SSDWholeRootMaintainer.shared.startPeriodicMaintenance(
            root: root,
            ttlSeconds: 900,
            intervalSeconds: 3600,
            nowSeconds: { 10_000 },
            budgetBytes: { 1 << 20 })
        let restartDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < restartDeadline,
            FileManager.default.fileExists(atPath: restartedTemp.path)
        {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: restartedTemp.path))
    }
}

// MARK: - Per-donation gate (replaces the SSD tier's per-model funding rule)

@Suite("SSD prefix cache: per-donation gate", .serialized)
struct SSDPrefixCacheDonationGateTests {

    /// Poll briefly and assert NOTHING was written (negative settling).
    private func expectNoWrites(_ cache: SSDPrefixCache, dir: URL) async {
        try? await Task.sleep(for: .milliseconds(300))
        #expect(cache.stats().blocksWritten == 0)
        #expect(cache.index.count == 0)
        #expect(dbk3Files(under: dir).isEmpty)
    }

    private func donate(_ cache: SSDPrefixCache, tokenCount: Int) {
        cache.donate(
            tokens: Array(0 ..< tokenCount),
            snapshots: fixtureSnapshots(tokenCount: tokenCount),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
    }

    @Test("gpt-oss constants: sub-2.5k donations skipped, above-floor donations persist")
    func gptOssConstantsGate() async throws {
        let dir = tempDir("gate-gptoss")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ClockBox(10_000)
        // Real gpt-oss-20b numbers: bound 12 × 128 = 1,536; benefit floor
        // 1,024 ⇒ persist only donations of MORE than 2,560 tokens.
        let cache = makeCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock,
            blockSize: 256, adoptionBound: 1536, minEffectiveTokens: 1024)
        defer { cache.close() }

        // Exactly at the floor (2,560 = 10 whole blocks): not adoptable ⇒
        // skipped (disk-wear win; nothing on disk).
        donate(cache, tokenCount: 2560)
        await expectNoWrites(cache, dir: dir)

        // One block past the floor: persists ALL its whole blocks (the
        // leading blocks are needed for the contiguous adoption run).
        donate(cache, tokenCount: 2816 + 3)  // 11 whole blocks + tail
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, cache.index.count < 11 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(cache.index.count == 11)
        #expect(dbk3Files(under: dir).count == 11)
    }

    @Test("gemma constants: the >27.1k evidence-backed tail caches; shorter writes nothing")
    func gemmaConstantsGate() async throws {
        let dir = tempDir("gate-gemma")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ClockBox(10_000)
        // Real Gemma numbers: bound 25,600 + measured saved-token floor 1,536.
        let cache = makeCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock,
            blockSize: 256, adoptionBound: 25_600, minEffectiveTokens: 1_536)
        defer { cache.close() }

        // A typical prompt (4k) AND the exact floor both write nothing —
        // the negative that used to be enforced by excluding gemma wholesale.
        donate(cache, tokenCount: 4096)
        await expectNoWrites(cache, dir: dir)
        donate(cache, tokenCount: 27_136)
        await expectNoWrites(cache, dir: dir)

        // The long-context tail (107 whole blocks = 27,392 tokens) persists.
        donate(cache, tokenCount: 27_392 + 5)
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline, cache.index.count < 107 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(cache.index.count == 107)
    }

    @Test("unknown/saturated adoption bound: never persists (the only 'never cached' case)")
    func saturatedBoundNeverPersists() async throws {
        let dir = tempDir("gate-unknown")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ClockBox(10_000)
        let cache = makeCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock,
            blockSize: 256, adoptionBound: Int.max, minEffectiveTokens: 1024)
        defer { cache.close() }
        donate(cache, tokenCount: 26_880)
        await expectNoWrites(cache, dir: dir)
    }

    @Test("persisted-run byte cap: blocks beyond maxStageBytes are never written (leading run kept)")
    func byteCapTrimsPersistedRun() async throws {
        let dir = tempDir("gate-bytecap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ClockBox(10_000)
        // Fixture block bytes: 2 tensors × [1,2,8,8] f16 = 2 × 256 B = 512 B
        // PLAINTEXT (the donate-side cap's unit). Cap at 3 blocks' worth:
        // an 8-block donation persists only blocks 1..3 (a valid contiguous
        // prefix run); 4.. are unstageable wear.
        let kek = SymmetricKey(size: .bits256)
        let writer = makeCache(
            dir: dir, kek: kek, clock: clock,
            minEffectiveTokens: fixtureBlockSize, maxStageBytes: 3 * 512)
        writer.donate(
            tokens: Array(0 ..< 64),
            snapshots: fixtureSnapshots(tokenCount: 64),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
        #expect(await waitForIndexCount(writer, atLeast: 3))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(writer.index.count == 3)
        #expect(dbk3Files(under: dir).count == 3)
        writer.close()

        // The persisted run is the LEADING prefix (contiguous from block 1):
        // a reader with an uncapped STAGE budget (the stage cap counts
        // on-disk bytes, which include DBK3 overhead) adopts exactly the
        // 3 persisted blocks.
        let reader = makeCache(
            dir: dir, kek: kek, clock: clock, minEffectiveTokens: fixtureBlockSize)
        defer { reader.close() }
        reader.scanOnDisk()
        let staged = await reader.stage(
            requestID: "r-cap", promptTokens: Array(0 ..< 64) + [1], cacheScope: "")
        #expect(staged.staged)
        let hit = reader.lookup(
            tokens: Array(0 ..< 64) + [1], layerKinds: fixtureLayerKinds, cacheSalt: nil)
        #expect(hit?.matched == 3 * fixtureBlockSize)
        if let hit {
            reader.endAdoption(
                tokens: Array(0 ..< 64) + [1], matched: hit.matched, cacheSalt: nil)
        }
        reader.completeStaging(requestID: "r-cap")
    }

    @Test("stage cap below hybrid benefit floor writes no unusable blocks")
    func byteCapBelowBenefitFloorSkipsDonation() async throws {
        let dir = tempDir("gate-bytecap-floor")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            adoptionBound: 32,
            minEffectiveTokens: 8,
            maxStageBytes: 3 * 512)
        defer { cache.close() }

        donate(cache, tokenCount: 64)
        await expectNoWrites(cache, dir: dir)
    }

    @Test("write-behind admits one full max-size (~600 MB) donation; oversize is dropped, never stalled")
    func writeBehindBigDonationAdmission() async throws {
        let dir = tempDir("gate-bigjob")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Effective queue-byte cap must clear a ~600 MB gemma tail donation.
        let effectiveCap = max(
            SSDPrefixCachePolicy.writeQueueMaxBytes,
            SSDPrefixCachePolicy.defaultMaxStageBytes + SSDPrefixCachePolicy.writeQueueSlackBytes)
        #expect(effectiveCap > 629_145_600)

        let kek = SymmetricKey(size: .bits256)
        let stats = SSDPrefixCacheStatsBox()
        let index = SSDBlockIndex()
        let writeBehind = SSDWriteBehind(
            config: SSDWriteBehind.Config(
                root: dir, kekKey: kek, strictFsync: false, ttlSeconds: 0,
                maxJobs: 2, maxQueuedBytes: effectiveCap,
                diskBudgetBytes: { 1 << 40 },
                volumeSpace: { nil },
                nowSeconds: { 10_000 },
                maintainWholeRoot: nil,
                writeBlock: nil),
            rateLimiter: SSDWriteRateLimiter(capBytesPerDay: 0),
            index: index, diskBudget: SSDDiskBudget(), stats: stats,
            onBlockSettled: { _ in }, sweepExpired: {})
        defer { writeBehind.close() }

        // A job CLAIMING 600 MB (tiny real chunks — admission is what's
        // under test) is admitted and consumed: graceful, no stall.
        func syntheticJob(tagByte: UInt8, claimedBytes: Int) -> SSDDonationJob {
            let tag16 = Data(repeating: tagByte, count: 16)
            let chunk = Data(repeating: 1, count: 256)
            let metadata = SSDBlockMetadata(
                lookupTag: SSDLookupKeys.hex(tag16 + tag16),
                weightHash: "w", layoutEpoch: "e", blockSize: 8, layerCount: 2,
                chunks: [
                    SSDBlockChunkDescriptor(
                        layerIndex: 0, tensor: 0, shape: [1, 2, 8, 8], dtype: "float16")
                ],
                chunkPlaintextSizes: [256], createdAt: 10_000)
            return SSDDonationJob(
                blocks: [SSDBlockWrite(
                    tag16: tag16, tag16Hex: SSDLookupKeys.hex(tag16),
                    metadata: metadata, chunks: [chunk], plaintextBytes: 256)],
                totalBytes: claimedBytes)
        }
        #expect(writeBehind.submit(syntheticJob(tagByte: 0xA1, claimedBytes: 629_145_600)))
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, stats.snapshot().blocksWritten < 1 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(stats.snapshot().blocksWritten == 1, "600 MB donation must be consumed, not stalled")

        // A job larger than the whole cap is rejected IMMEDIATELY
        // (deterministic regardless of consumer state) — drop, not stall.
        #expect(!writeBehind.submit(syntheticJob(tagByte: 0xB2, claimedBytes: effectiveCap + 1)))
    }
}

private final class DonationOutcomeRecorder: PrefixCacheDonationRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [PrefixCacheDonationOutcome: Int] = [:]

    func record(_ outcome: PrefixCacheDonationOutcome) {
        lock.withLock { counts[outcome, default: 0] += 1 }
    }

    func count(_ outcome: PrefixCacheDonationOutcome) -> Int {
        lock.withLock { counts[outcome, default: 0] }
    }
}

@Suite("SSD prefix cache: donation outcomes", .serialized)
struct SSDPrefixCacheDonationOutcomeTests {
    @Test("every donation opportunity settles one bounded outcome")
    func branchOutcomes() async throws {
        let root = tempDir("donation-outcomes")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DonationOutcomeRecorder()

        let noBlock = makeCache(
            dir: root.appendingPathComponent("no-block"),
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            donationRecorder: recorder)
        noBlock.donate(
            tokens: Array(0 ..< 7),
            snapshots: fixtureSnapshots(tokenCount: 7),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)

        let belowFloor = makeCache(
            dir: root.appendingPathComponent("floor"),
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            adoptionBound: 8,
            minEffectiveTokens: 8,
            donationRecorder: recorder)
        belowFloor.donate(
            tokens: Array(0 ..< 16),
            snapshots: fixtureSnapshots(tokenCount: 16),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)

        let incomplete = makeCache(
            dir: root.appendingPathComponent("incomplete"),
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            donationRecorder: recorder)
        incomplete.donate(
            tokens: Array(0 ..< 16),
            snapshots: [nil, nil],
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)

        let stageCapped = makeCache(
            dir: root.appendingPathComponent("stage-cap"),
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            maxStageBytes: 512,
            donationRecorder: recorder)
        stageCapped.donate(
            tokens: Array(0 ..< 16),
            snapshots: fixtureSnapshots(tokenCount: 16),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)

        let rateLimited = makeCache(
            dir: root.appendingPathComponent("rate"),
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            maxWriteBytesPerDay: 1,
            donationRecorder: recorder)
        rateLimited.donate(
            tokens: Array(0 ..< 16),
            snapshots: fixtureSnapshots(tokenCount: 16),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)

        let closed = makeCache(
            dir: root.appendingPathComponent("closed"),
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            donationRecorder: recorder)
        closed.close()
        closed.donate(
            tokens: Array(0 ..< 16),
            snapshots: fixtureSnapshots(tokenCount: 16),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)

        #expect(recorder.count(.noCompleteBlock) == 1)
        #expect(recorder.count(.belowEffectiveTokenFloor) == 1)
        #expect(recorder.count(.incompleteLayerState) == 1)
        #expect(recorder.count(.stageSizeExceeded) == 1)
        #expect(recorder.count(.writeRateLimited) == 1)
        #expect(recorder.count(.cacheClosed) == 1)

        for cache in [noBlock, belowFloor, incomplete, stageCapped, rateLimited] {
            cache.close()
        }
    }

    @Test("durable and deduplicated donations settle distinctly")
    func durableOutcomes() async throws {
        let dir = tempDir("donation-durable")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = DonationOutcomeRecorder()
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            donationRecorder: recorder)
        defer { cache.close() }

        let tokens = Array(0 ..< 16)
        let snapshots = fixtureSnapshots(tokenCount: tokens.count)
        cache.donate(
            tokens: tokens,
            snapshots: snapshots,
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
        await cache.waitForWritesForTesting()
        #expect(recorder.count(.donated) == 1)

        cache.donate(
            tokens: tokens,
            snapshots: snapshots,
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
        #expect(recorder.count(.alreadyDurable) == 1)
        let total = PrefixCacheDonationOutcome.allCases.reduce(0) {
            $0 + recorder.count($1)
        }
        #expect(total == 2)
    }
}

// MARK: - WS-4.2 windowed sidecar

/// Layout with a window that TILES: blockSize 8, window 16 ⇒ two sidecars per
/// window. Layer 0 is the full-attention (block-cached) layer, layers 1 and 2
/// are storage-owning sliding layers, layer 3 borrows layer 1's KV and must
/// therefore never be persisted.
private let sidecarBlockSize = 8
private let sidecarWindow = 16
private let sidecarLayerKinds: [CBv2LayerKind] = [
    CBv2LayerKind(attention: .full, headDim: fixtureHeadDim, kvHeads: fixtureKVHeads, queryHeads: 4),
    CBv2LayerKind(
        attention: .slidingWindow(sidecarWindow), headDim: fixtureHeadDim,
        kvHeads: fixtureKVHeads, queryHeads: 4),
    CBv2LayerKind(
        attention: .slidingWindow(sidecarWindow), headDim: fixtureHeadDim,
        kvHeads: fixtureKVHeads, queryHeads: 4),
    CBv2LayerKind(
        attention: .slidingWindow(sidecarWindow), sharesKVWithLayer: 1,
        headDim: fixtureHeadDim, kvHeads: fixtureKVHeads, queryHeads: 4),
]

private func sidecarGeometry() -> SSDWindowSidecarGeometry {
    SSDWindowSidecarGeometry.derive(
        layerKinds: sidecarLayerKinds, blockSize: sidecarBlockSize)!
}

private func makeSidecarCache(
    dir: URL,
    kek: SymmetricKey,
    clock: ClockBox,
    geometry: SSDWindowSidecarGeometry? = sidecarGeometry(),
    adoptionBound: Int = 0,
    maxStageBytes: Int = 1 << 30
) -> SSDPrefixCache {
    let config = SSDPrefixCache.Config(
        modelId: "sidecar-model",
        promptContractID: "sidecar-prompt-contract",
        weightHash: "sidecar-weight-hash",
        blockSize: sidecarBlockSize,
        adoptionBoundTokens: adoptionBound,
        layoutEpoch: SSDBlockStore.layoutEpoch(
            blockSize: sidecarBlockSize, layerKinds: sidecarLayerKinds),
        root: dir,
        ttlSeconds: 900,
        minEffectiveTokens: sidecarBlockSize,
        maxStageBytes: maxStageBytes,
        maxStageMillis: 1_000_000,
        windowSidecar: geometry,
        nowSeconds: { clock.now })
    return SSDPrefixCache(
        config: config, kekKey: kek, kvBudget: nil, diskBudget: SSDDiskBudget(),
        maxWriteBytesPerDay: 0, strictFsync: false,
        diskBudgetBytes: { 1 << 40 })
}

/// Full-layer snapshots (layer 0 only) covering `tokenCount` tokens.
private func sidecarSnapshots(tokenCount: Int)
    -> [(keys: MLXArray, values: MLXArray, offset: Int)?]
{
    _ = LiveInferenceFixtures.ensureMetallibColocated()
    let shape = [1, fixtureKVHeads, tokenCount, fixtureHeadDim]
    let count = shape.reduce(1, *)
    let base = MLXArray(0 ..< count).reshaped(shape).asType(.float16)
    eval(base)
    return [(keys: base, values: (base + 0.5).asType(.float16), offset: tokenCount), nil, nil, nil]
}

/// Sliding-window payloads anchored at `base`, distinct per layer so a
/// layer-order bug cannot pass by accident.
private func sidecarWindows(base: Int, tokens: Int = sidecarWindow)
    -> [SSDWindowSidecar.Window?]
{
    _ = LiveInferenceFixtures.ensureMetallibColocated()
    let shape = [1, fixtureKVHeads, tokens, fixtureHeadDim]
    let count = shape.reduce(1, *)
    func payload(_ seed: Float) -> SSDWindowSidecar.Window {
        let ramp = MLXArray(0 ..< count).reshaped(shape).asType(.float16)
        let keys = (ramp + seed).asType(.float16)
        let values = (ramp - seed).asType(.float16)
        eval(keys, values)
        return (keys: keys, values: values, base: base)
    }
    return [nil, payload(1), payload(2), nil]
}

private func maxAbs(_ a: MLXArray, _ b: MLXArray) -> Float {
    abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
}

@Suite("SSD prefix cache: windowed sidecar (WS-4.2)")
struct SSDWindowSidecarTests {

    private let tokenCount = 64  // 8 whole blocks at blockSize 8

    // MARK: Geometry

    @Test("geometry derives only for layouts whose window tiles into whole blocks")
    func geometryDerivation() {
        let geometry = try! #require(
            SSDWindowSidecarGeometry.derive(
                layerKinds: sidecarLayerKinds, blockSize: sidecarBlockSize))
        #expect(geometry.windowTokens == 16)
        #expect(geometry.blocksPerWindow == 2)
        #expect(geometry.layerCount == 4)
        // The KV-SHARED sliding layer borrows storage and must not be
        // persisted; only the two owning sliding layers are.
        #expect(geometry.layers.map(\.index) == [1, 2])

        func kinds(sliding: Int, window: Int, full: Int) -> [CBv2LayerKind] {
            (0 ..< sliding).map { _ in
                CBv2LayerKind(
                    attention: .slidingWindow(window), headDim: 256, kvHeads: 8, queryHeads: 16)
            } + (0 ..< full).map { _ in
                CBv2LayerKind(attention: .full, headDim: 512, kvHeads: 2, queryHeads: 16)
            }
        }
        // gemma-4-26B: 25 sliding × 1024 + 5 full, at the production block size.
        #expect(
            SSDWindowSidecarGeometry.derive(
                layerKinds: kinds(sliding: 25, window: 1024, full: 5),
                blockSize: 256)?.blocksPerWindow == 4)
        // gpt-oss-20b's 128-token window is SHORTER than one block, so it can
        // never be tiled — it keeps its 1,536-token replay bound.
        #expect(
            SSDWindowSidecarGeometry.derive(
                layerKinds: kinds(sliding: 12, window: 128, full: 12), blockSize: 256) == nil)
        // A window that is not a whole number of blocks fails closed.
        #expect(
            SSDWindowSidecarGeometry.derive(
                layerKinds: kinds(sliding: 4, window: 300, full: 1), blockSize: 256) == nil)
        // Pure full attention has no window to persist.
        #expect(
            SSDWindowSidecarGeometry.derive(
                layerKinds: kinds(sliding: 0, window: 0, full: 24), blockSize: 256) == nil)
        // Mixed window sizes: one payload cannot serve two windows.
        var mixed = kinds(sliding: 2, window: 1024, full: 1)
        mixed[0].attention = .slidingWindow(512)
        #expect(SSDWindowSidecarGeometry.derive(layerKinds: mixed, blockSize: 256) == nil)
    }

    @Test("coveredBlocks: a mid-block donor covers W/blockSize − 1 blocks, and donors tile")
    func coverageArithmetic() {
        let geometry = sidecarGeometry()  // window 16 = 2 blocks of 8
        // Block-aligned donor at offset 64 retains [48, 64) ⇒ blocks 6 and 7.
        #expect(geometry.coveredBlocks(base: 48, tokens: 16, blockCount: 8) == 6 ..< 8)
        // The general case: a donor that stopped mid-block at offset 61 retains
        // [45, 61) and covers only block 6. This is the physics that makes the
        // sidecar PER-BLOCK rather than per-window.
        #expect(geometry.coveredBlocks(base: 45, tokens: 16, blockCount: 8) == 6 ..< 7)
        // Two donors straddling a boundary tile it: 61 gives block 6, 68 gives
        // block 7, and together they complete the window ending at 64.
        #expect(geometry.coveredBlocks(base: 52, tokens: 16, blockCount: 8) == 7 ..< 8)
        // Never more blocks than a window spans, even from a longer payload.
        #expect(geometry.coveredBlocks(base: 0, tokens: 64, blockCount: 8) == 6 ..< 8)
        // Degenerate inputs produce no coverage rather than a bad slice.
        #expect(geometry.coveredBlocks(base: 0, tokens: 0, blockCount: 8).isEmpty)
        #expect(geometry.coveredBlocks(base: 3, tokens: 4, blockCount: 8).isEmpty)
        #expect(geometry.coveredBlocks(base: 48, tokens: 16, blockCount: 0).isEmpty)
    }

    @Test("sidecar tags come from a separate HMAC domain and never collide with block tags")
    func tagDomainSeparation() {
        let keys = SSDLookupKeys(kek: SymmetricKey(size: .bits256))
        let hash = Data(SHA256.hash(data: Data("prefix".utf8)))
        let block = keys.tag(chainHash: hash, cacheSalt: "")
        let window = keys.windowTag(chainHash: hash, cacheSalt: "")
        #expect(block != window)
        #expect(window.count == 32)
        #expect(keys.windowTag16(chainHash: hash, cacheSalt: "").count == 16)
        #expect(keys.windowTag16(chainHash: hash, cacheSalt: "") == window.prefix(16))
        // Scope isolation holds in the sidecar domain too.
        #expect(keys.windowTag(chainHash: hash, cacheSalt: "a") != window)
    }

    @Test("an ordinary block's canonical metadata JSON is unchanged by the new fields")
    func metadataBackwardCompatibility() throws {
        // The AAD is the canonical JSON, so a nil window field that serialized
        // would break every pre-existing file's auth tag on read.
        let metadata = SSDBlockMetadata(
            lookupTag: String(repeating: "ab", count: 32),
            weightHash: "w", layoutEpoch: "e", blockSize: 8, layerCount: 2,
            chunks: [], chunkPlaintextSizes: [], createdAt: 1000)
        let json = try #require(String(
            data: try SSDBlockStore.canonicalEncode(metadata), encoding: .utf8))
        #expect(!json.contains("windowKind"))
        #expect(!json.contains("windowBase"))
        #expect(!json.contains("windowTokens"))
        // …and a sidecar's does carry them, authenticated.
        let sidecar = SSDBlockMetadata(
            lookupTag: String(repeating: "ab", count: 32),
            weightHash: "w", layoutEpoch: "e", blockSize: 8, layerCount: 2,
            chunks: [], chunkPlaintextSizes: [], createdAt: 1000,
            windowKind: SSDWindowSidecar.kind, windowBase: 48, windowTokens: 8)
        let sidecarJSON = try #require(String(
            data: try SSDBlockStore.canonicalEncode(sidecar), encoding: .utf8))
        #expect(sidecarJSON.contains("\"windowBase\":48"))
        #expect(sidecarJSON.contains("\"windowKind\":\"sliding-window-v1\""))
    }

    // MARK: Lifecycle

    @Test("stage → restart → rehydrate: a windowed sidecar survives and restores byte-exactly")
    func sidecarRestartRoundTrip() async throws {
        let dir = tempDir("sidecar-warmth")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let tokens = Array(0 ..< tokenCount)
        let windowBase = tokenCount - sidecarWindow  // 48
        let windows = sidecarWindows(base: windowBase)

        let writer = makeSidecarCache(dir: dir, kek: kek, clock: clock)
        writer.donate(
            requestID: nil,
            tokens: tokens,
            snapshots: sidecarSnapshots(tokenCount: tokenCount),
            windowSnapshots: windows,
            layerKinds: sidecarLayerKinds,
            cacheSalt: nil)
        // 8 blocks + 2 sidecars tiling [48, 64).
        #expect(await waitForIndexCount(writer, atLeast: 10))
        await writer.waitForWritesForTesting()
        #expect(writer.stats().windowSidecarsWritten == 2)
        #expect(dbk3Files(under: dir).count == 10)
        writer.close()

        // "Restart": a fresh instance over the same dir and install key. The
        // directory scan is the whole recovery protocol — sidecars are indexed
        // by the same pass that indexes blocks.
        let reader = makeSidecarCache(dir: dir, kek: kek, clock: clock)
        defer { reader.close() }
        reader.scanOnDisk()
        #expect(reader.index.count == 10)

        let prompt = tokens + [9_001]
        let staged = await reader.stage(
            requestID: "req-window", promptTokens: prompt, cacheScope: "")
        #expect(staged.staged)
        #expect(staged.stagedTokens == tokenCount)
        #expect(reader.stats().windowsRestored == 1)

        let restored = try #require(reader.stagedWindow(requestID: "req-window"))
        #expect(restored.count == 4)
        #expect(restored[0] == nil)  // full-attention layer: blocks, not sidecar
        #expect(restored[3] == nil)  // KV-shared sliding layer: borrows layer 1
        for layer in [1, 2] {
            let entry = try #require(restored[layer])
            #expect(entry.base == windowBase, "restored window must anchor at M − W")
            #expect(entry.keys.shape == [1, fixtureKVHeads, sidecarWindow, fixtureHeadDim])
            let donor = try #require(windows[layer])
            #expect(maxAbs(entry.keys, donor.keys) == 0)
            #expect(maxAbs(entry.values, donor.values) == 0)
        }

        // The block adoption is unaffected and still byte-exact.
        let (matched, prefix) = try #require(
            reader.lookup(tokens: prompt, layerKinds: sidecarLayerKinds, cacheSalt: nil))
        #expect(matched == tokenCount)
        let adopted = try #require(prefix[0])
        let donorFull = try #require(sidecarSnapshots(tokenCount: tokenCount)[0])
        #expect(maxAbs(adopted.keys, donorFull.keys) == 0)

        reader.endAdoption(tokens: prompt, matched: matched, cacheSalt: nil)
        #expect(reader.bytesInUse == 0)
        #expect(reader.stagedWindow(requestID: "req-window") == nil)
    }

    @Test("an incomplete tiling replays instead of restoring a PARTIAL window")
    func partialTilingIsRefused() async throws {
        let dir = tempDir("sidecar-partial")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let tokens = Array(0 ..< tokenCount)

        let cache = makeSidecarCache(dir: dir, kek: kek, clock: clock)
        defer { cache.close() }
        // A donor that stopped mid-block: window [45, 61) covers block 6 only,
        // so the window ending at 64 can never be assembled from it alone.
        cache.donate(
            requestID: nil,
            tokens: tokens,
            snapshots: sidecarSnapshots(tokenCount: tokenCount),
            windowSnapshots: sidecarWindows(base: 45),
            layerKinds: sidecarLayerKinds,
            cacheSalt: nil)
        #expect(await waitForIndexCount(cache, atLeast: 9))
        await cache.waitForWritesForTesting()
        #expect(cache.stats().windowSidecarsWritten == 1)

        let staged = await cache.stage(
            requestID: "req-partial", promptTokens: tokens + [7], cacheScope: "")
        #expect(staged.staged, "the block run still adopts")
        #expect(cache.stagedWindow(requestID: "req-partial") == nil)
        #expect(cache.stats().windowsRestored == 0)
    }

    @Test("two donors straddling a boundary tile its window; the second completes it")
    func donorsTileTheWindow() async throws {
        let dir = tempDir("sidecar-tile")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let tokens = Array(0 ..< tokenCount)
        let snapshots = sidecarSnapshots(tokenCount: tokenCount)

        let cache = makeSidecarCache(dir: dir, kek: kek, clock: clock)
        defer { cache.close() }
        // Donor A stopped at 61: covers block 6 ([48, 56)).
        cache.donate(
            requestID: nil, tokens: tokens, snapshots: snapshots,
            windowSnapshots: sidecarWindows(base: 45),
            layerKinds: sidecarLayerKinds, cacheSalt: nil)
        #expect(await waitForIndexCount(cache, atLeast: 9))
        await cache.waitForWritesForTesting()
        #expect(cache.stagedWindow(requestID: "none") == nil)

        // Donor B stopped at 68: covers block 7 ([56, 64)). Same prefix, so its
        // eight blocks dedupe — only the missing sidecar is written.
        cache.donate(
            requestID: nil, tokens: tokens, snapshots: snapshots,
            windowSnapshots: sidecarWindows(base: 52),
            layerKinds: sidecarLayerKinds, cacheSalt: nil)
        #expect(await waitForIndexCount(cache, atLeast: 10))
        await cache.waitForWritesForTesting()
        #expect(cache.stats().windowSidecarsWritten == 2)

        let staged = await cache.stage(
            requestID: "req-tiled", promptTokens: tokens + [7], cacheScope: "")
        #expect(staged.staged)
        let restored = try #require(cache.stagedWindow(requestID: "req-tiled"))
        // Block 6 came from donor A (base 45 ⇒ offset 3 into its payload),
        // block 7 from donor B (base 52 ⇒ offset 4).
        let a = try #require(sidecarWindows(base: 45)[1])
        let b = try #require(sidecarWindows(base: 52)[1])
        let entry = try #require(restored[1])
        #expect(entry.base == 48)
        #expect(maxAbs(
            entry.keys[.ellipsis, 0 ..< 8, 0...],
            a.keys[.ellipsis, 3 ..< 11, 0...]) == 0)
        #expect(maxAbs(
            entry.keys[.ellipsis, 8 ..< 16, 0...],
            b.keys[.ellipsis, 4 ..< 12, 0...]) == 0)
    }

    @Test("a corrupted sidecar drops the window only; the block adoption stands")
    func corruptSidecarDegradesToReplay() async throws {
        let dir = tempDir("sidecar-corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let tokens = Array(0 ..< tokenCount)

        let writer = makeSidecarCache(dir: dir, kek: kek, clock: clock)
        writer.donate(
            requestID: nil, tokens: tokens,
            snapshots: sidecarSnapshots(tokenCount: tokenCount),
            windowSnapshots: sidecarWindows(base: 48),
            layerKinds: sidecarLayerKinds, cacheSalt: nil)
        #expect(await waitForIndexCount(writer, atLeast: 10))
        await writer.waitForWritesForTesting()
        writer.close()

        // Flip one byte of the LAST sidecar's ciphertext body.
        let keys = SSDLookupKeys(kek: kek)
        let hasher = CBv2BlockHasher(
            blockSize: sidecarBlockSize,
            promptContractID: "sidecar-prompt-contract",
            scopeID: "")
        let hashes = hasher.chainHashes(tokens: tokens)
        let victim = SSDBlockStore.fileURL(
            root: dir,
            tag16Hex: SSDLookupKeys.hex(
                keys.windowTag16(chainHash: hashes[7], cacheSalt: "")))
        var bytes = try Data(contentsOf: victim)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: victim)

        let reader = makeSidecarCache(dir: dir, kek: kek, clock: clock)
        defer { reader.close() }
        reader.scanOnDisk()
        let staged = await reader.stage(
            requestID: "req-corrupt", promptTokens: tokens + [7], cacheScope: "")
        #expect(staged.staged, "corruption in an accelerator must not cost the block run")
        #expect(staged.stagedTokens == tokenCount)
        #expect(reader.stagedWindow(requestID: "req-corrupt") == nil)
        #expect(reader.stats().corruptDropped == 1)
        // Fail-closed: the unreadable sidecar is unlinked and de-indexed.
        #expect(!FileManager.default.fileExists(atPath: victim.path))
    }

    @Test("the feature is OFF by default: no geometry ⇒ no sidecars, no window")
    func disabledByDefault() async throws {
        #expect(!SSDPrefixCachePolicy.windowSidecarEnabled(environment: [:]))
        let dir = tempDir("sidecar-off")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = makeSidecarCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: ClockBox(10_000),
            geometry: nil)
        defer { cache.close() }
        let tokens = Array(0 ..< tokenCount)
        cache.donate(
            requestID: nil, tokens: tokens,
            snapshots: sidecarSnapshots(tokenCount: tokenCount),
            windowSnapshots: sidecarWindows(base: 48),
            layerKinds: sidecarLayerKinds, cacheSalt: nil)
        #expect(await waitForIndexCount(cache, atLeast: 8))
        await cache.waitForWritesForTesting()
        #expect(cache.index.count == 8, "only the full-attention blocks")
        #expect(cache.stats().windowSidecarsWritten == 0)
        let staged = await cache.stage(
            requestID: "req-off", promptTokens: tokens + [7], cacheScope: "")
        #expect(staged.staged)
        #expect(cache.stagedWindow(requestID: "req-off") == nil)
    }

    @Test("the contiguous windowed ring conforms to the donor seam WS-4.1 freezes")
    func contiguousDonorSeam() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let row = CBv2WindowedSequenceKV(
            window: sidecarWindow, kvHeads: fixtureKVHeads, headDim: fixtureHeadDim)
        #expect((row as any SSDWindowSnapshotting).windowSnapshot() == nil, "empty row")
        let shape = [1, fixtureKVHeads, 24, fixtureHeadDim]
        let chunk = MLXArray(0 ..< shape.reduce(1, *)).reshaped(shape).asType(.float16)
        eval(chunk)
        _ = row.update(keys: chunk, values: chunk)
        let snapshot = try! #require((row as any SSDWindowSnapshotting).windowSnapshot())
        // 24 tokens written into a 16-slot ring ⇒ the window is [8, 24).
        #expect(snapshot.keys.dim(2) == sidecarWindow)
        #expect(snapshot.base == 24 - sidecarWindow)
        #expect(maxAbs(snapshot.keys, chunk[.ellipsis, 8 ..< 24, 0...]) == 0)
    }

    // MARK: Economics

    @Test("gemma-4 sidecar economics: 10:1 sliding:full, 200 MiB read, 140 ms planned")
    func gemmaEconomics() throws {
        let sliding = CBv2LayerKind(
            attention: .slidingWindow(1024), headDim: 256, kvHeads: 8, queryHeads: 16)
        let full = CBv2LayerKind(attention: .full, headDim: 512, kvHeads: 2, queryHeads: 16)
        let gemma = (0 ..< 5).flatMap { _ in Array(repeating: sliding, count: 5) + [full] }
        let geometry = try #require(
            SSDWindowSidecarGeometry.derive(layerKinds: gemma, blockSize: 256))
        #expect(geometry.layers.count == 25)
        #expect(geometry.blocksPerWindow == 4)

        // One sidecar = 50 MiB; the full-attention block it rides beside is
        // 5 MiB. That 10:1 is the real economics of WS-4.2 and it is a
        // property of gemma-4's geometry (25 × 8 × 256 sliding against
        // 5 × 2 × 512 full), not of this format.
        let sidecarBytes = geometry.bytesPerBlock(elementSize: 2)
        #expect(sidecarBytes == 52_428_800)
        var fullBlockBytes = 0
        for kind in gemma where kind.attention == .full {
            fullBlockBytes += 2 * kind.kvHeads * 256 * kind.headDim * 2
        }
        #expect(fullBlockBytes == 5_242_880)
        #expect(sidecarBytes / fullBlockBytes == 10)

        // "read-terminal-four": one adoption reads four sidecars = 200 MiB,
        // which the conservative 1.5 GB/s planner costs at 140 ms against the
        // 1,000 ms stage budget, and which fits the 1 GiB per-adoption cap
        // with room for 164 blocks (41,984 tokens) of prefix.
        #expect(geometry.windowReadBytes(elementSize: 2) == 209_715_200)
        #expect(
            SSDPrefixCachePolicy.estimatedStageMillis(
                bytes: geometry.windowReadBytes(elementSize: 2)) == 140)
        #expect(SSDPrefixCachePolicy.estimatedStageMillis(
            bytes: geometry.windowReadBytes(elementSize: 2))
            < SSDPrefixCachePolicy.defaultMaxStageMillis)
        let blocksLeft =
            (SSDPrefixCachePolicy.defaultMaxStageBytes
                - geometry.windowReadBytes(elementSize: 2)) / fullBlockBytes
        #expect(blocksLeft == 164)
    }

    @Test("staging a window costs the sidecar read and nothing structural")
    func stageDelta() async throws {
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let tokens = Array(0 ..< tokenCount)

        func stageMs(withSidecar: Bool) async throws -> Double {
            let dir = tempDir("sidecar-delta-\(withSidecar)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let geometry = withSidecar ? sidecarGeometry() : nil
            let cache = makeSidecarCache(
                dir: dir, kek: kek, clock: clock, geometry: geometry)
            defer { cache.close() }
            cache.donate(
                requestID: nil, tokens: tokens,
                snapshots: sidecarSnapshots(tokenCount: tokenCount),
                windowSnapshots: sidecarWindows(base: 48),
                layerKinds: sidecarLayerKinds, cacheSalt: nil)
            #expect(await waitForIndexCount(cache, atLeast: withSidecar ? 10 : 8))
            await cache.waitForWritesForTesting()
            let staged = await cache.stage(
                requestID: "req-delta", promptTokens: tokens + [7], cacheScope: "")
            #expect(staged.staged)
            #expect((cache.stagedWindow(requestID: "req-delta") != nil) == withSidecar)
            return staged.stageMs
        }

        let cold = try await stageMs(withSidecar: false)
        let warm = try await stageMs(withSidecar: true)
        // The sidecar read is bounded work on the same pipeline, not a new
        // phase: it must stay well inside the stage deadline.
        #expect(warm < Double(SSDPrefixCachePolicy.defaultMaxStageMillis))
        #expect(cold < Double(SSDPrefixCachePolicy.defaultMaxStageMillis))
    }
}
