// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation

extension SSDBlockStore {
    /// AES.GCM combined box of the 32-byte DEK: nonce, key, tag.
    static let wrappedDEKBytes = nonceLength + 32 + gcmTagLength
    /// Magic 4, version 2, flags 2, file IV, wrapped-DEK length 4, wrapped
    /// DEK, metadata length 4, chunk count 4.
    static let streamedFixedBytes = 4 + 2 + 2 + fileIVLength + 4 + wrappedDEKBytes + 4 + 4
    /// Ciphertext length 4 and GCM tag per chunk; the nonce is derived.
    static let streamedChunkFramingBytes = 4 + gcmTagLength

    /// Exact length of the file `writeStreaming` publishes for `metadata`:
    /// the fixed header, the canonical metadata, and each chunk's plaintext
    /// plus framing. No I/O and no key, so a writer can claim disk budget for
    /// the complete stored size before its first byte.
    static func streamedFileBytes(for metadata: SSDBlockMetadata) throws -> Int {
        guard metadata.chunkPlaintextSizes.count == metadata.chunks.count else {
            throw SSDBlockStoreError.malformedHeader("invalid streamed chunk limits/count")
        }
        var total = streamedFixedBytes
        let parts = [try canonicalEncode(metadata).count]
            + metadata.chunkPlaintextSizes.flatMap { [$0, streamedChunkFramingBytes] }
        for part in parts {
            let (next, overflow) = total.addingReportingOverflow(part)
            guard part >= 0, !overflow else { throw SSDBlockStoreError.sizeOverflow("stored file size") }
            total = next
        }
        return total
    }

    /// DBK3 wire format with one plaintext chunk alive at a time. The producer
    /// may export a tensor segment directly; it need not retain a whole file.
    /// `beforePublish` receives the finished file's length while it is still a
    /// temp file; a throw there removes it and nothing is published.
    static func writeStreaming(
        to url: URL, metadata: SSDBlockMetadata, kekKey: SymmetricKey,
        maximumChunkBytes: Int, strictFsync: Bool = false,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil,
        beforePublish: ((Int) throws -> Void)? = nil,
        chunk: (Int) throws -> Data
    ) throws -> Int {
        guard isSafeBlockURL(url) else {
            throw SSDBlockStoreError.ioFailure("unsafe block path")
        }
        try validateChunkSizes(metadata, maximumChunkBytes: maximumChunkBytes,
                               maximumPlaintextBytes: Int.max)
        let metadataJSON = try canonicalEncode(metadata)
        let fileIV = randomBytes(fileIVLength)
        let dek = SymmetricKey(size: .bits256)
        let wrappedDEK = try wrapDEK(dek: dek, kekKey: kekKey, aad: metadataJSON)
        let header = try assembleHeader(
            fileIV: fileIV, wrappedDEK: wrappedDEK, metadataJSON: metadataJSON)
        return try SSDNoFollowIO.writeAtomically(
            to: url, strictFsync: strictFsync, beforeOperation: beforeOperation,
            beforePublish: beforePublish
        ) { handle in
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: uint32LE(UInt32(metadata.chunkPlaintextSizes.count)))
            for index in metadata.chunkPlaintextSizes.indices {
                let plaintext = try chunk(index)
                guard plaintext.count == metadata.chunkPlaintextSizes[index] else {
                    throw SSDBlockStoreError.malformedHeader("streamed chunk size mismatch")
                }
                let nonce = try deriveChunkNonce(dek: dek, fileIV: fileIV, chunkIndex: UInt32(index))
                let sealed = try AES.GCM.seal(
                    plaintext, using: dek, nonce: AES.GCM.Nonce(data: nonce), authenticating: metadataJSON)
                try handle.write(contentsOf: uint32LE(UInt32(plaintext.count + gcmTagLength)))
                try handle.write(contentsOf: sealed.ciphertext)
                try handle.write(contentsOf: sealed.tag)
            }
        }
    }

    /// Authenticate the header before calling the allocation/identity validator.
    /// Each chunk is authenticated before it reaches the sink. A later failure
    /// requires the caller to discard its incomplete destination; this method
    /// never publishes a partially reconstructed checkpoint.
    @discardableResult
    static func readStreaming(
        from url: URL, kekKey: SymmetricKey, maximumChunkBytes: Int,
        maximumPlaintextBytes: Int,
        maximumMetadataBytes: Int = maxHeaderFieldBytes,
        maximumWrappedDEKBytes: Int = maxHeaderFieldBytes,
        requireEOF: Bool = false,
        checkCancellation: () throws -> Void = {},
        beforeRead: ((Int) throws -> Void)? = nil,
        onBytesRead: (Int) -> Void = { _ in },
        onAuthenticatedFile: ((SSDAuthenticatedFileIdentity) -> Void)? = nil,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil,
        validateMetadata: (SSDBlockMetadata) throws -> Void,
        consumeChunk: (Int, Data) throws -> Void
    ) throws -> SSDBlockMetadata {
        try checkCancellation()
        guard isSafeBlockURL(url), isRealRegularFile(url) else {
            throw SSDBlockStoreError.ioFailure("unsafe block path")
        }
        let handle = try SSDNoFollowIO.openRegularFileForReading(
            at: url, beforeOperation: beforeOperation)
        defer { try? handle.close() }
        let initialIdentity = try onAuthenticatedFile.map { _ in try SSDAuthenticatedFileIdentity(handle: handle) }
        let header = try readHeader(from: handle, maximumMetadataBytes: maximumMetadataBytes,
                                    maximumWrappedDEKBytes: maximumWrappedDEKBytes, beforeRead: beforeRead)
        onBytesRead(Int(header.bodyOffset))
        let dek = try unwrapDEK(wrapped: header.wrappedDEK, kekKey: kekKey, aad: header.metadataBytes)
        try validateChunkSizes(header.metadata, maximumChunkBytes: maximumChunkBytes,
                               maximumPlaintextBytes: maximumPlaintextBytes)
        try validateMetadata(header.metadata)
        let count = readUInt32LE(try readExactly(4, from: handle, what: "chunk count", beforeRead: beforeRead), at: 0)
        onBytesRead(4)
        guard Int(count) == header.metadata.chunkPlaintextSizes.count else {
            throw SSDBlockStoreError.malformedHeader("streamed chunk count mismatch")
        }
        for index in 0..<Int(count) {
            try checkCancellation()
            let length = Int(readUInt32LE(
                try readExactly(4, from: handle, what: "chunk length", beforeRead: beforeRead), at: 0))
            let expected = header.metadata.chunkPlaintextSizes[index]
            guard length == expected + gcmTagLength else {
                throw SSDBlockStoreError.malformedHeader("streamed ciphertext size mismatch")
            }
            let ciphertext = try readExactly(expected, from: handle, what: "chunk ciphertext", beforeRead: beforeRead)
            let tag = try readExactly(gcmTagLength, from: handle, what: "chunk tag", beforeRead: beforeRead)
            onBytesRead(length + 4)
            let nonce = try deriveChunkNonce(dek: dek, fileIV: header.fileIV, chunkIndex: UInt32(index))
            let plaintext: Data
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
                plaintext = try AES.GCM.open(box, using: dek, authenticating: header.metadataBytes)
            } catch {
                throw SSDBlockStoreError.authenticationFailed("streamed chunk \(index): \(error)")
            }
            guard plaintext.count == expected else {
                throw SSDBlockStoreError.authenticationFailed("streamed plaintext size mismatch")
            }
            try consumeChunk(index, plaintext)
        }
        if requireEOF {
            try beforeRead?(1)
            if !(try handle.read(upToCount: 1) ?? Data()).isEmpty {
                throw SSDBlockStoreError.malformedHeader("unexpected trailing encrypted data")
            }
        }
        if let initialIdentity, let onAuthenticatedFile {
            guard try SSDAuthenticatedFileIdentity(handle: handle) == initialIdentity else {
                throw SSDAuthenticatedFileChange.changedDuringRead
            }
            onAuthenticatedFile(initialIdentity)
        }
        return header.metadata
    }

    private static func validateChunkSizes(
        _ metadata: SSDBlockMetadata, maximumChunkBytes: Int, maximumPlaintextBytes: Int
    ) throws {
        guard maximumChunkBytes >= 0, maximumPlaintextBytes >= 0,
            metadata.chunkPlaintextSizes.count == metadata.chunks.count,
            metadata.chunkPlaintextSizes.count <= UInt32.max
        else { throw SSDBlockStoreError.malformedHeader("invalid streamed chunk limits/count") }
        var total = 0
        for size in metadata.chunkPlaintextSizes {
            guard size >= 0, size <= maximumChunkBytes, size <= Int(UInt32.max) - gcmTagLength else {
                throw SSDBlockStoreError.sizeOverflow("streamed chunk exceeds limit")
            }
            let (next, overflow) = total.addingReportingOverflow(size)
            guard !overflow, next <= maximumPlaintextBytes else {
                throw SSDBlockStoreError.sizeOverflow("streamed plaintext exceeds budget")
            }
            total = next
        }
    }
}
