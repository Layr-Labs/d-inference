// Copyright © 2026 Eigen Labs.
//
// DBK3 — per-block content-addressed encrypted file codec for the SSD
// prefix cache. One file per 256-token KV block; eviction is `unlink(2)`
// (zero write amplification — the endurance-correct choice, spec §4.1).
//
// The crypto core is the reviewed legacy `EncryptedKVStore` scheme,
// verbatim in structure with a format-version bump to 3:
//
// ```
// 0       4       magic = "DBKV"
// 4       2       uint16 LE  format_version (= 3)
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
//   info = "dbkv-chunk-v3" ‖ file_IV ‖ uint32_be(chunk_index), L = 12.
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

/// Plaintext-but-authenticated DBK3 metadata (the GCM AAD). Reviewed
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
        self.schema = "darkbloom.kv.v3"
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
    static let formatVersion: UInt16 = 3
    static let fileIVLength = 12
    static let nonceLength = 12
    static let gcmTagLength = 16
    static let chunkInfoPrefix = "dbkv-chunk-v3"
    static let fileExtension = "dbk3"
    /// Same hostile-length bound as the v1 parser.
    static let maxHeaderFieldBytes = 64 * 1024 * 1024
    static let tempMarker = "darkbloom-tmp"
    /// Temp ownership must survive concurrent maintenance in other processes.
    /// One hour is deliberately much longer than the largest expected block write.
    static let crashTempTTLSeconds: Int64 = 60 * 60

    #if canImport(os)
    private static let logger = Logger(
        subsystem: "com.darkbloom.provider", category: "ssd_block_store")
    #endif

    // MARK: Layout epoch

    /// `"cbv2-snap-2|f16|<blockSize>|<layerKindsDigest[:8]>"` — bumps
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
        return "cbv2-snap-2|f16|\(blockSize)|\(hex)"
    }

    // MARK: Paths

    /// `<root>/<tagHex[0..2]>/<tagHex>.dbk3` — 2-hex-char fan-out keeps
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
        strictFsync: Bool = false,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil
    ) throws -> Int {
        let modelRoot = url.deletingLastPathComponent().deletingLastPathComponent()
        guard isSafeBlockURL(url, modelRoot: modelRoot) else {
            throw SSDBlockStoreError.ioFailure("unsafe block path")
        }
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

        do {
            return try SSDNoFollowIO.writeAtomically(
                to: url,
                strictFsync: strictFsync,
                beforeOperation: beforeOperation
            ) { handle in
            try handle.write(contentsOf: header)
            try writeEncryptedBody(handle, chunks: chunks, dek: dek, fileIV: fileIV, aad: metadataJSON)
            }
        } catch {
            throw SSDBlockStoreError.ioFailure("descriptor-relative write: \(error)")
        }
    }

    // MARK: Read

    /// Read + authenticate one block file. Any auth/binding failure throws;
    /// the caller deletes the file and falls back to recompute.
    static func read(
        from url: URL,
        kekKey: SymmetricKey,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil
    ) throws -> (SSDBlockMetadata, [Data]) {
        guard isSafeBlockURL(url), isRealRegularFile(url) else {
            throw SSDBlockStoreError.ioFailure("unsafe block path")
        }
        let handle = try SSDNoFollowIO.openRegularFileForReading(
            at: url, beforeOperation: beforeOperation)
        defer { try? handle.close() }
        let header = try readHeader(from: handle)
        let dek = try unwrapDEK(
            wrapped: header.wrappedDEK, kekKey: kekKey, aad: header.metadataBytes)
        let plaintexts = try decryptChunks(from: handle, header: header, dek: dek)
        return (header.metadata, plaintexts)
    }

    /// Header-only metadata read (startup index scan) — no DEK unwrap, no
    /// chunk decrypt. NOTE: an unauthenticated read (the AAD is only
    /// verified when chunks are opened); scan decisions made on it are
    /// re-verified at adoption time by the full authenticated `read`.
    static func readMetadataOnly(
        from url: URL,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil
    ) throws -> SSDBlockMetadata {
        guard isSafeBlockURL(url), isRealRegularFile(url) else {
            throw SSDBlockStoreError.ioFailure("unsafe block path")
        }
        let handle = try SSDNoFollowIO.openRegularFileForReading(
            at: url, beforeOperation: beforeOperation)
        defer { try? handle.close() }
        return try readHeader(from: handle).metadata
    }

    // MARK: Temp sweep

    /// `<tag>.dbk3.darkbloom-tmp.<UUID>`. The product-specific marker lets
    /// maintenance prove ownership without opening an incomplete DBK3 file.
    static func temporaryFileURL(for url: URL, uuid: UUID = UUID()) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).\(tempMarker).\(uuid.uuidString)")
    }

    /// Exact crash-temp ownership check. A candidate must carry the generated
    /// filename grammar and live in the matching 2-hex fan-out directory.
    static func isOwnedTempFileName(_ name: String, fanout: String) -> Bool {
        guard isLowerHex(fanout, count: 2), name.utf8.count > 32 else { return false }
        let tag = String(name.prefix(32))
        guard isLowerHex(tag, count: 32), tag.hasPrefix(fanout) else { return false }
        let marker = ".\(fileExtension).\(tempMarker)."
        let remainder = String(name.dropFirst(32))
        guard remainder.hasPrefix(marker) else { return false }
        let uuidString = String(remainder.dropFirst(marker.count))
        guard uuidString.utf8.count == 36, let uuid = UUID(uuidString: uuidString) else {
            return false
        }
        return uuid.uuidString == uuidString
    }

    static func isLowerHex(_ value: String, count: Int) -> Bool {
        guard value.utf8.count == count else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    /// Reject a maintenance root whose path resolves through any symlink.
    /// Maintenance performs deletion, so following a caller-controlled root
    /// outside the dedicated cache hierarchy is never acceptable.
    static func isSafeMaintenanceRoot(_ root: URL) -> Bool {
        pathResolvesToItself(root)
    }

    static func isStaleTempFile(modifiedAt: Int64?, nowSeconds: Int64) -> Bool {
        guard let modifiedAt, modifiedAt <= nowSeconds else { return false }
        return nowSeconds - modifiedAt >= crashTempTTLSeconds
    }

    /// Best-effort removal of orphaned atomic-write temp files under one
    /// recognized model tree (process kill between createFile and rename).
    /// Young files may belong to another process and are preserved. Near-matches
    /// and unrecognized directory shapes are never removed.
    @discardableResult
    static func sweepStaleTempFiles(
        under root: URL,
        nowSeconds: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> Int {
        let fm = FileManager.default
        guard isSafeMaintenanceRoot(root), isLowerHex(root.lastPathComponent, count: 12)
        else { return 0 }
        guard let fanouts = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        else { return 0 }
        var removed = 0
        for dir in fanouts {
            guard isLowerHex(dir.lastPathComponent, count: 2),
                let dirValues = try? dir.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                dirValues.isDirectory == true, dirValues.isSymbolicLink != true,
                let nested = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles])
            else { continue }
            for url in nested {
                guard isOwnedTempFileName(
                    url.lastPathComponent, fanout: dir.lastPathComponent),
                    let values = try? url.resourceValues(
                        forKeys: [
                            .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                        ]),
                    values.isRegularFile == true, values.isSymbolicLink != true,
                    isStaleTempFile(
                        modifiedAt: values.contentModificationDate.map {
                            Int64($0.timeIntervalSince1970)
                        },
                        nowSeconds: nowSeconds)
                else { continue }
                if removeItemIfSafe(at: url, under: root) {
                    removed += 1
                }
            }
        }
        return removed
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
        from handle: FileHandle, header: ParsedHeader, dek: SymmetricKey
    ) throws -> [Data] {
        do {
            try handle.seek(toOffset: header.bodyOffset)
        } catch {
            throw SSDBlockStoreError.ioFailure("seek encrypted body: \(error)")
        }

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

    private static func readHeader(from handle: FileHandle) throws -> ParsedHeader {
        try handle.seek(toOffset: 0)
        let prefix = try readExactly(24, from: handle, what: "header prefix")
        guard Array(prefix.prefix(4)) == magic else {
            throw SSDBlockStoreError.malformedHeader("magic mismatch")
        }
        let version = readUInt16LE(prefix, at: 4)
        guard version == formatVersion else {
            throw SSDBlockStoreError.unsupportedVersion(version)
        }
        guard readUInt16LE(prefix, at: 6) == 0 else {
            throw SSDBlockStoreError.malformedHeader("flags ≠ 0 in v3")
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
        guard metadata.schema == "darkbloom.kv.v3" else {
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

    // Decode little-endian fields BYTEWISE. `Data.subdata(in:)` / `Data`'s
    // backing storage carries no alignment guarantee, so the previous
    // `UnsafeRawBufferPointer.load(as: UInt16/UInt32)` could trap on a
    // misaligned pointer while scanning/reading an otherwise-valid on-disk
    // DBK3 entry (a cache miss must never crash the provider). Byte shifts
    // are alignment-agnostic and pin the on-disk endianness explicitly.
    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let b = data.subdata(in: offset..<(offset + 2))
        let base = b.startIndex
        return UInt16(b[base]) | (UInt16(b[base + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let b = data.subdata(in: offset..<(offset + 4))
        let base = b.startIndex
        return UInt32(b[base])
            | (UInt32(b[base + 1]) << 8)
            | (UInt32(b[base + 2]) << 16)
            | (UInt32(b[base + 3]) << 24)
    }

    private static func randomBytes(_ n: Int) -> Data {
        var buf = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &buf)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(buf)
    }

}
