// Copyright © 2026 Eigen Labs.
//
// DBK2 — per-block content-addressed encrypted file codec for the SSD
// prefix cache. One file per 256-token KV block; eviction is `unlink(2)`
// (zero write amplification — the endurance-correct choice, spec §4.1).
//
// The crypto core is the reviewed legacy `EncryptedKVStore` scheme,
// verbatim in structure with a format-version bump to 2:
//
// ```
// 0       4       magic = "DBKV"
// 4       2       uint16 LE  format_version (= 2)
// 6       2       uint16 LE  flags (reserved, must be 0)
// 8      12       file_IV       random per-file; folded into HKDF info
// 20      4       uint32 LE  wrapped_DEK length (N)
// 24      N       wrapped_DEK   AES-256-GCM(KEK, DEK, AAD=metadata)
// 24+N    4       uint32 LE  metadata length (M)
// 28+N    M       metadata      canonical JSON; verbatim AAD on chunk seal
// 28+N+M  4       uint32 LE  chunk_count
// then per chunk: uint32 LE ct length ‖ AES-256-GCM ct ‖ tag
// ```
//
// Per-chunk nonces: HKDF-Expand only (the DEK is already uniform),
//   info = "dbkv-chunk-v2" ‖ file_IV ‖ uint32_be(chunk_index), L = 12.
// AAD on every chunk seal AND on the DEK wrap is the canonical
// (sorted-keys) metadata JSON — tampering any metadata field breaks every
// auth tag and the reader deletes the file (fail-closed to recompute).
//
// WHAT A DISK OBSERVER SEES (reviewed field-by-field, spec §4.2): the
// HMAC lookup tag (not recomputable without K_lookup), the model's
// weight hash + layout epoch (model identity — already public per box),
// block shape descriptors (architecture — public), and createdAt. NO raw
// chain hashes, NO token ids/counts, NO scope/salt values, NO request ids.
//
// v1 `.darkbloom-kv` files are never read by this tier (different
// subtree + suffix; they die with the legacy engine's deletion pass).

import CryptoKit
import Foundation
import MLXLMCommon
#if canImport(os)
import os
#endif

// MARK: - Errors

enum SSDBlockStoreError: Error, CustomStringConvertible, Sendable {
    case ioFailure(String)
    case malformedHeader(String)
    case unsupportedVersion(UInt16)
    case authenticationFailed(String)
    case sizeOverflow(String)
    case truncated(String)
    case bindingMismatch(String)

    var description: String {
        switch self {
        case .ioFailure(let m): return "I/O failure: \(m)"
        case .malformedHeader(let m): return "malformed header: \(m)"
        case .unsupportedVersion(let v): return "unsupported format version \(v)"
        case .authenticationFailed(let m): return "authentication failed: \(m)"
        case .sizeOverflow(let m): return "size overflow: \(m)"
        case .truncated(let m): return "truncated: \(m)"
        case .bindingMismatch(let m): return "binding mismatch: \(m)"
        }
    }
}

// MARK: - Metadata

/// One chunk = one (cacheable layer × {K, V}) tensor for a single block,
/// in engine-native `[1, kvHeads, blockSize, headDim]` layout.
struct SSDBlockChunkDescriptor: Codable, Equatable, Sendable {
    /// Model layer index this chunk belongs to.
    let layerIndex: Int
    /// 0 = keys, 1 = values.
    let tensor: Int
    let shape: [Int]
    let dtype: String
}

/// Plaintext-but-authenticated DBK2 metadata (the GCM AAD). Reviewed
/// leak-by-leak in the design spec §4.2 — nothing prefix-derived beyond
/// the keyed `lookupTag`.
struct SSDBlockMetadata: Codable, Equatable, Sendable {
    let schema: String
    /// FULL 256-bit HMAC lookup tag (hex). The filename carries only the
    /// truncated 128-bit prefix; the reader re-verifies this full tag.
    let lookupTag: String
    /// Model weight root hash — MB-1 binding; mismatch ⇒ delete-on-sight.
    let weightHash: String
    /// Snapshot-semantics epoch (`SSDBlockStore.layoutEpoch`); mismatch ⇒
    /// fail-closed drop.
    let layoutEpoch: String
    let blockSize: Int
    /// Total layer slots of the model (incl. non-cacheable layers), so the
    /// adopter can rebuild a full-width per-layer array without the model.
    let layerCount: Int
    let chunks: [SSDBlockChunkDescriptor]
    let chunkPlaintextSizes: [Int]
    let createdAt: Int64

    init(
        lookupTag: String, weightHash: String, layoutEpoch: String, blockSize: Int,
        layerCount: Int, chunks: [SSDBlockChunkDescriptor], chunkPlaintextSizes: [Int],
        createdAt: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.schema = "darkbloom.kv.v2"
        self.lookupTag = lookupTag
        self.weightHash = weightHash
        self.layoutEpoch = layoutEpoch
        self.blockSize = blockSize
        self.layerCount = layerCount
        self.chunks = chunks
        self.chunkPlaintextSizes = chunkPlaintextSizes
        self.createdAt = createdAt
    }
}

// MARK: - Codec

enum SSDBlockStore {

    static let magic: [UInt8] = [0x44, 0x42, 0x4B, 0x56]  // "DBKV"
    static let formatVersion: UInt16 = 2
    static let fileIVLength = 12
    static let nonceLength = 12
    static let gcmTagLength = 16
    static let chunkInfoPrefix = "dbkv-chunk-v2"
    static let fileExtension = "dbk2"
    /// Same hostile-length bound as the v1 parser.
    static let maxHeaderFieldBytes = 64 * 1024 * 1024
    static let tempInfix = "tmp-"

    #if canImport(os)
    private static let logger = Logger(
        subsystem: "com.darkbloom.provider", category: "ssd_block_store")
    #endif

    // MARK: Layout epoch

    /// `"cbv2-snap-1|f16|<blockSize>|<layerKindsDigest[:8]>"` — bumps
    /// whenever the engine's snapshot semantics, KV dtype policy, block
    /// size, or the model's layer-kind derivation change, so old files
    /// fail closed. The provider binary version is deliberately NOT in
    /// here: an update that doesn't change layout keeps the cache warm.
    static func layoutEpoch(blockSize: Int, layerKinds: [CBv2LayerKind]) -> String {
        var canonical = ""
        for (i, kind) in layerKinds.enumerated() {
            let att: String
            switch kind.attention {
            case .full: att = "full"
            case .slidingWindow(let w): att = "sw\(w)"
            }
            let share = kind.sharesKVWithLayer.map { "s\($0)" } ?? "s-"
            canonical += "\(i):\(att):\(share):\(kind.kvHeads)x\(kind.headDim);"
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return "cbv2-snap-1|f16|\(blockSize)|\(hex)"
    }

    // MARK: Paths

    /// `<root>/<tagHex[0..2]>/<tagHex>.dbk2` — 2-hex-char fan-out keeps
    /// directories small at the default budget (~41 files/dir at 10k
    /// entries).
    static func fileURL(root: URL, tag16Hex: String) -> URL {
        root.appendingPathComponent(String(tag16Hex.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(tag16Hex).\(fileExtension)")
    }

    // MARK: Write

    /// Encrypt + atomically write one block file. `strictFsync` restores
    /// the per-file F_FULLFSYNC of the legacy store; the default skips it
    /// (best-effort cache; GCM auth catches torn writes — spec §4.5).
    static func write(
        to url: URL,
        metadata: SSDBlockMetadata,
        chunks: [Data],
        kekKey: SymmetricKey,
        strictFsync: Bool = false
    ) throws {
        guard chunks.count == metadata.chunkPlaintextSizes.count,
            chunks.count == metadata.chunks.count
        else {
            throw SSDBlockStoreError.malformedHeader(
                "chunk count \(chunks.count) ≠ metadata (\(metadata.chunkPlaintextSizes.count)/\(metadata.chunks.count))")
        }
        for (i, c) in chunks.enumerated() where c.count != metadata.chunkPlaintextSizes[i] {
            throw SSDBlockStoreError.malformedHeader(
                "chunk[\(i)] plaintext size \(c.count) ≠ metadata \(metadata.chunkPlaintextSizes[i])")
        }
        let metadataJSON = try canonicalEncode(metadata)
        let fileIV = randomBytes(fileIVLength)
        let dek = SymmetricKey(size: .bits256)
        let wrappedDEK = try wrapDEK(dek: dek, kekKey: kekKey, aad: metadataJSON)
        let header = try assembleHeader(
            fileIV: fileIV, wrappedDEK: wrappedDEK, metadataJSON: metadataJSON)

        let dir = url.deletingLastPathComponent()
        try ensureDirectory(dir)
        let tmpURL = url.appendingPathExtension("\(tempInfix)\(UUID().uuidString)")
        do {
            FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tmpURL)
            defer { try? handle.close() }
            try handle.write(contentsOf: header)
            try writeEncryptedBody(handle, chunks: chunks, dek: dek, fileIV: fileIV, aad: metadataJSON)
            if strictFsync { try handle.synchronize() }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw SSDBlockStoreError.ioFailure("write tmp: \(error)")
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                do {
                    try FileManager.default.moveItem(at: tmpURL, to: url)
                } catch {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw SSDBlockStoreError.ioFailure("atomic rename: \(error)")
        }
    }

    // MARK: Read

    /// Read + authenticate one block file. Any auth/binding failure throws;
    /// the caller deletes the file and falls back to recompute.
    static func read(
        from url: URL, kekKey: SymmetricKey
    ) throws -> (SSDBlockMetadata, [Data]) {
        let header = try readHeader(at: url)
        let dek = try unwrapDEK(
            wrapped: header.wrappedDEK, kekKey: kekKey, aad: header.metadataBytes)
        let plaintexts = try decryptChunks(at: url, header: header, dek: dek)
        return (header.metadata, plaintexts)
    }

    /// Header-only metadata read (startup index scan) — no DEK unwrap, no
    /// chunk decrypt. NOTE: an unauthenticated read (the AAD is only
    /// verified when chunks are opened); scan decisions made on it are
    /// re-verified at adoption time by the full authenticated `read`.
    static func readMetadataOnly(from url: URL) throws -> SSDBlockMetadata {
        try readHeader(at: url).metadata
    }

    // MARK: Temp sweep

    /// Best-effort removal of orphaned atomic-write temp files under the
    /// fan-out tree (process kill between createFile and rename).
    static func sweepStaleTempFiles(under root: URL) {
        let fm = FileManager.default
        guard let fanouts = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return }
        for dir in fanouts {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                guard let nested = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for name in nested where name.contains(".\(tempInfix)") {
                    try? fm.removeItem(at: dir.appendingPathComponent(name))
                }
            } else if dir.lastPathComponent.contains(".\(tempInfix)") {
                try? fm.removeItem(at: dir)
            }
        }
    }

    // MARK: - DEK wrap/unwrap (verbatim legacy scheme)

    private static func wrapDEK(dek: SymmetricKey, kekKey: SymmetricKey, aad: Data) throws -> Data {
        let dekBytes = dek.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(dekBytes, using: kekKey, authenticating: aad)
        guard let combined = sealed.combined else {
            throw SSDBlockStoreError.ioFailure("DEK wrap produced no combined output")
        }
        return combined
    }

    private static func unwrapDEK(wrapped: Data, kekKey: SymmetricKey, aad: Data) throws -> SymmetricKey {
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped)
            let raw = try AES.GCM.open(box, using: kekKey, authenticating: aad)
            guard raw.count == 32 else {
                throw SSDBlockStoreError.authenticationFailed(
                    "DEK unwrap: expected 32 bytes, got \(raw.count)")
            }
            return SymmetricKey(data: raw)
        } catch let e as SSDBlockStoreError {
            throw e
        } catch {
            throw SSDBlockStoreError.authenticationFailed("DEK unwrap: \(error)")
        }
    }

    // MARK: - Body

    private static func writeEncryptedBody(
        _ handle: FileHandle, chunks: [Data], dek: SymmetricKey, fileIV: Data, aad: Data
    ) throws {
        guard chunks.count <= UInt32.max else {
            throw SSDBlockStoreError.sizeOverflow("too many chunks: \(chunks.count)")
        }
        try handle.write(contentsOf: uint32LE(UInt32(chunks.count)))
        for (i, plaintext) in chunks.enumerated() {
            guard plaintext.count <= Int(UInt32.max) - gcmTagLength else {
                throw SSDBlockStoreError.sizeOverflow("chunk \(i) too large")
            }
            let nonce = try deriveChunkNonce(dek: dek, fileIV: fileIV, chunkIndex: UInt32(i))
            let sealed: AES.GCM.SealedBox
            do {
                sealed = try AES.GCM.seal(
                    plaintext, using: dek, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
            } catch {
                throw SSDBlockStoreError.ioFailure("AES.GCM.seal chunk \(i): \(error)")
            }
            let sealedLen = plaintext.count + gcmTagLength
            try handle.write(contentsOf: uint32LE(UInt32(sealedLen)))
            try handle.write(contentsOf: sealed.ciphertext)
            try handle.write(contentsOf: sealed.tag)
        }
    }

    private static func decryptChunks(
        at url: URL, header: ParsedHeader, dek: SymmetricKey
    ) throws -> [Data] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: header.bodyOffset)
        } catch {
            throw SSDBlockStoreError.ioFailure("open/seek \(url.lastPathComponent): \(error)")
        }
        defer { try? handle.close() }

        let countBytes = try readExactly(4, from: handle, what: "chunk count")
        let chunkCount = readUInt32LE(countBytes, at: 0)
        guard Int(chunkCount) == header.metadata.chunkPlaintextSizes.count else {
            throw SSDBlockStoreError.malformedHeader(
                "chunk_count \(chunkCount) ≠ metadata \(header.metadata.chunkPlaintextSizes.count)")
        }
        var plaintexts: [Data] = []
        plaintexts.reserveCapacity(Int(chunkCount))
        for i in 0..<Int(chunkCount) {
            let ctLenBytes = try readExactly(4, from: handle, what: "chunk \(i) length")
            let ctLen = Int(readUInt32LE(ctLenBytes, at: 0))
            let expectedPlaintext = header.metadata.chunkPlaintextSizes[i]
            guard ctLen >= gcmTagLength, expectedPlaintext >= 0,
                ctLen == expectedPlaintext + gcmTagLength
            else {
                throw SSDBlockStoreError.malformedHeader(
                    "chunk \(i) ciphertext size \(ctLen) inconsistent with plaintext \(expectedPlaintext)")
            }
            let ciphertext = try readExactly(ctLen - gcmTagLength, from: handle, what: "chunk \(i) ct")
            let tag = try readExactly(gcmTagLength, from: handle, what: "chunk \(i) tag")
            let nonce = try deriveChunkNonce(dek: dek, fileIV: header.fileIV, chunkIndex: UInt32(i))
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
                let pt = try AES.GCM.open(box, using: dek, authenticating: header.metadataBytes)
                guard pt.count == expectedPlaintext else {
                    throw SSDBlockStoreError.authenticationFailed(
                        "chunk \(i) decrypted size \(pt.count) ≠ metadata \(expectedPlaintext)")
                }
                plaintexts.append(pt)
            } catch let e as SSDBlockStoreError {
                throw e
            } catch {
                throw SSDBlockStoreError.authenticationFailed("AES.GCM.open chunk \(i): \(error)")
            }
        }
        return plaintexts
    }

    // MARK: - Header

    private struct ParsedHeader {
        let fileIV: Data
        let wrappedDEK: Data
        let metadataBytes: Data
        let metadata: SSDBlockMetadata
        let bodyOffset: UInt64
    }

    private static func readHeader(at url: URL) throws -> ParsedHeader {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SSDBlockStoreError.ioFailure("open \(url.lastPathComponent): \(error)")
        }
        defer { try? handle.close() }

        let prefix = try readExactly(24, from: handle, what: "header prefix")
        guard Array(prefix.prefix(4)) == magic else {
            throw SSDBlockStoreError.malformedHeader("magic mismatch")
        }
        let version = readUInt16LE(prefix, at: 4)
        guard version == formatVersion else {
            throw SSDBlockStoreError.unsupportedVersion(version)
        }
        guard readUInt16LE(prefix, at: 6) == 0 else {
            throw SSDBlockStoreError.malformedHeader("flags ≠ 0 in v2")
        }
        let fileIV = prefix.subdata(in: 8..<20)
        let wrappedLen = Int(readUInt32LE(prefix, at: 20))
        guard wrappedLen >= 0, wrappedLen <= maxHeaderFieldBytes else {
            throw SSDBlockStoreError.malformedHeader("wrapped DEK length \(wrappedLen) out of bounds")
        }
        let wrappedDEK = try readExactly(wrappedLen, from: handle, what: "wrapped DEK")
        let metadataLenBytes = try readExactly(4, from: handle, what: "metadata length")
        let metadataLen = Int(readUInt32LE(metadataLenBytes, at: 0))
        guard metadataLen >= 0, metadataLen <= maxHeaderFieldBytes else {
            throw SSDBlockStoreError.malformedHeader("metadata length \(metadataLen) out of bounds")
        }
        let metadataBytes = try readExactly(metadataLen, from: handle, what: "metadata")
        let metadata: SSDBlockMetadata
        do {
            metadata = try JSONDecoder().decode(SSDBlockMetadata.self, from: metadataBytes)
        } catch {
            throw SSDBlockStoreError.malformedHeader("metadata JSON: \(error)")
        }
        guard metadata.schema == "darkbloom.kv.v2" else {
            throw SSDBlockStoreError.malformedHeader("schema \(metadata.schema)")
        }
        return ParsedHeader(
            fileIV: fileIV, wrappedDEK: wrappedDEK, metadataBytes: metadataBytes,
            metadata: metadata, bodyOffset: UInt64(24 + wrappedLen + 4 + metadataLen))
    }

    private static func readExactly(_ count: Int, from handle: FileHandle, what: String) throws -> Data {
        guard count > 0 else { return Data() }
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: count - out.count)
            } catch {
                throw SSDBlockStoreError.ioFailure("read \(what): \(error)")
            }
            guard let chunk, !chunk.isEmpty else {
                throw SSDBlockStoreError.truncated(
                    "\(what): expected \(count) bytes, got \(out.count) before EOF")
            }
            out.append(chunk)
        }
        return out
    }

    // MARK: - Nonces (HKDF-Expand only, v2 info string)

    static func deriveChunkNonce(dek: SymmetricKey, fileIV: Data, chunkIndex: UInt32) throws -> Data {
        guard fileIV.count == fileIVLength else {
            throw SSDBlockStoreError.malformedHeader("file_IV length \(fileIV.count)")
        }
        var info = Data()
        info.append(Data(chunkInfoPrefix.utf8))
        info.append(fileIV)
        var be = chunkIndex.bigEndian
        withUnsafeBytes(of: &be) { info.append(contentsOf: $0) }
        let nonceKey = HKDF<SHA256>.expand(
            pseudoRandomKey: dek, info: info, outputByteCount: nonceLength)
        return nonceKey.withUnsafeBytes { Data($0) }
    }

    // MARK: - Canonical JSON (stable AAD bytes)

    static func canonicalEncode(_ metadata: SSDBlockMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(metadata)
    }

    // MARK: - Byte helpers

    private static func assembleHeader(fileIV: Data, wrappedDEK: Data, metadataJSON: Data) throws -> Data {
        var header = Data()
        header.reserveCapacity(28 + wrappedDEK.count + metadataJSON.count)
        header.append(contentsOf: magic)
        header.append(uint16LE(formatVersion))
        header.append(uint16LE(0))
        header.append(fileIV)
        guard wrappedDEK.count <= UInt32.max else {
            throw SSDBlockStoreError.sizeOverflow("wrapped DEK too large")
        }
        header.append(uint32LE(UInt32(wrappedDEK.count)))
        header.append(wrappedDEK)
        guard metadataJSON.count <= UInt32.max else {
            throw SSDBlockStoreError.sizeOverflow("metadata too large")
        }
        header.append(uint32LE(UInt32(metadataJSON.count)))
        header.append(metadataJSON)
        return header
    }

    private static func uint16LE(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 2)
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
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
                    at: url, withIntermediateDirectories: true)
            } catch {
                throw SSDBlockStoreError.ioFailure("mkdir \(url.path): \(error)")
            }
        }
    }
}
