// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("SSD prefix cache: DBK3 block store")
struct SSDBlockStoreTests {


    @Test("round-trip: metadata + chunks survive encrypt/decrypt byte-exactly")
    func roundTrip() throws {
        let dir = tempDir("store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let chunks = [Data((0 ..< 256).map { UInt8($0 % 251) }), Data(repeating: 7, count: 256)]
        let metadata = blockMetadataFixture(sizes: chunks.map(\.count))
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
            let metadata = blockMetadataFixture(sizes: sizes)
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
        let metadata = blockMetadataFixture(sizes: [512])
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

}
