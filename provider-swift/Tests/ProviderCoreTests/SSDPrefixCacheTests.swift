// Copyright © 2026 Eigen Labs.
//
// Unit suite for the encrypted SSD KV-offload prefix cache (v0.7.5):
// HMAC name derivation (keyed + salt-scoped), DBK2 round-trip + AAD
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
    let url = FileManager.default.temporaryDirectory
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
    diskBudget: SSDDiskBudget = SSDDiskBudget()
) -> SSDPrefixCache {
    let config = SSDPrefixCache.Config(
        modelId: "test-model",
        weightHash: "test-weight-hash",
        blockSize: blockSize,
        adoptionBoundTokens: adoptionBound,
        layoutEpoch: SSDBlockStore.layoutEpoch(
            blockSize: blockSize, layerKinds: fixtureLayerKinds),
        root: dir,
        ttlSeconds: ttlSeconds,
        minEffectiveTokens: minEffectiveTokens,
        maxStageBytes: maxStageBytes,
        maxStageMillis: 1_000_000,
        nowSeconds: { clock.now })
    return SSDPrefixCache(
        config: config, kekKey: kek, kvBudget: kvBudget, diskBudget: diskBudget,
        maxWriteBytesPerDay: maxWriteBytesPerDay, strictFsync: false,
        diskBudgetBytes: { diskBudgetBytes })
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

private func dbk2Files(under root: URL) -> [URL] {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return [] }
    return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "dbk2" }
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

// MARK: - DBK2 codec

@Suite("SSD prefix cache: DBK2 block store")
struct SSDBlockStoreTests {

    private func fixtureMetadata(sizes: [Int]) -> SSDBlockMetadata {
        SSDBlockMetadata(
            lookupTag: String(repeating: "ab", count: 32),
            weightHash: "w-hash",
            layoutEpoch: "cbv2-snap-1|f16|8|deadbeef",
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

    @Test("header length fields decode correctly across sizes (unaligned-safe byte decode)")
    func headerLengthFieldsDecode() throws {
        // Regression (Codex, v0.7.5 SSD review — SSDBlockStore DBK2 header
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
        if let range = meta.range(of: Data("darkbloom.kv.v2".utf8)) {
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
        #expect(a.hasPrefix("cbv2-snap-1|f16|8|"))
    }
}

// MARK: - Mode selection + no-carve

@Suite("SSD prefix cache: tier mode selection")
struct SSDPrefixCacheModeTests {

    @Test("matrix: SSD default-on; kill switches; RAM opt-in; both ⇒ SSD wins")
    func modeMatrix() {
        // Fleet default: nothing set ⇒ SSD tier, no both-tiers warn.
        #expect(PrefixCachePolicy.mode(environment: [:]) == .ssd(warnBothTiers: false))
        // RAM opt-in alone (SSD default still on) ⇒ SSD wins + WARN.
        #expect(
            PrefixCachePolicy.mode(environment: ["DARKBLOOM_PREFIX_CACHE": "1"])
                == .ssd(warnBothTiers: true))
        // RAM opt-in + SSD killed ⇒ the opt-in RAM tier (unchanged semantics).
        #expect(
            PrefixCachePolicy.mode(environment: [
                "DARKBLOOM_PREFIX_CACHE": "1", "DARKBLOOM_PREFIX_CACHE_SSD": "0",
            ]) == .ram)
        // SSD killed alone ⇒ off.
        #expect(
            PrefixCachePolicy.mode(environment: ["DARKBLOOM_PREFIX_CACHE_SSD": "0"]) == .off)
        // Master kill kills EVERYTHING, even with SSD affirmatively set.
        #expect(
            PrefixCachePolicy.mode(environment: [
                "DARKBLOOM_PREFIX_CACHE": "0", "DARKBLOOM_PREFIX_CACHE_SSD": "1",
            ]) == .off)
        // Fail-safe: a typo'd master value can only ever leave a box uncached.
        #expect(PrefixCachePolicy.mode(environment: ["DARKBLOOM_PREFIX_CACHE": "banana"]) == .off)
        // A typo'd SSD value kills the SSD tier only.
        #expect(
            PrefixCachePolicy.mode(environment: ["DARKBLOOM_PREFIX_CACHE_SSD": "banana"]) == .off)
        #expect(
            PrefixCachePolicy.mode(environment: [
                "DARKBLOOM_PREFIX_CACHE": "1", "DARKBLOOM_PREFIX_CACHE_SSD": "banana",
            ]) == .ram)
        // Explicit SSD affirmative is idempotent with the default.
        #expect(
            PrefixCachePolicy.mode(environment: ["DARKBLOOM_PREFIX_CACHE_SSD": "1"])
                == .ssd(warnBothTiers: false))
    }

    @Test("NO memory carve in SSD mode: the engine keeps the full slot grant")
    func noCarveInSSDMode() {
        // SSD mode requests a ZERO memory budget — the carve must hand the
        // engine the entire grant (the invariant the wiring enforces via
        // `requestedPrefixBudget = 0` for every non-.ram mode).
        let slot = 8 * 1_073_741_824
        let carve = PrefixCachePolicy.carve(
            slotKVBytesCapacity: slot, requestedBudgetBytes: 0, kvBytesPerToken: 24_576)
        #expect(carve.engineKVBytesCapacity == slot)
        #expect(carve.prefixCacheBudgetBytes == 0)
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
        let files = dbk2Files(under: dir)
        #expect(files.count == 8)
        // RAM discipline: nothing resident after donation.
        #expect(cache.bytesInUse == 0)

        // No raw chain hashes anywhere on disk (filenames are HMAC tags).
        let hasher = CBv2BlockHasher(blockSize: fixtureBlockSize, modelName: "test-model")
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
        #expect(dbk2Files(under: dir).count == 8)

        // A one-block extension writes ONLY the tail block.
        donateFixture(cache, tokens: Array(0 ..< (tokenCount + fixtureBlockSize)))
        #expect(await waitForIndexCount(cache, atLeast: 9))
        #expect(dbk2Files(under: dir).count == 9)
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
        #expect(staged)
        #expect(reader.bytesInUse > 0)

        // Engine-side synchronous lookup hits the staging map.
        let hit = reader.lookup(tokens: prompt, layerKinds: fixtureLayerKinds, cacheSalt: nil)
        let (matched, prefix) = try #require(hit)
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
        #expect(await !cache.stage(requestID: "r-unscoped", promptTokens: prompt, cacheScope: ""))
        #expect(await !cache.stage(requestID: "r-b", promptTokens: prompt, cacheScope: "scope-b"))
        #expect(await cache.stage(requestID: "r-a", promptTokens: prompt, cacheScope: "scope-a"))
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
        for file in dbk2Files(under: dir) {
            var bytes = try Data(contentsOf: file)
            bytes[bytes.count - 10] ^= 0xFF
            try bytes.write(to: file)
        }
        let prompt = tokens + [12345]
        let staged = await cache.stage(requestID: "r-c", promptTokens: prompt, cacheScope: "")
        #expect(!staged, "corrupt blocks must fall back to recompute, not stage")
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
        #expect(dbk2Files(under: dir).isEmpty)
        #expect(cache.stats().ttlExpired == 8)
        // Nothing left to adopt.
        let prompt = tokens + [1]
        #expect(await !cache.stage(requestID: "r-t", promptTokens: prompt, cacheScope: ""))
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
        #expect(await cache.stage(requestID: "r-hot", promptTokens: hot + [7], cacheScope: ""))
        cache.completeStaging(requestID: "r-hot")

        // 600 s more: the cold prefix (1,200 s idle) expires; the hot one
        // (600 s since its hit) survives.
        clock.advance(600)
        cache.sweepExpiredEntries()
        #expect(cache.index.count == 8)
        #expect(await cache.stage(requestID: "r-hot2", promptTokens: hot + [8], cacheScope: ""))
        cache.completeStaging(requestID: "r-hot2")
        #expect(await !cache.stage(requestID: "r-cold", promptTokens: cold + [9], cacheScope: ""))
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
        #expect(await cache.stage(requestID: "r-new", promptTokens: fresh + [1], cacheScope: ""))
        cache.completeStaging(requestID: "r-new")
        #expect(await !cache.stage(requestID: "r-old", promptTokens: old + [1], cacheScope: ""))
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
        #expect(dbk2Files(under: dir).isEmpty)
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
        #expect(dbk2Files(under: dir).isEmpty)

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
            await !cache.stage(
                requestID: "r-overflow",
                promptTokens: Array(0 ..< tokenCount) + [99],
                cacheScope: ""))
    }
}

// MARK: - Staging reservation hygiene

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
        #expect(await cache.stage(requestID: "req-ok", promptTokens: prompt, cacheScope: ""))
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
        let hasher = CBv2BlockHasher(blockSize: fixtureBlockSize, modelName: "test-model")
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

        // Expected staged bytes = the surviving 7 blocks' file sizes.
        var expectedBytes = 0
        for i in 0 ..< chain.count - 1 {
            expectedBytes += try Data(contentsOf: fileURL(i)).count
        }

        let prompt = tokens + [7]
        #expect(await cache.stage(requestID: "req-short", promptTokens: prompt, cacheScope: ""))
        #expect(cache.stats().corruptDropped == 1)
        // Regression (Codex, v0.7.5 SSD review): the reservation and the
        // staging accounting must reflect the SHORTENED run — they used to
        // stay at the original 8-block figure, falsely consuming shared KV
        // headroom until this request's release.
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
        #expect(await cache.stage(requestID: "req-b", promptTokens: prompt, cacheScope: ""))
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
            return await cache.stage(requestID: "req-x", promptTokens: prompt, cacheScope: "")
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
        #expect(!staged, "refusal under memory pressure must be a silent recompute")
        #expect(await budget.outstandingReservedBytes() == 0)
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
        #expect(await cache.stage(requestID: "req-c", promptTokens: prompt, cacheScope: ""))
        #expect(await budget.outstandingReservedBytes() > 0)
        cache.close()
        #expect(await waitForZeroOutstanding(budget))
        #expect(cache.bytesInUse == 0)
        // On-disk files SURVIVE close — durable warmth is the feature.
        #expect(!dbk2Files(under: dir).isEmpty)
    }

    @Test("two same-prefix requests share ONE entry reservation — no double-charge, no orphaned residency")
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
        // A creates the staged entry; B attaches to the SAME entry.
        #expect(await cache.stage(requestID: "req-A", promptTokens: prompt, cacheScope: ""))
        let afterA = await budget.outstandingReservedBytes()
        #expect(afterA > 0)
        #expect(await cache.stage(requestID: "req-B", promptTokens: prompt, cacheScope: ""))
        // Charged ONCE: attaching adds a residency ticket, not a reservation.
        // (Pre-fix this was 2 × afterA.)
        #expect(
            await budget.outstandingReservedBytes() == afterA,
            "attaching to a staged entry must not add a second reservation")
        #expect(cache.bytesInUse == Int(afterA))

        // Both engines look up the shared arrays (two live pins).
        let hit = try #require(
            cache.lookup(tokens: prompt, layerKinds: fixtureLayerKinds, cacheSalt: nil))
        _ = try #require(
            cache.lookup(tokens: prompt, layerKinds: fixtureLayerKinds, cacheSalt: nil))
        // A fully completes (adoption + terminal backstop) while B is STILL
        // pinned and the entry is STILL resident. Its reservation must NOT
        // be released here — residency stays covered.
        cache.endAdoption(tokens: prompt, matched: hit.matched, cacheSalt: nil)
        cache.completeStaging(requestID: "req-A")
        #expect(
            await budget.outstandingReservedBytes() == afterA,
            "a resident shared entry must stay reserved until its LAST user leaves")
        #expect(cache.bytesInUse == Int(afterA))

        // B finishes; the entry retires and the single reservation drains.
        cache.endAdoption(tokens: prompt, matched: hit.matched, cacheSalt: nil)
        cache.completeStaging(requestID: "req-B")
        #expect(await waitForZeroOutstanding(budget), "the last user must drain the entry reservation")
        #expect(cache.bytesInUse == 0)
    }
}

// MARK: - Own-root isolation (legacy upgrade sweeper safety)

@Suite("SSD prefix cache: own root survives the legacy kv sweep")
struct SSDRootIsolationTests {

    @Test("cacheDirectory lives under darkbloom/kv2, never under the legacy darkbloom/kv root")
    func rootIsOutsideLegacyTree() {
        let dir = SSDPrefixCacheFactory.cacheDirectory(modelId: "gpt-oss-20b")
        let path = dir.path
        #expect(path.contains("/darkbloom/kv2/"),
            "SSD tier must use its own root: \(path)")
        // The critical invariant: NOT inside the legacy root the upgrade
        // sweeper sheds (kv2 is a SIBLING of kv, not a subtree).
        #expect(!path.contains("/darkbloom/kv/"),
            "SSD tier must never live under the legacy kv root: \(path)")
        // Stable modelKey derivation (12-hex prefix of SHA256(modelId)).
        #expect(dir.lastPathComponent.count == 12)
    }

    @Test("the REAL legacy sweeper (LegacyKVCacheSweeper.sweep) leaves SSD entries intact and adoptable")
    func legacySweepSurvival() async throws {
        // Layout mirroring production: <caches>/darkbloom/kv (legacy) and
        // <caches>/darkbloom/kv2/<modelKey> (SSD) as SIBLINGS.
        let caches = tempDir("sweep-survival")
        defer { try? FileManager.default.removeItem(at: caches) }
        let legacyRoot = caches.appendingPathComponent("darkbloom/kv", isDirectory: true)
        let ssdDir = caches.appendingPathComponent(
            "darkbloom/kv2/aaaa11112222", isDirectory: true)
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
        // ciphertext wholesale. kv2/ (a SIBLING, not a subtree) must be
        // untouched.
        let sweptBytes = LegacyKVCacheSweeper.sweep(kvRoot: legacyRoot)
        #expect(sweptBytes > 0, "the sweeper must have removed the legacy tier's bytes")
        #expect(!fm.fileExists(atPath: legacyRoot.path), "the legacy kv/ root must be gone")

        #expect(dbk2Files(under: ssdDir).count == 8, "SSD entries must survive the legacy sweep")
        // And they remain fully adoptable: fresh cache, scan, stage.
        let reader = makeCache(dir: ssdDir, kek: kek, clock: clock)
        defer { reader.close() }
        reader.scanOnDisk()
        #expect(reader.index.count == 8)
        #expect(await reader.stage(
            requestID: "r-survive", promptTokens: tokens + [1], cacheScope: ""))
        reader.completeStaging(requestID: "r-survive")
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
        #expect(dbk2Files(under: dir).isEmpty)
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
        #expect(dbk2Files(under: dir).count == 11)
    }

    @Test("gemma constants: the >26.6k long-context tail caches; anything shorter writes nothing")
    func gemmaConstantsGate() async throws {
        let dir = tempDir("gate-gemma")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ClockBox(10_000)
        // Real gemma-4-26B numbers: bound 25 × 1,024 = 25,600; floor 26,624.
        let cache = makeCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock,
            blockSize: 256, adoptionBound: 25_600, minEffectiveTokens: 1024)
        defer { cache.close() }

        // A typical prompt (4k) AND the exact floor both write nothing —
        // the negative that used to be enforced by excluding gemma wholesale.
        donate(cache, tokenCount: 4096)
        await expectNoWrites(cache, dir: dir)
        donate(cache, tokenCount: 26_624)
        await expectNoWrites(cache, dir: dir)

        // The long-context tail (105 whole blocks = 26,880 tokens) persists.
        donate(cache, tokenCount: 26_880 + 5)
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline, cache.index.count < 105 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(cache.index.count == 105)
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
        #expect(dbk2Files(under: dir).count == 3)
        writer.close()

        // The persisted run is the LEADING prefix (contiguous from block 1):
        // a reader with an uncapped STAGE budget (the stage cap counts
        // on-disk bytes, which include DBK2 overhead) adopts exactly the
        // 3 persisted blocks.
        let reader = makeCache(
            dir: dir, kek: kek, clock: clock, minEffectiveTokens: fixtureBlockSize)
        defer { reader.close() }
        reader.scanOnDisk()
        let staged = await reader.stage(
            requestID: "r-cap", promptTokens: Array(0 ..< 64) + [1], cacheScope: "")
        #expect(staged)
        let hit = reader.lookup(
            tokens: Array(0 ..< 64) + [1], layerKinds: fixtureLayerKinds, cacheSalt: nil)
        #expect(hit?.matched == 3 * fixtureBlockSize)
        if let hit {
            reader.endAdoption(
                tokens: Array(0 ..< 64) + [1], matched: hit.matched, cacheSalt: nil)
        }
        reader.completeStaging(requestID: "r-cap")
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
                nowSeconds: { 10_000 }),
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
