// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation

extension SSDBlockStore {
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
                                    maximumWrappedDEKBytes: maximumWrappedDEKBytes)
        onBytesRead(Int(header.bodyOffset))
        let dek = try unwrapDEK(wrapped: header.wrappedDEK, kekKey: kekKey, aad: header.metadataBytes)
        try validateChunkSizes(header.metadata, maximumChunkBytes: maximumChunkBytes,
                               maximumPlaintextBytes: maximumPlaintextBytes)
        try validateMetadata(header.metadata)
        let count = readUInt32LE(try readExactly(4, from: handle, what: "chunk count"), at: 0)
        onBytesRead(4)
        guard Int(count) == header.metadata.chunkPlaintextSizes.count else {
            throw SSDBlockStoreError.malformedHeader("streamed chunk count mismatch")
        }
        for index in 0..<Int(count) {
            try checkCancellation()
            let length = Int(readUInt32LE(
                try readExactly(4, from: handle, what: "chunk length"), at: 0))
            let expected = header.metadata.chunkPlaintextSizes[index]
            guard length == expected + gcmTagLength else {
                throw SSDBlockStoreError.malformedHeader("streamed ciphertext size mismatch")
            }
            let ciphertext = try readExactly(expected, from: handle, what: "chunk ciphertext")
            let tag = try readExactly(gcmTagLength, from: handle, what: "chunk tag")
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
        if requireEOF, !(try handle.read(upToCount: 1) ?? Data()).isEmpty {
            throw SSDBlockStoreError.malformedHeader("unexpected trailing encrypted data")
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
