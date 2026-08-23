// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

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
    maxStageBytes: Int = 1 << 30,
    maxWriteBytesPerDay: Int = 0
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
        maxWriteBytesPerDay: maxWriteBytesPerDay, strictFsync: false,
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

/// The SAME payloads in the shape `EngineLoopV2.enqueueDonation` hands to
/// `CBv2SlidingWindowDonating`: `CBv2SequenceKV.snapshot()` triples, whose
/// `offset` is the position of the NEXT token, untruncated, and nil at every
/// layer the engine does not donate (full-attention and KV-shared sliding).
private func engineSlidingSnapshots(base: Int, tokens: Int = sidecarWindow)
    -> [(keys: MLXArray, values: MLXArray, offset: Int)?]
{
    sidecarWindows(base: base, tokens: tokens).map { window in
        window.map { (keys: $0.keys, values: $0.values, offset: $0.base + $0.keys.dim(2)) }
    }
}

/// The PLAINTEXT metadata JSON of a DBK3 file, sliced straight out of the
/// bytes on disk — the region `assembleHeader` writes unencrypted so startup
/// can index without the KEK. Layout: magic(4) ‖ version(2) ‖ flags(2) ‖
/// fileIV(12) ‖ u32le wrappedDEKLen ‖ wrappedDEK ‖ u32le metadataLen ‖ metadata.
private func dbk3PlaintextMetadataJSON(_ bytes: Data) -> Data? {
    func uint32LE(at offset: Int) -> Int? {
        guard offset >= 0, bytes.count >= offset + 4 else { return nil }
        var value = 0
        for i in (0 ..< 4).reversed() { value = value << 8 | Int(bytes[bytes.startIndex + offset + i]) }
        return value
    }
    guard bytes.count > 24, Array(bytes.prefix(4)) == SSDBlockStore.magic,
        let dekLength = uint32LE(at: 20)
    else { return nil }
    let metadataLengthOffset = 24 + dekLength
    guard let metadataLength = uint32LE(at: metadataLengthOffset) else { return nil }
    let start = metadataLengthOffset + 4
    guard metadataLength > 0, bytes.count >= start + metadataLength else { return nil }
    return bytes.subdata(in: (bytes.startIndex + start) ..< (bytes.startIndex + start + metadataLength))
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
        // …and a sidecar's carries the discriminator and a keyed COMMITMENT
        // to its position — never the position itself.
        let keys = SSDLookupKeys(kek: SymmetricKey(size: .bits256))
        let windowTag = keys.windowTag(
            chainHash: Data(SHA256.hash(data: Data("prefix".utf8))), cacheSalt: "")
        let sidecar = SSDBlockMetadata(
            lookupTag: String(repeating: "ab", count: 32),
            weightHash: "w", layoutEpoch: "e", blockSize: 8, layerCount: 2,
            chunks: [], chunkPlaintextSizes: [], createdAt: 1000,
            windowKind: SSDWindowSidecar.kind,
            windowBaseTag: keys.windowBaseCommitmentHex(windowTag: windowTag, base: 48),
            windowTokens: 8)
        let sidecarJSON = try #require(String(
            data: try SSDBlockStore.canonicalEncode(sidecar), encoding: .utf8))
        #expect(sidecarJSON.contains("\"windowKind\":\"sliding-window-v1\""))
        #expect(
            !sidecarJSON.contains("\"windowBase\":"),
            "the raw absolute-position key must not exist in the AAD JSON")
        #expect(
            sidecarJSON.contains(
                "\"windowBaseTag\":\"\(keys.windowBaseCommitmentHex(windowTag: windowTag, base: 48))\""))
        // The commitment is position-binding: a different base, same file.
        #expect(
            keys.windowBaseCommitmentHex(windowTag: windowTag, base: 48)
                != keys.windowBaseCommitmentHex(windowTag: windowTag, base: 56))
        // …and install-binding: another box's K_lookup commits differently.
        let otherKeys = SSDLookupKeys(kek: SymmetricKey(size: .bits256))
        #expect(
            otherKeys.windowBaseCommitmentHex(windowTag: windowTag, base: 48)
                != keys.windowBaseCommitmentHex(windowTag: windowTag, base: 48))
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

    // MARK: The production donation path

    @Test("the request-aware production donation captures windows (the feature is not inert)")
    func requestAwareDonationCapturesWindows() async throws {
        let dir = tempDir("sidecar-request-aware")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = makeSidecarCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: ClockBox(10_000))
        defer { cache.close() }
        let tokens = Array(0 ..< tokenCount)

        // The engine reads this BEFORE it snapshots anything, so a false here
        // means production never even builds the (200 MiB on gemma-4) window.
        #expect(cache.wantsSlidingWindowDonation)
        // Reached through the EXISTENTIAL the engine actually casts to
        // (`EngineLoopV2.enqueueDonation`): losing the conformance, or losing
        // the dispatch, makes production silently stop writing sidecars.
        let donor: any CBv2SlidingWindowDonating = cache
        donor.donate(
            requestID: CBv2RequestID(41),
            tokens: tokens,
            snapshots: sidecarSnapshots(tokenCount: tokenCount),
            slidingSnapshots: engineSlidingSnapshots(base: 48),
            layerKinds: sidecarLayerKinds,
            cacheSalt: nil)
        #expect(await waitForIndexCount(cache, atLeast: 10))
        await cache.waitForWritesForTesting()
        #expect(
            cache.stats().windowSidecarsWritten == 2,
            "the production donation overload must persist the terminal tiling")

        // …and the window it wrote is the donor's, byte-exactly.
        let staged = await cache.stage(
            requestID: "req-production", promptTokens: tokens + [7], cacheScope: "")
        #expect(staged.staged)
        let restored = try #require(cache.stagedWindow(requestID: "req-production"))
        let donated = try #require(sidecarWindows(base: 48)[1])
        let entry = try #require(restored[1])
        #expect(entry.base == 48)
        #expect(maxAbs(entry.keys, donated.keys) == 0)
    }

    @Test("the frozen request-aware overload carries no windows — the defect this replaced")
    func frozenRequestAwareOverloadIsWindowless() async throws {
        let dir = tempDir("sidecar-frozen-overload")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = makeSidecarCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: ClockBox(10_000))
        defer { cache.close() }
        let tokens = Array(0 ..< tokenCount)
        // `CBv2PrefixCache`'s snapshots array is nil at every windowed layer by
        // contract, so this overload can only ever write blocks. It is pinned
        // here so nobody "fixes" the inertness by smuggling sliding rows into
        // a contract that four other conformers read as full-attention only.
        cache.donate(
            requestID: CBv2RequestID(42),
            tokens: tokens,
            snapshots: sidecarSnapshots(tokenCount: tokenCount),
            layerKinds: sidecarLayerKinds,
            cacheSalt: nil)
        #expect(await waitForIndexCount(cache, atLeast: 8))
        await cache.waitForWritesForTesting()
        #expect(cache.index.count == 8)
        #expect(cache.stats().windowSidecarsWritten == 0)
    }

    @Test("a cache without sidecars tells the engine not to snapshot sliding rows")
    func donorSeamIsSilentWhenDisabled() {
        let dir = tempDir("sidecar-no-donor")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = makeSidecarCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: ClockBox(10_000),
            geometry: nil)
        defer { cache.close() }
        #expect(
            !cache.wantsSlidingWindowDonation,
            "the default build must not pay for a window nobody persists")
    }

    // MARK: Replay bound

    @Test("a restored window does not shorten the replay bound it advertises")
    func aRestoredWindowDoesNotShortenTheBound() async throws {
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let tokens = Array(0 ..< tokenCount)

        /// `donorBase` 48 tiles the terminal window ([48,64) ⇒ blocks 6+7);
        /// 45 covers block 6 only, so boundary 64 can never be restored.
        func savedTokens(donorBase: Int) async throws -> Int {
            let dir = tempDir("sidecar-bound-\(donorBase)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let cache = makeSidecarCache(
                dir: dir, kek: kek, clock: clock, adoptionBound: 24)
            defer { cache.close() }
            cache.donate(
                requestID: nil, tokens: tokens,
                snapshots: sidecarSnapshots(tokenCount: tokenCount),
                windowSnapshots: sidecarWindows(base: donorBase),
                layerKinds: sidecarLayerKinds, cacheSalt: nil)
            #expect(await waitForIndexCount(cache, atLeast: donorBase == 48 ? 10 : 9))
            await cache.waitForWritesForTesting()
            let staged = await cache.stage(
                requestID: "req-bound-\(donorBase)", promptTokens: tokens + [7], cacheScope: "")
            guard case .staged(let matched, let saved, _) = staged.disposition else {
                Issue.record("expected a staged run, got \(staged.disposition)")
                return -1
            }
            #expect(matched == tokenCount, "the block run adopts either way")
            // The window IS restored for the complete tiling and not for the
            // incomplete one — the read path still does its job.
            #expect((cache.stagedWindow(requestID: "req-bound-\(donorBase)") != nil)
                == (donorBase == 48))
            return saved
        }

        // BOTH are charged the conservative 24. WS-4.2 once let the complete
        // tiling advertise a zero replay and report all 64 tokens saved; no row
        // in this repo can install a restored window, so that number was a lie
        // the adopter then paid for in full. A restored window is a persisted
        // ARTEFACT, not yet a shorter replay, and this pins the difference.
        #expect(try await savedTokens(donorBase: 48) == tokenCount - 24)
        #expect(try await savedTokens(donorBase: 45) == tokenCount - 24)
    }

    // MARK: Endurance

    @Test("a nearly-drained write bucket funds the required blocks, never the sidecars")
    func sidecarsNeverStarveTheBlocks() async throws {
        let dir = tempDir("sidecar-endurance")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = Array(0 ..< tokenCount)
        // Fixture bytes: a full-attention block is 512 B (one layer × K/V ×
        // 256 B); a sidecar is 1024 B (two sliding layers). The whole job
        // wants 8 × 512 + 2 × 1024 = 6,144 B. Allow 4,608 — every block plus
        // one block's slack, and less than one sidecar beyond them.
        let cache = makeSidecarCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: ClockBox(10_000),
            maxWriteBytesPerDay: 8 * 512 + 512)
        defer { cache.close() }
        cache.donate(
            requestID: nil, tokens: tokens,
            snapshots: sidecarSnapshots(tokenCount: tokenCount),
            windowSnapshots: sidecarWindows(base: 48),
            layerKinds: sidecarLayerKinds, cacheSalt: nil)
        #expect(await waitForIndexCount(cache, atLeast: 8))
        await cache.waitForWritesForTesting()

        // `SSDWriteBehind.consume` charges the bucket per entry IN ARRAY
        // ORDER, so whoever is queued first spends the allowance. The prefix
        // blocks are the thing the sidecars can only accelerate, so they win:
        // all 8 land. Queued the other way round, two sidecars would have
        // taken 2,048 B and starved three of them.
        #expect(cache.stats().blocksWritten == 8, "every required block is funded")
        #expect(
            cache.stats().windowSidecarsWritten == 0,
            "the optional accelerator yields to the blocks it depends on")
        // …and the refused sidecars were never EXTRACTED: the pre-check runs
        // before the device slice / eval / host copy, so nothing was
        // materialized only to be dropped, and no tag is stranded in flight.
        #expect(cache.stats().donationsDropped == 0)
        #expect(dbk3Files(under: dir).count == 8)

        // The block run still adopts; only the window is missing.
        let staged = await cache.stage(
            requestID: "req-endurance", promptTokens: tokens + [7], cacheScope: "")
        #expect(staged.staged)
        #expect(cache.stagedWindow(requestID: "req-endurance") == nil)
    }

    @Test("re-donating a covered boundary refreshes its sidecars, not just its blocks")
    func donationRefreshesReusedSidecars() async throws {
        let dir = tempDir("sidecar-refresh")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ClockBox(10_000)
        let cache = makeSidecarCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock)
        defer { cache.close() }
        let tokens = Array(0 ..< tokenCount)
        let snapshots = sidecarSnapshots(tokenCount: tokenCount)

        cache.donate(
            requestID: nil, tokens: tokens, snapshots: snapshots,
            windowSnapshots: sidecarWindows(base: 48),
            layerKinds: sidecarLayerKinds, cacheSalt: nil)
        #expect(await waitForIndexCount(cache, atLeast: 10))
        await cache.waitForWritesForTesting()

        // 800 s later the same conversation donates the same prefix again.
        // Every block AND every sidecar is already durable, so nothing is
        // written — but the donation is proof of activity and must slide the
        // TTL of both. The blocks were always refreshed here; the sidecars
        // were not, so they aged out from under a still-warm run.
        clock.advance(800)
        cache.donate(
            requestID: nil, tokens: tokens, snapshots: snapshots,
            windowSnapshots: sidecarWindows(base: 48),
            layerKinds: sidecarLayerKinds, cacheSalt: nil)
        await cache.waitForWritesForTesting()
        #expect(cache.stats().windowSidecarsWritten == 2, "nothing re-written")

        // 200 s more: 1,000 s since the first donation (past the 900 s TTL),
        // 200 s since the refresh. Everything must survive.
        clock.advance(200)
        cache.sweepExpiredEntries()
        #expect(
            cache.index.count == 10,
            "an unrefreshed sidecar expires under a warm block run and re-arms the replay")
        let staged = await cache.stage(
            requestID: "req-refresh", promptTokens: tokens + [7], cacheScope: "")
        #expect(staged.staged)
        #expect(cache.stagedWindow(requestID: "req-refresh") != nil)
    }

    // MARK: On-disk privacy (TB-003)

    @Test("a written sidecar's plaintext header carries no absolute token position")
    func sidecarHeaderHidesPosition() async throws {
        let dir = tempDir("sidecar-privacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let tokens = Array(0 ..< tokenCount)
        let cache = makeSidecarCache(dir: dir, kek: kek, clock: ClockBox(10_000))
        cache.donate(
            requestID: nil, tokens: tokens,
            snapshots: sidecarSnapshots(tokenCount: tokenCount),
            windowSnapshots: sidecarWindows(base: 48),
            layerKinds: sidecarLayerKinds, cacheSalt: nil)
        #expect(await waitForIndexCount(cache, atLeast: 10))
        await cache.waitForWritesForTesting()
        cache.close()

        // The two sidecars written cover blocks 6 and 7 — absolute bases 48
        // and 56. Read the REAL BYTES back and prove neither appears.
        let keys = SSDLookupKeys(kek: kek)
        let hasher = CBv2BlockHasher(
            blockSize: sidecarBlockSize, promptContractID: "sidecar-prompt-contract", scopeID: "")
        let hashes = hasher.chainHashes(tokens: tokens)
        var checked = 0
        for (block, base) in [(6, 48), (7, 56)] {
            let fullTag = keys.windowTag(chainHash: hashes[block], cacheSalt: "")
            let url = SSDBlockStore.fileURL(
                root: dir,
                tag16Hex: SSDLookupKeys.hex(fullTag.prefix(SSDLookupKeys.truncatedTagLength)))
            let bytes = try Data(contentsOf: url)
            let metadataBytes = try #require(dbk3PlaintextMetadataJSON(bytes))
            let json = try #require(String(data: metadataBytes, encoding: .utf8))

            // 1. No raw position key, and no decimal position anywhere in the
            //    plaintext header once the opaque commitment is removed.
            #expect(!json.contains("\"windowBase\":"))
            let commitment = keys.windowBaseCommitmentHex(windowTag: fullTag, base: base)
            // Opaque by construction: a full-width SHA-256 MAC in lowercase
            // hex, so the field itself cannot BE the position in disguise.
            #expect(SSDBlockStore.isLowerHex(commitment, count: 64))
            #expect(json.contains(commitment), "the commitment is what binds the position")
            let withoutCommitment = json.replacingOccurrences(of: commitment, with: "")
            for position in [48, 56, tokenCount] {
                #expect(
                    !withoutCommitment.contains(":\(position)")
                        && !withoutCommitment.contains(",\(position)"),
                    "absolute position \(position) leaked into the plaintext header")
            }
            // 2. The accepted plaintext discriminator, kept deliberately: it
            //    says only "sliding-window sidecar", which the chunk
            //    descriptors (sliding layer indices + shapes, already public
            //    architecture) reveal regardless.
            #expect(json.contains("\"windowKind\":\"sliding-window-v1\""))
            // 3. The commitment still BINDS: the same file cannot pass the
            //    anti-splice check at the neighbouring boundary.
            let metadata = try SSDBlockStore.readMetadataOnly(from: url)
            #expect(SSDWindowSidecar.isBound(
                metadata, expectedBaseTag: commitment, geometry: sidecarGeometry()))
            #expect(!SSDWindowSidecar.isBound(
                metadata,
                expectedBaseTag: keys.windowBaseCommitmentHex(
                    windowTag: fullTag, base: base + sidecarBlockSize),
                geometry: sidecarGeometry()))
            checked += 1
        }
        #expect(checked == 2)
    }

    @Test("the contiguous windowed ring conforms to the donor seam WS-4.1 freezes")
    func contiguousDonorSeam() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let row = CBv2WindowedSequenceKV(
            window: sidecarWindow, kvHeads: fixtureKVHeads, headDim: fixtureHeadDim)
        #expect(row.windowSnapshot() == nil, "empty row")
        let shape = [1, fixtureKVHeads, 24, fixtureHeadDim]
        let chunk = MLXArray(0 ..< shape.reduce(1, *)).reshaped(shape).asType(.float16)
        eval(chunk)
        _ = row.update(keys: chunk, values: chunk)
        let snapshot = try! #require(row.windowSnapshot())
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

        // "read-terminal-four": one adoption reads `blocksPerWindow` sidecars
        // = 200 MiB, which the conservative 1.5 GB/s planner costs at 140 ms
        // against the 1,000 ms stage budget, and which fits the 1 GiB
        // per-adoption cap with room for 164 blocks (41,984 tokens) of prefix.
        let windowReadBytes = sidecarBytes * geometry.blocksPerWindow
        #expect(windowReadBytes == 209_715_200)
        #expect(SSDPrefixCachePolicy.estimatedStageMillis(bytes: windowReadBytes) == 140)
        #expect(SSDPrefixCachePolicy.estimatedStageMillis(bytes: windowReadBytes)
            < SSDPrefixCachePolicy.defaultMaxStageMillis)
        let blocksLeft =
            (SSDPrefixCachePolicy.defaultMaxStageBytes - windowReadBytes) / fullBlockBytes
        #expect(blocksLeft == 164)
    }

    @Test("staging restores a window only when sidecar artifacts are present")
    func stageArtifactBehavior() async throws {
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let tokens = Array(0 ..< tokenCount)

        func stage(withSidecar: Bool) async throws {
            let dir = tempDir("sidecar-stage-\(withSidecar)")
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
                requestID: "req-stage", promptTokens: tokens + [7], cacheScope: "")
            #expect(staged.staged)
            #expect(staged.stagedTokens == tokenCount)
            #expect((cache.stagedWindow(requestID: "req-stage") != nil) == withSidecar)
        }

        try await stage(withSidecar: false)
        try await stage(withSidecar: true)
    }
}
