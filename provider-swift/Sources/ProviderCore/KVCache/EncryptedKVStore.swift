/// EncryptedKVStore — on-disk format for darkbloom's encrypted KV
/// cache (`*.darkbloom-kv`).
///
/// One file per cached prefix. Inside the file:
///
/// ```
/// 0       4       magic = "DBKV"
/// 4       2       uint16 LE  format_version (= 1)
/// 6       2       uint16 LE  flags (reserved, must be 0)
/// 8      12       file_IV       random per-file; folded into HKDF info (not a salt)
/// 20      4       uint32 LE  wrapped_DEK length (N)
/// 24      N       wrapped_DEK   AES-256-GCM(KEK, DEK, AAD=metadata)
///                               = nonce(12) ‖ ct(32) ‖ tag(16)
/// 24+N    4       uint32 LE  metadata length (M)
/// 28+N    M       metadata      JSON; verbatim AAD on chunk seal
/// 28+N+M  4       uint32 LE  chunk_count
/// then for each chunk i ∈ [0, chunk_count):
///         4       uint32 LE  ciphertext length (= plaintext + 16 tag)
///         var     AES-256-GCM ct ‖ tag       (nonce HKDF-derived)
/// ```
///
/// Per-chunk nonces are HKDF-derived rather than stored, using
/// HKDF-Expand ONLY (Extract is skipped — the DEK is already a uniform
/// 256-bit key, so running Extract on it is a no-op per RFC 5869 §3.3):
///   PRK  = DEK (passed directly; NO salt)
///   info = "dbkv-chunk-v1" ‖ file_IV ‖ uint32_be(chunk_index)
///   L    = 12
/// `file_IV` is a per-file uniqueness value folded into `info` (NOT an
/// HKDF salt). Different files carry different file_IV → distinct info
/// → no nonce collision across files even if DEK material somehow
/// repeated. Within one file, the chunk_index in `info` separates
/// per-chunk nonces. See `deriveChunkNonce` for the implementation.
///
/// AAD on every chunk seal is the *entire* metadata-JSON byte
/// sequence. Tampering with any field — model_hash, layer count,
/// token_count — fails authentication on every chunk. Conversely, the
/// metadata itself isn't encrypted: callers can inspect it without
/// paying the KEK unwrap (e.g. to decide whether to load this file at
/// all). Confidentiality is for the KV tensors only.
///
/// `metadata.json_canonical` is encoded with stable key ordering so
/// the AAD bytes match exactly across write + read. Swift's
/// `JSONEncoder` doesn't guarantee key order; we sort keys explicitly
/// and use `.withoutEscapingSlashes` so the wire bytes are
/// deterministic.

import CryptoKit
import Foundation
import os

private let storeLogger = Logger(subsystem: "dev.darkbloom.provider", category: "encrypted-kv-store")

// MARK: - Errors

public enum EncryptedKVStoreError: Error, CustomStringConvertible, Sendable {
    case ioFailure(String)
    case malformedHeader(String)
    case unsupportedVersion(UInt16)
    case authenticationFailed(String)
    case sizeOverflow(String)
    case truncated(String)

    public var description: String {
        switch self {
        case .ioFailure(let m): return "I/O failure: \(m)"
        case .malformedHeader(let m): return "malformed header: \(m)"
        case .unsupportedVersion(let v): return "unsupported format version \(v)"
        case .authenticationFailed(let m): return "authentication failed: \(m)"
        case .sizeOverflow(let m): return "size overflow: \(m)"
        case .truncated(let m): return "truncated: \(m)"
        }
    }
}

// MARK: - Metadata

/// Public metadata block. Stored verbatim in the file and used as AAD
/// on every chunk seal. Tampering with any field breaks decryption.
///
/// `tokenPrefixHash` is the SHA-256 of the token-ID array that this
/// cache represents — that's the identity used by the prefix index.
/// `modelHash` binds the cache to a specific model file so loading
/// after a model upgrade fails closed.
public struct EncryptedKVStoreMetadata: Codable, Sendable, Equatable {
    public let magic: String
    public let formatVersion: Int
    public let modelHash: String
    public let modelDtype: String
    public let modelArch: String
    public let vocabSize: Int
    public let numLayers: Int
    public let kvHeads: Int
    public let headDim: Int
    public let tokenCount: Int
    public let tokenPrefixHash: String
    public let kvCacheClass: String
    public let metaState: [String]
    public let chunkPlaintextSizes: [Int]
    public let createdAt: Int64
    public let expiresAt: Int64?
    /// Per-tenant cache scope (e.g. `SHA256(prompt_cache_key)`). Bound into the
    /// GCM AAD via the metadata JSON, and re-checked on read (MB-1-style), so a
    /// file written under scope A cannot be opened/served under scope B even if
    /// a filename/digest collision were engineered. OPTIONAL + nil-by-default:
    /// an unscoped write omits the key entirely (synthesized Codable +
    /// JSONEncoder drop nil), so the AAD bytes of pre-scope files are unchanged
    /// and they still decrypt. nil and "" are treated as the same unscoped value.
    public let scope: String?
    public let schema: String

    public init(
        modelHash: String,
        modelDtype: String,
        modelArch: String,
        vocabSize: Int,
        numLayers: Int,
        kvHeads: Int,
        headDim: Int,
        tokenCount: Int,
        tokenPrefixHash: String,
        kvCacheClass: String,
        metaState: [String],
        chunkPlaintextSizes: [Int],
        createdAt: Int64 = Int64(Date().timeIntervalSince1970),
        expiresAt: Int64? = nil,
        scope: String? = nil
    ) {
        self.magic = "DBKV"
        self.formatVersion = Int(EncryptedKVStore.formatVersion)
        self.modelHash = modelHash
        self.modelDtype = modelDtype
        self.modelArch = modelArch
        self.vocabSize = vocabSize
        self.numLayers = numLayers
        self.kvHeads = kvHeads
        self.headDim = headDim
        self.tokenCount = tokenCount
        self.tokenPrefixHash = tokenPrefixHash
        self.kvCacheClass = kvCacheClass
        self.metaState = metaState
        self.chunkPlaintextSizes = chunkPlaintextSizes
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        // Normalize "" to nil so empty-scope writes stay byte-identical to
        // pre-scope files (no `scope` key in the JSON/AAD).
        self.scope = (scope?.isEmpty == false) ? scope : nil
        self.schema = "darkbloom.kv.v1"
    }
}

// MARK: - Codec

public enum EncryptedKVStore {

    // MARK: Constants

    public static let magic: [UInt8] = [0x44, 0x42, 0x4B, 0x56]  // "DBKV"
    public static let formatVersion: UInt16 = 1
    public static let fileIVLength = 12
    public static let nonceLength = 12
    public static let gcmTagLength = 16
    public static let chunkInfoPrefix = "dbkv-chunk-v1"
    public static let fileExtension = "darkbloom-kv"
    /// Hard bound on the length fields the header-only
    /// parser will trust before it has read the bytes. The wrapped DEK is ~60
    /// bytes (32-byte key + GCM tag + nonce) and metadata is a small JSON
    /// (layout + chunk sizes); 64 MiB is astronomically larger than either, but
    /// bounds a corrupt/hostile length prefix so we never allocate gigabytes
    /// (or loop) off an attacker-chosen uint32. A real value over this is
    /// treated as a malformed header.
    static let maxHeaderFieldBytes = 64 * 1024 * 1024
    /// Infix used for atomic-write temp files: `<name>.tmp-<UUID>`.
    static let tempInfix = "tmp-"

    /// Best-effort one-time sweep of orphaned atomic-write temp files in
    /// `dir`. `atomicWrite` cleans its own temp on a normal error, but a
    /// process KILL (SIGKILL/OOM/power-loss) between createFile and rename
    /// leaves a `.tmp-<UUID>` orphan with no sweep. Call once at cache
    /// setup so they can't accumulate across crashes. Never throws.
    /// Recurse ONE level into subdirectories. The engine tier
    /// writes flat (`kv/<modelKey>/<hash>.tmp-…`) but the checkpoint tier nests
    /// under a model-hash subdir (`kv/<modelKey>/<modelHash[:12]>/<digest>.tmp-…`)
    /// — a non-recursive sweep of the modelKey dir would leave nested multi-GB
    /// temp blobs behind (invisible to collectKVFiles, leaking outside the
    /// global budget).
    static func sweepStaleTempFiles(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return }
        for url in entries {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if let nested = try? fm.contentsOfDirectory(atPath: url.path) {
                    for name in nested where name.contains(".\(tempInfix)") {
                        try? fm.removeItem(at: url.appendingPathComponent(name))
                    }
                }
            } else if url.lastPathComponent.contains(".\(tempInfix)") {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: Write

    /// Encrypt `chunks` to a new file at `url`. The wrapped DEK is
    /// produced by the KEK actor using `metadata`-as-AAD. The same
    /// metadata bytes are bound into every chunk seal, so any tamper
    /// of the metadata breaks every chunk's auth tag — the cache
    /// becomes unreadable, the consumer falls back to cold prefill.
    ///
    /// Atomic-rename: written to a sibling `.tmp` first then renamed,
    /// so a crash mid-write doesn't leave a half-written file the
    /// index could pick up.
    public static func write(
        to url: URL,
        metadata: EncryptedKVStoreMetadata,
        chunks: [Data],
        kek: KVCacheKEK
    ) async throws {
        guard chunks.count == metadata.chunkPlaintextSizes.count else {
            throw EncryptedKVStoreError.malformedHeader(
                "chunk count \(chunks.count) ≠ metadata.chunkPlaintextSizes \(metadata.chunkPlaintextSizes.count)"
            )
        }
        for (i, c) in chunks.enumerated() where c.count != metadata.chunkPlaintextSizes[i] {
            throw EncryptedKVStoreError.malformedHeader(
                "chunk[\(i)] plaintext size \(c.count) ≠ metadata.chunkPlaintextSizes[\(i)] \(metadata.chunkPlaintextSizes[i])"
            )
        }

        let metadataJSON = try canonicalEncode(metadata)
        let fileIV = randomBytes(fileIVLength)

        // Wrap a fresh DEK with the KEK; the metadata JSON is bound
        // into the wrap so tampering with it also breaks DEK unwrap.
        let (dek, wrappedDEK) = try await kek.freshDEK(aad: metadataJSON)

        let header = try assembleHeader(fileIV: fileIV, wrappedDEK: wrappedDEK, metadataJSON: metadataJSON)
        try atomicWrite(header: header, chunks: chunks, dek: dek, fileIV: fileIV, aad: metadataJSON, to: url)
        storeLogger.debug(
            "wrote \(chunks.count, privacy: .public) chunks to \(url.lastPathComponent, privacy: .public)"
        )
    }

    /// Synchronous variant of `write` for callers that hold an
    /// already-unwrapped KEK `SymmetricKey` and cannot await the
    /// `KVCacheKEK` actor — notably the engine-step-loop persistence
    /// backend (`EncryptedPrefixCachePersistence`). Produces an
    /// identical on-disk file format; the only difference is the DEK is
    /// wrapped with `kekKey` via synchronous AES-GCM rather than through
    /// the actor.
    public static func writeSync(
        to url: URL,
        metadata: EncryptedKVStoreMetadata,
        chunks: [Data],
        kekKey: SymmetricKey
    ) throws {
        guard chunks.count == metadata.chunkPlaintextSizes.count else {
            throw EncryptedKVStoreError.malformedHeader(
                "chunk count \(chunks.count) ≠ metadata.chunkPlaintextSizes \(metadata.chunkPlaintextSizes.count)"
            )
        }
        for (i, c) in chunks.enumerated() where c.count != metadata.chunkPlaintextSizes[i] {
            throw EncryptedKVStoreError.malformedHeader(
                "chunk[\(i)] plaintext size \(c.count) ≠ metadata.chunkPlaintextSizes[\(i)] \(metadata.chunkPlaintextSizes[i])"
            )
        }
        let metadataJSON = try canonicalEncode(metadata)
        let fileIV = randomBytes(fileIVLength)
        let dek = SymmetricKey(size: .bits256)
        let wrappedDEK = try wrapDEKSync(dek: dek, kekKey: kekKey, aad: metadataJSON)

        let header = try assembleHeader(fileIV: fileIV, wrappedDEK: wrappedDEK, metadataJSON: metadataJSON)
        try atomicWrite(header: header, chunks: chunks, dek: dek, fileIV: fileIV, aad: metadataJSON, to: url)
    }

    // MARK: Read

    /// Read and decrypt all chunks from `url`. Returns the metadata
    /// (always parsed first; tamper of the metadata block surfaces as
    /// a DEK unwrap auth failure) and the array of plaintext chunks
    /// in the original write order.
    public static func read(
        from url: URL,
        kek: KVCacheKEK
    ) async throws -> (EncryptedKVStoreMetadata, [Data]) {
        let header = try readHeader(at: url)
        let dek = try await kek.unwrap(
            wrappedDEK: header.wrappedDEK,
            aad: header.metadataBytes
        )
        let plaintexts = try decryptChunks(at: url, header: header, dek: dek)
        return (header.metadata, plaintexts)
    }

    /// Synchronous variant of `read` for callers holding an unwrapped
    /// KEK `SymmetricKey` (see `writeSync`). Same format + auth checks.
    public static func readSync(
        from url: URL,
        kekKey: SymmetricKey
    ) throws -> (EncryptedKVStoreMetadata, [Data]) {
        let header = try readHeader(at: url)
        let dek = try unwrapDEKSync(wrapped: header.wrappedDEK, kekKey: kekKey, aad: header.metadataBytes)
        let plaintexts = try decryptChunks(at: url, header: header, dek: dek)
        return (header.metadata, plaintexts)
    }

    /// Parse only the metadata block — no DEK unwrap, no chunk
    /// decrypt. Suitable for index rebuilds and prefix lookups where
    /// we just need to know `token_count`, `model_hash`, etc.
    ///
    /// Reads ONLY the header bytes via `FileHandle`
    /// (fixed prefix → wrapped-DEK len+bytes → metadata len+bytes). It never
    /// maps or copies the multi-GB ciphertext body the way `splitHeaderAndBody`
    /// does. `reconcileWithDisk` calls this for every on-disk checkpoint, and a
    /// checkpoint body can be gigabytes — the old path allocated/copied the
    /// whole body per file only to discard it (OOM / huge latency).
    public static func readMetadataOnly(from url: URL) throws -> EncryptedKVStoreMetadata {
        try readHeader(at: url).metadata
    }

    /// Read EXACTLY `count` bytes from `handle` or throw `.truncated`.
    /// `FileHandle.read(upToCount:)` can return short reads, so loop until we
    /// have all the bytes (or hit EOF). Used by the header-only parser.
    private static func readExactly(_ count: Int, from handle: FileHandle, what: String) throws -> Data {
        guard count > 0 else { return Data() }
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: count - out.count)
            } catch {
                throw EncryptedKVStoreError.ioFailure("read \(what): \(error)")
            }
            guard let chunk, !chunk.isEmpty else {
                throw EncryptedKVStoreError.truncated("\(what): expected \(count) bytes, got \(out.count) before EOF")
            }
            out.append(chunk)
        }
        return out
    }

    // MARK: - Shared body/header/write helpers (used by both async + sync paths)

    /// Wrap a per-file DEK under the KEK key with AAD binding (sync).
    private static func wrapDEKSync(dek: SymmetricKey, kekKey: SymmetricKey, aad: Data) throws -> Data {
        let dekBytes = dek.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(dekBytes, using: kekKey, authenticating: aad)
        guard let combined = sealed.combined else {
            throw EncryptedKVStoreError.ioFailure("DEK wrap produced no combined output")
        }
        return combined
    }

    private static func unwrapDEKSync(wrapped: Data, kekKey: SymmetricKey, aad: Data) throws -> SymmetricKey {
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped)
            let raw = try AES.GCM.open(box, using: kekKey, authenticating: aad)
            guard raw.count == 32 else {
                throw EncryptedKVStoreError.authenticationFailed("DEK unwrap: expected 32 bytes, got \(raw.count)")
            }
            return SymmetricKey(data: raw)
        } catch let e as EncryptedKVStoreError {
            throw e
        } catch {
            throw EncryptedKVStoreError.authenticationFailed("DEK unwrap: \(error)")
        }
    }

    private static func assembleHeader(fileIV: Data, wrappedDEK: Data, metadataJSON: Data) throws -> Data {
        var header = Data()
        header.reserveCapacity(28 + wrappedDEK.count + metadataJSON.count)
        header.append(contentsOf: magic)
        header.append(uint16LE(formatVersion))
        header.append(uint16LE(0))  // flags
        header.append(fileIV)
        guard wrappedDEK.count <= UInt32.max else {
            throw EncryptedKVStoreError.sizeOverflow("wrapped DEK too large")
        }
        header.append(uint32LE(UInt32(wrappedDEK.count)))
        header.append(wrappedDEK)
        guard metadataJSON.count <= UInt32.max else {
            throw EncryptedKVStoreError.sizeOverflow("metadata too large")
        }
        header.append(uint32LE(UInt32(metadataJSON.count)))
        header.append(metadataJSON)
        return header
    }

    private static func atomicWrite(
        header: Data,
        chunks: [Data],
        dek: SymmetricKey,
        fileIV: Data,
        aad: Data,
        to url: URL
    ) throws {
        let tmpURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        let dir = url.deletingLastPathComponent()
        try ensureDirectory(dir)
        do {
            FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tmpURL)
            defer { try? handle.close() }
            try writeInBoundedSegments(handle, header)
            try writeEncryptedBody(handle, chunks: chunks, dek: dek, fileIV: fileIV, aad: aad)
            try handle.synchronize()  // fsync before rename
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw EncryptedKVStoreError.ioFailure("write tmp: \(error)")
        }
        do {
            // Atomic create-or-replace. `replaceItemAt` is for REPLACING
            // an existing item; on some platforms/filesystems it errors
            // when the destination doesn't exist (the common first-write
            // case). Use a plain rename to create, and only
            // `replaceItemAt` when there's an existing file to swap —
            // both are atomic within one filesystem. (On macOS/APFS
            // replaceItemAt happens to create too — proven by the
            // round-trip tests — but this is the portable, unambiguous
            // form.)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                do {
                    try FileManager.default.moveItem(at: tmpURL, to: url)
                } catch {
                    // Lost a race: another writer created it between the
                    // check and the move. Fall back to replace.
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw EncryptedKVStoreError.ioFailure("atomic rename: \(error)")
        }
        // Durability: flush the directory entry created by the rename
        // (F_FULLFSYNC on Apple SSDs); best-effort, see syncDirectory.
        syncDirectory(dir)
    }

    /// Stream the encrypted body directly to the file handle. This avoids
    /// constructing one full ciphertext `Data` for multi-GB checkpoints.
    private static func writeEncryptedBody(
        _ handle: FileHandle,
        chunks: [Data],
        dek: SymmetricKey,
        fileIV: Data,
        aad: Data
    ) throws {
        guard chunks.count <= UInt32.max else {
            throw EncryptedKVStoreError.sizeOverflow("too many chunks: \(chunks.count)")
        }
        try handle.write(contentsOf: uint32LE(UInt32(chunks.count)))
        for (i, plaintext) in chunks.enumerated() {
            guard plaintext.count <= Int(UInt32.max) - gcmTagLength else {
                throw EncryptedKVStoreError.sizeOverflow("chunk \(i) too large")
            }
            let nonce = try deriveChunkNonce(dek: dek, fileIV: fileIV, chunkIndex: UInt32(i))
            let sealed: AES.GCM.SealedBox
            do {
                sealed = try AES.GCM.seal(
                    plaintext, using: dek, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
            } catch {
                throw EncryptedKVStoreError.ioFailure("AES.GCM.seal chunk \(i): \(error)")
            }
            guard sealed.ciphertext.count == plaintext.count, sealed.tag.count == gcmTagLength else {
                throw EncryptedKVStoreError.ioFailure(
                    "unexpected sealed size: ct=\(sealed.ciphertext.count), tag=\(sealed.tag.count), pt=\(plaintext.count)")
            }
            let sealedLen = plaintext.count + gcmTagLength
            try handle.write(contentsOf: uint32LE(UInt32(sealedLen)))
            try writeInBoundedSegments(handle, sealed.ciphertext)
            try writeInBoundedSegments(handle, sealed.tag)
        }
    }

    /// `FileHandle.write(contentsOf:)` issues a SINGLE `write(2)` syscall for
    /// the whole `Data`. On Darwin a single `write` of more than `INT_MAX`
    /// (2_147_483_647) bytes fails with EINVAL ("Invalid argument") — so a
    /// large checkpoint body (e.g. a ~2.4GB hybrid KV snapshot at 100k tokens)
    /// can never be persisted in one call, and the throw is swallowed by the
    /// flush loop's catch → written=0, no file. Split the write into segments
    /// strictly below that limit. Segments are sliced as contiguous subranges
    /// (no extra copy of the whole buffer).
    private static let maxWriteSegment = 1 << 30  // 1 GiB, well under INT_MAX
    private static func writeInBoundedSegments(_ handle: FileHandle, _ data: Data) throws {
        guard !data.isEmpty else { return }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: maxWriteSegment, limitedBy: data.endIndex)
                ?? data.endIndex
            try handle.write(contentsOf: data[offset..<end])
            offset = end
        }
    }

    /// Decrypt body chunks from disk one at a time, validating each plaintext
    /// size against the metadata. Shared by `read` and `readSync`.
    private static func decryptChunks(at url: URL, header: ParsedHeader, dek: SymmetricKey) throws -> [Data] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: header.bodyOffset)
        } catch {
            throw EncryptedKVStoreError.ioFailure("open/seek \(url.lastPathComponent): \(error)")
        }
        defer { try? handle.close() }

        let countBytes = try readExactly(4, from: handle, what: "chunk count")
        let chunkCount = readUInt32LE(countBytes, at: 0)
        guard Int(chunkCount) == header.metadata.chunkPlaintextSizes.count else {
            throw EncryptedKVStoreError.malformedHeader(
                "chunk_count \(chunkCount) ≠ metadata.chunkPlaintextSizes.count \(header.metadata.chunkPlaintextSizes.count)")
        }
        var plaintexts: [Data] = []
        plaintexts.reserveCapacity(Int(chunkCount))
        for i in 0..<Int(chunkCount) {
            let ctLenBytes = try readExactly(4, from: handle, what: "chunk \(i) length field")
            let ctLen = Int(readUInt32LE(ctLenBytes, at: 0))
            guard ctLen >= gcmTagLength else {
                throw EncryptedKVStoreError.malformedHeader("chunk \(i) shorter than GCM tag")
            }
            let expectedPlaintext = header.metadata.chunkPlaintextSizes[i]
            guard expectedPlaintext >= 0, ctLen == expectedPlaintext + gcmTagLength else {
                throw EncryptedKVStoreError.malformedHeader(
                    "chunk \(i) ciphertext size \(ctLen) inconsistent with metadata plaintext size \(expectedPlaintext)")
            }
            let ciphertext = try readExactly(ctLen - gcmTagLength, from: handle, what: "chunk \(i) ciphertext")
            let tag = try readExactly(gcmTagLength, from: handle, what: "chunk \(i) tag")
            let nonce = try deriveChunkNonce(dek: dek, fileIV: header.fileIV, chunkIndex: UInt32(i))
            let box: AES.GCM.SealedBox
            do {
                box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            } catch {
                throw EncryptedKVStoreError.malformedHeader("chunk \(i) SealedBox: \(error)")
            }
            do {
                let pt = try AES.GCM.open(box, using: dek, authenticating: header.metadataBytes)
                guard pt.count == header.metadata.chunkPlaintextSizes[i] else {
                    throw EncryptedKVStoreError.authenticationFailed(
                        "chunk \(i) decrypted size \(pt.count) ≠ metadata size \(header.metadata.chunkPlaintextSizes[i])")
                }
                plaintexts.append(pt)
            } catch let e as EncryptedKVStoreError {
                throw e
            } catch {
                throw EncryptedKVStoreError.authenticationFailed("AES.GCM.open chunk \(i): \(error)")
            }
        }
        return plaintexts
    }

    // MARK: - Header parsing

    private struct ParsedHeader {
        let fileIV: Data
        let wrappedDEK: Data
        let metadataBytes: Data
        let metadata: EncryptedKVStoreMetadata
        let bodyOffset: UInt64
    }

    private static func readHeader(at url: URL) throws -> ParsedHeader {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw EncryptedKVStoreError.ioFailure("open \(url.lastPathComponent): \(error)")
        }
        defer { try? handle.close() }
        return try readHeader(from: handle)
    }

    private static func readHeader(from handle: FileHandle) throws -> ParsedHeader {
        let prefix = try readExactly(24, from: handle, what: "header prefix")

        // Magic.
        let m = prefix.prefix(4)
        guard Array(m) == magic else {
            throw EncryptedKVStoreError.malformedHeader(
                "magic mismatch: got \(Array(m).map { String(format: "%02x", $0) }.joined())"
            )
        }

        // Version.
        let version = readUInt16LE(prefix, at: 4)
        guard version == formatVersion else {
            throw EncryptedKVStoreError.unsupportedVersion(version)
        }

        // Flags — must be 0 in v1.
        let flags = readUInt16LE(prefix, at: 6)
        guard flags == 0 else {
            throw EncryptedKVStoreError.malformedHeader("flags \(flags) ≠ 0 in v1")
        }

        // file_IV.
        let fileIV = prefix.subdata(in: 8..<20)

        // wrapped DEK length + bytes.
        let wrappedLen = Int(readUInt32LE(prefix, at: 20))
        guard wrappedLen >= 0, wrappedLen <= maxHeaderFieldBytes else {
            throw EncryptedKVStoreError.malformedHeader("wrapped DEK length \(wrappedLen) out of bounds")
        }
        let wrappedDEK = try readExactly(wrappedLen, from: handle, what: "wrapped DEK")

        // Metadata length + bytes.
        let metadataLenBytes = try readExactly(4, from: handle, what: "metadata length")
        let metadataLen = Int(readUInt32LE(metadataLenBytes, at: 0))
        guard metadataLen >= 0, metadataLen <= maxHeaderFieldBytes else {
            throw EncryptedKVStoreError.malformedHeader("metadata length \(metadataLen) out of bounds")
        }
        let metadataBytes = try readExactly(metadataLen, from: handle, what: "metadata")

        let metadata: EncryptedKVStoreMetadata
        do {
            metadata = try canonicalDecode(metadataBytes)
        } catch {
            throw EncryptedKVStoreError.malformedHeader("metadata JSON: \(error)")
        }

        let header = ParsedHeader(
            fileIV: fileIV,
            wrappedDEK: wrappedDEK,
            metadataBytes: metadataBytes,
            metadata: metadata,
            bodyOffset: UInt64(24 + wrappedLen + 4 + metadataLen)
        )
        return header
    }

    // MARK: - Nonce derivation

    /// HKDF-Expand-only nonce derivation. HKDF-Extract is skipped
    /// because the DEK is already a uniformly random key — running
    /// Extract on a uniform 32-byte secret is a no-op (per RFC 5869
    /// §3.3). We pass the DEK directly as the PRK.
    ///
    /// info = "dbkv-chunk-v1" ‖ file_IV ‖ uint32_be(chunk_index)
    /// length = 12 bytes
    internal static func deriveChunkNonce(
        dek: SymmetricKey,
        fileIV: Data,
        chunkIndex: UInt32
    ) throws -> Data {
        guard fileIV.count == fileIVLength else {
            throw EncryptedKVStoreError.malformedHeader(
                "file_IV length \(fileIV.count) ≠ \(fileIVLength)"
            )
        }
        var info = Data()
        info.append(Data(chunkInfoPrefix.utf8))
        info.append(fileIV)
        info.append(uint32BE(chunkIndex))

        let nonceKey = HKDF<SHA256>.expand(
            pseudoRandomKey: dek,
            info: info,
            outputByteCount: nonceLength
        )
        return nonceKey.withUnsafeBytes { Data($0) }
    }

    // MARK: - JSON canonicalization

    /// Encode metadata with sorted keys so the AAD bytes are
    /// reproducible across writer/reader.
    internal static func canonicalEncode(_ metadata: EncryptedKVStoreMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(metadata)
    }

    internal static func canonicalDecode(_ data: Data) throws -> EncryptedKVStoreMetadata {
        let decoder = JSONDecoder()
        return try decoder.decode(EncryptedKVStoreMetadata.self, from: data)
    }

    // MARK: - Byte helpers

    private static func uint16LE(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 2)
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }

    private static func uint32BE(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes {
            UInt16(littleEndian: $0.load(as: UInt16.self))
        }
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }
    }

    private static func randomBytes(_ n: Int) -> Data {
        var buf = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &buf)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(buf)
    }

    private static func ensureDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true
                )
            } catch {
                throw EncryptedKVStoreError.ioFailure("mkdir \(url.path): \(error)")
            }
        }
    }

    /// Best-effort flush of a directory's metadata so a just-renamed
    /// entry is durable across power loss. Uses F_FULLFSYNC (true
    /// flush-to-media on APFS/Apple SSDs); failures are logged, not
    /// fatal — the cache is reconstructable, so a lost rename only
    /// costs a cold prefill.
    private static func syncDirectory(_ url: URL) {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            storeLogger.debug("syncDirectory: open failed for \(url.path, privacy: .public)")
            return
        }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) == -1 {
            // Fall back to fsync where F_FULLFSYNC isn't honored.
            _ = fsync(fd)
        }
    }
}
