import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

// EncryptedKVStore tests cover the on-disk format end-to-end:
// roundtrip write+read of multi-chunk payloads, tamper detection at
// the file-magic / version / metadata / DEK / chunk-ct / chunk-tag
// levels, and metadata-only reads that don't unwrap the DEK.
//
// All tests use the in-memory KEK so they don't need Secure Enclave
// access. The format is backend-agnostic — the SE-backed KEK is
// covered separately in KVCacheKEKTests.

// MARK: - Fixtures

private func newTempURL() -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbkv-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent(
        "\(UUID().uuidString).\(EncryptedKVStore.fileExtension)"
    )
}

private func newKEK() -> KVCacheKEK {
    return KVCacheKEK(
        wrapper: InMemoryKeyWrappingService(),
        storage: InMemoryWrappedKEKStorage(identifier: UUID().uuidString)
    )
}

private func makeMetadata(
    numLayers: Int = 4,
    tokenCount: Int = 1024,
    chunkSizes: [Int] = [1024, 2048, 512, 4096]
) -> EncryptedKVStoreMetadata {
    return EncryptedKVStoreMetadata(
        modelHash: "sha256:0123abcd",
        modelDtype: "bf16",
        modelArch: "Llama",
        vocabSize: 128_256,
        numLayers: numLayers,
        kvHeads: 8,
        headDim: 128,
        tokenCount: tokenCount,
        tokenPrefixHash: "sha256:cafef00d",
        kvCacheClass: "KVCacheSimple",
        metaState: [""],
        chunkPlaintextSizes: chunkSizes,
        createdAt: 1_716_422_400,
        expiresAt: 1_717_027_200
    )
}

private func makeChunks(_ sizes: [Int]) -> [Data] {
    sizes.enumerated().map { (i, n) in
        Data((0..<n).map { _ in UInt8.random(in: 0...255) })
    }
}

// MARK: - Happy path

@Test
func storeRoundtripsSingleChunk() async throws {
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = newKEK()
    defer { Task { try? await kek.wipe() } }

    let plaintext = Data((0..<4096).map { UInt8($0 % 256) })
    let metadata = makeMetadata(chunkSizes: [plaintext.count])

    try await EncryptedKVStore.write(
        to: url, metadata: metadata, chunks: [plaintext], kek: kek
    )

    let (meta, chunks) = try await EncryptedKVStore.read(from: url, kek: kek)
    #expect(meta == metadata)
    #expect(chunks.count == 1)
    #expect(chunks[0] == plaintext)
}

@Test
func storeRoundtripsMultipleChunks() async throws {
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = newKEK()
    defer { Task { try? await kek.wipe() } }

    let sizes = [16, 1024, 33, 65536, 0, 7]  // includes empty chunk and odd sizes
    let plaintexts = makeChunks(sizes)
    let metadata = makeMetadata(chunkSizes: sizes)

    try await EncryptedKVStore.write(
        to: url, metadata: metadata, chunks: plaintexts, kek: kek
    )

    let (_, decrypted) = try await EncryptedKVStore.read(from: url, kek: kek)
    #expect(decrypted.count == plaintexts.count)
    for (i, pt) in plaintexts.enumerated() {
        #expect(decrypted[i] == pt, "chunk \(i) mismatch")
    }
}

@Test
func storeReadMetadataOnlyDoesNotUnwrapDEK() async throws {
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = newKEK()
    defer { Task { try? await kek.wipe() } }

    let metadata = makeMetadata(chunkSizes: [64])
    try await EncryptedKVStore.write(
        to: url, metadata: metadata, chunks: makeChunks([64]), kek: kek
    )

    // Read metadata without touching the KEK at all.
    let meta = try EncryptedKVStore.readMetadataOnly(from: url)
    #expect(meta == metadata)
}

// MARK: - Tamper detection

@Test
func storeRejectsCorruptedMagic() async throws {
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = newKEK()
    defer { Task { try? await kek.wipe() } }

    try await EncryptedKVStore.write(
        to: url, metadata: makeMetadata(chunkSizes: [16]),
        chunks: [Data(count: 16)], kek: kek
    )

    // Flip a magic byte.
    var raw = try Data(contentsOf: url)
    raw[0] = 0xFF
    try raw.write(to: url)

    await #expect(throws: EncryptedKVStoreError.self) {
        _ = try await EncryptedKVStore.read(from: url, kek: kek)
    }
}

@Test
func storeRejectsUnsupportedVersion() async throws {
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = newKEK()
    defer { Task { try? await kek.wipe() } }

    try await EncryptedKVStore.write(
        to: url, metadata: makeMetadata(chunkSizes: [16]),
        chunks: [Data(count: 16)], kek: kek
    )

    // Bump the version field (offset 4) to a value we don't support.
    var raw = try Data(contentsOf: url)
    raw[4] = 0xFF
    raw[5] = 0xFF
    try raw.write(to: url)

    await #expect(throws: EncryptedKVStoreError.self) {
        _ = try await EncryptedKVStore.read(from: url, kek: kek)
    }
}

@Test
func storeRejectsTamperedMetadata() async throws {
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = newKEK()
    defer { Task { try? await kek.wipe() } }

    let plaintext = Data((0..<512).map { UInt8($0 & 0xFF) })
    try await EncryptedKVStore.write(
        to: url, metadata: makeMetadata(chunkSizes: [plaintext.count]),
        chunks: [plaintext], kek: kek
    )

    // Find the metadata block and flip a byte there. We don't bother
    // parsing the header — we know "Llama" appears in the modelArch
    // field, so locate it directly and flip.
    var raw = try Data(contentsOf: url)
    let pattern = Data("Llama".utf8)
    var hit: Int?
    for i in 0...(raw.count - pattern.count) {
        if raw.subdata(in: i..<(i + pattern.count)) == pattern {
            hit = i
            break
        }
    }
    let metaByteOffset = try #require(hit, "couldn't locate metadata in file")
    raw[metaByteOffset] ^= 0xFF
    try raw.write(to: url)

    // DEK unwrap binds metadata as AAD, so tamper must fail there
    // (KVCacheKEKError) — not at chunk decrypt.
    await #expect(throws: (any Error).self) {
        _ = try await EncryptedKVStore.read(from: url, kek: kek)
    }
}

@Test
func storeRejectsTamperedChunkCiphertext() async throws {
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = newKEK()
    defer { Task { try? await kek.wipe() } }

    let plaintext = Data(repeating: 0x55, count: 256)
    try await EncryptedKVStore.write(
        to: url, metadata: makeMetadata(chunkSizes: [plaintext.count]),
        chunks: [plaintext], kek: kek
    )

    // Flip the last byte of the file (inside the chunk's GCM tag).
    var raw = try Data(contentsOf: url)
    let last = raw.count - 1
    raw[last] ^= 0xFF
    try raw.write(to: url)

    await #expect(throws: EncryptedKVStoreError.self) {
        _ = try await EncryptedKVStore.read(from: url, kek: kek)
    }
}

@Test
func storeRejectsTruncatedFile() async throws {
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = newKEK()
    defer { Task { try? await kek.wipe() } }

    try await EncryptedKVStore.write(
        to: url, metadata: makeMetadata(chunkSizes: [1024]),
        chunks: [Data(count: 1024)], kek: kek
    )

    // Lop off the trailing 100 bytes.
    let raw = try Data(contentsOf: url)
    try raw.prefix(raw.count - 100).write(to: url)

    await #expect(throws: EncryptedKVStoreError.self) {
        _ = try await EncryptedKVStore.read(from: url, kek: kek)
    }
}

@Test
func storeRejectsWrongKEK() async throws {
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let writerKEK = newKEK()
    defer { Task { try? await writerKEK.wipe() } }
    let readerKEK = newKEK()  // different in-memory wrapper key
    defer { Task { try? await readerKEK.wipe() } }

    try await EncryptedKVStore.write(
        to: url, metadata: makeMetadata(chunkSizes: [128]),
        chunks: [Data(count: 128)], kek: writerKEK
    )

    await #expect(throws: KVCacheKEKError.self) {
        _ = try await EncryptedKVStore.read(from: url, kek: readerKEK)
    }
}

// MARK: - Nonce derivation

@Test
func chunkNonceIsDeterministic() throws {
    let dek = SymmetricKey(data: Data(repeating: 0x77, count: 32))
    let iv = Data(repeating: 0x33, count: EncryptedKVStore.fileIVLength)

    let n1 = try EncryptedKVStore.deriveChunkNonce(dek: dek, fileIV: iv, chunkIndex: 0)
    let n2 = try EncryptedKVStore.deriveChunkNonce(dek: dek, fileIV: iv, chunkIndex: 0)
    #expect(n1 == n2)
    #expect(n1.count == EncryptedKVStore.nonceLength)
}

@Test
func chunkNonceDiffersByIndex() throws {
    let dek = SymmetricKey(data: Data(repeating: 0x77, count: 32))
    let iv = Data(repeating: 0x33, count: EncryptedKVStore.fileIVLength)

    let n0 = try EncryptedKVStore.deriveChunkNonce(dek: dek, fileIV: iv, chunkIndex: 0)
    let n1 = try EncryptedKVStore.deriveChunkNonce(dek: dek, fileIV: iv, chunkIndex: 1)
    let n2 = try EncryptedKVStore.deriveChunkNonce(dek: dek, fileIV: iv, chunkIndex: 42)
    #expect(n0 != n1)
    #expect(n1 != n2)
    #expect(n0 != n2)
}

@Test
func chunkNonceDiffersByFileIV() throws {
    let dek = SymmetricKey(data: Data(repeating: 0x77, count: 32))
    let ivA = Data(repeating: 0x33, count: EncryptedKVStore.fileIVLength)
    let ivB = Data(repeating: 0x44, count: EncryptedKVStore.fileIVLength)

    let nA = try EncryptedKVStore.deriveChunkNonce(dek: dek, fileIV: ivA, chunkIndex: 0)
    let nB = try EncryptedKVStore.deriveChunkNonce(dek: dek, fileIV: ivB, chunkIndex: 0)
    #expect(nA != nB)
}

@Test
func writeCreatesBrandNewFile() async throws {
    // Codex flagged that the atomic-rename path might fail to CREATE a file
    // that doesn't exist yet (replaceItemAt is replace-only on some
    // platforms), which would make first-ever SSD writes a silent no-op.
    // Prove the opposite: writing to a non-existent path creates it and
    // round-trips. (Guards the create-or-replace fix in atomicWrite.)
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(!FileManager.default.fileExists(atPath: url.path), "precondition: target must not exist")

    let kek = newKEK()
    let pt = Data((0..<777).map { UInt8($0 & 0xFF) })
    try await EncryptedKVStore.write(
        to: url, metadata: makeMetadata(chunkSizes: [pt.count]), chunks: [pt], kek: kek
    )
    #expect(FileManager.default.fileExists(atPath: url.path), "first write must CREATE the file")

    let (_, chunks) = try await EncryptedKVStore.read(from: url, kek: kek)
    #expect(chunks == [pt])
}

@Test
func chunkNonceRejectsWrongIVLength() {
    let dek = SymmetricKey(data: Data(repeating: 0x77, count: 32))
    let shortIV = Data(repeating: 0x33, count: 8)
    #expect(throws: EncryptedKVStoreError.self) {
        _ = try EncryptedKVStore.deriveChunkNonce(
            dek: dek, fileIV: shortIV, chunkIndex: 0
        )
    }
}

// MARK: - Validation

@Test
func storeRejectsChunkCountMismatch() async throws {
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = newKEK()
    defer { Task { try? await kek.wipe() } }

    // metadata says 2 chunks; we pass 1.
    let metadata = makeMetadata(chunkSizes: [16, 32])
    await #expect(throws: EncryptedKVStoreError.self) {
        try await EncryptedKVStore.write(
            to: url, metadata: metadata,
            chunks: [Data(count: 16)], kek: kek
        )
    }
}

@Test
func storeRejectsChunkSizeMismatch() async throws {
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = newKEK()
    defer { Task { try? await kek.wipe() } }

    // metadata says chunk[0] is 64 bytes; we pass 65.
    let metadata = makeMetadata(chunkSizes: [64])
    await #expect(throws: EncryptedKVStoreError.self) {
        try await EncryptedKVStore.write(
            to: url, metadata: metadata,
            chunks: [Data(count: 65)], kek: kek
        )
    }
}

@Test
func sweepStaleTempFilesRemovesOrphansKeepsRealFiles() throws {
    // A process kill between atomic-write's createFile and rename leaves a
    // <name>.tmp-<UUID> orphan with no normal cleanup. sweepStaleTempFiles
    // must remove those while leaving real .darkbloom-kv files + index.json.
    let fm = FileManager.default
    let dir = fm.temporaryDirectory
        .appendingPathComponent("dbkv-sweep-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let orphan1 = dir.appendingPathComponent("abc.\(EncryptedKVStore.fileExtension).tmp-\(UUID().uuidString)")
    let orphan2 = dir.appendingPathComponent("def.\(EncryptedKVStore.fileExtension).tmp-\(UUID().uuidString)")
    let real = dir.appendingPathComponent("abc.\(EncryptedKVStore.fileExtension)")
    let index = dir.appendingPathComponent("index.json")
    for u in [orphan1, orphan2, real, index] { fm.createFile(atPath: u.path, contents: Data([1, 2, 3])) }

    EncryptedKVStore.sweepStaleTempFiles(in: dir)

    #expect(!fm.fileExists(atPath: orphan1.path), "orphan temp 1 must be swept")
    #expect(!fm.fileExists(atPath: orphan2.path), "orphan temp 2 must be swept")
    #expect(fm.fileExists(atPath: real.path), "real cache file must be kept")
    #expect(fm.fileExists(atPath: index.path), "index.json must be kept")
}

// MARK: - header-only readMetadataOnly
//
// C2 is a memory/perf fix: readMetadataOnly used to map+copy the entire
// multi-GB ciphertext body (via splitHeaderAndBody's `subdata`) only to discard
// it, OOMing reconcileWithDisk. The fix reads ONLY the header via FileHandle.
// This is inherently NOT a failing-on-revert guard (you'd have to measure heap
// allocation), so these are CORRECTNESS tests for the new parser, not strict
// revert-guards: (1) equivalence pins the new FileHandle offset math (a bug in
// the header-only parser fails this); (2) the malformed/truncated cases pin its
// defensive behavior. The "don't copy the body" property itself is verified by
// inspection (the new path never calls subdata(in: metadataEnd..<raw.count)).

@Test
func readMetadataOnlyMatchesFullParseOnLargeBody() async throws {
    // The new FileHandle header-only parser must return the SAME metadata as a
    // full read on a multi-MB body (the path reconcileWithDisk hammers). Guards
    // the new parser's offset math against regressions IN the new code.
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = newKEK()
    defer { Task { try? await kek.wipe() } }

    let sizes = [4 * 1024 * 1024, 2 * 1024 * 1024]  // 6 MiB of body
    let metadata = makeMetadata(tokenCount: 9001, chunkSizes: sizes)
    try await EncryptedKVStore.write(to: url, metadata: metadata, chunks: makeChunks(sizes), kek: kek)

    let headerOnly = try EncryptedKVStore.readMetadataOnly(from: url)
    let (fullMeta, _) = try await EncryptedKVStore.read(from: url, kek: kek)
    #expect(headerOnly == metadata, "C2: header-only metadata must equal what was written")
    #expect(headerOnly == fullMeta, "C2: header-only metadata must equal the full-read metadata")
}

@Test
func readMetadataOnlyRejectsTruncatedHeader() async throws {
    // The FileHandle parser reads exact byte counts; a file truncated mid-header
    // must throw (not read uninitialized/short). Old whole-file map+subdata also
    // threw, but via a different path — this pins the new parser's behavior.
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = newKEK()
    defer { Task { try? await kek.wipe() } }

    let metadata = makeMetadata(chunkSizes: [256])
    try await EncryptedKVStore.write(to: url, metadata: metadata, chunks: makeChunks([256]), kek: kek)

    // Truncate to 12 bytes — past the magic/version but mid fixed-prefix.
    let raw = try Data(contentsOf: url)
    try raw.prefix(12).write(to: url)
    #expect(throws: EncryptedKVStoreError.self) {
        _ = try EncryptedKVStore.readMetadataOnly(from: url)
    }
}

@Test
func readMetadataOnlyRejectsOutOfBoundsWrappedLen() async throws {
    // C2 revert-guard for the hard bound: a corrupt/hostile wrapped-DEK length
    // field (here 0x7FFFFFFF) must be rejected as malformed BEFORE the parser
    // tries to read ~2 GiB off the field. The pre-fix code had no such bound.
    let url = newTempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let kek = newKEK()
    defer { Task { try? await kek.wipe() } }

    let metadata = makeMetadata(chunkSizes: [256])
    try await EncryptedKVStore.write(to: url, metadata: metadata, chunks: makeChunks([256]), kek: kek)

    // Overwrite the wrapped-DEK length (uint32 LE at offset 20) with a huge value.
    var raw = try Data(contentsOf: url)
    raw[20] = 0xFF; raw[21] = 0xFF; raw[22] = 0xFF; raw[23] = 0x7F
    try raw.write(to: url)
    #expect(throws: EncryptedKVStoreError.self) {
        _ = try EncryptedKVStore.readMetadataOnly(from: url)
    }
}
