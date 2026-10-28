// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation

extension SSDBlockStore {
    /// Charge the complete DBK3 file, including metadata and authentication tags.
    static func serializedByteCount(metadata: SSDBlockMetadata) throws -> Int {
        let header = try assembleHeader(
            fileIV: Data(count: fileIVLength),
            wrappedDEK: Data(count: nonceLength + 32 + gcmTagLength),
            metadataJSON: canonicalEncode(metadata))
        var bytes = header.count + 4 // chunk count
        for size in metadata.chunkPlaintextSizes {
            guard size >= 0, size <= Int.max - bytes - 4 - gcmTagLength else {
                throw SSDBlockStoreError.sizeOverflow("serialized block size overflow")
            }
            bytes += 4 + size + gcmTagLength
        }
        return bytes
    }

    /// DBK3 wire format with one plaintext chunk alive at a time. The producer
    /// may export a tensor segment directly; it need not retain a whole file.
    static func writeStreaming(
        to url: URL, metadata: SSDBlockMetadata, kekKey: SymmetricKey,
        maximumChunkBytes: Int, strictFsync: Bool = false,
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil,
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
            to: url, strictFsync: strictFsync, beforeOperation: beforeOperation
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
        return try withoutActuallyEscaping(onBytesRead) { onBytesRead in
            let cursor = try SSDBlockChunkCursor(
                url: url, kekKey: kekKey, maximumChunkBytes: maximumChunkBytes,
                maximumPlaintextBytes: maximumPlaintextBytes, maximumMetadataBytes: maximumMetadataBytes,
                maximumWrappedDEKBytes: maximumWrappedDEKBytes, tracksIdentity: onAuthenticatedFile != nil,
                beforeRead: beforeRead, onBytesRead: onBytesRead, beforeOperation: beforeOperation,
                validateMetadata: validateMetadata)
            for index in 0..<cursor.chunkCount {
                try checkCancellation()
                try consumeChunk(index, try cursor.next() ?? Data())
            }
            if let identity = try cursor.finish(requireEOF: requireEOF) { onAuthenticatedFile?(identity) }
            return cursor.metadata
        }
    }

    static func validateChunkSizes(
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
