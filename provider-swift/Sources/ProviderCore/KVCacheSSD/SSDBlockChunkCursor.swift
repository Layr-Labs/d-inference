// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation

/// Pull-style DBK3 reader: returns each chunk, in file order, once authenticated.
final class SSDBlockChunkCursor {
    let metadata: SSDBlockMetadata
    let fileIV: Data
    private let handle: FileHandle
    private let dek: SymmetricKey
    private let aad: Data
    private let identity: SSDAuthenticatedFileIdentity?
    private let beforeRead: ((Int) throws -> Void)?
    private let onBytesRead: (Int) -> Void
    private(set) var nextIndex = 0

    var chunkCount: Int { metadata.chunkPlaintextSizes.count }

    /// `tracksIdentity` lets `finish` prove the file unchanged since open.
    init(
        url: URL, kekKey: SymmetricKey, maximumChunkBytes: Int, maximumPlaintextBytes: Int,
        maximumMetadataBytes: Int = SSDBlockStore.maxHeaderFieldBytes,
        maximumWrappedDEKBytes: Int = SSDBlockStore.maxHeaderFieldBytes, tracksIdentity: Bool = false,
        beforeRead: ((Int) throws -> Void)? = nil, onBytesRead: @escaping (Int) -> Void = { _ in },
        beforeOperation: (@Sendable (SSDActiveIOOperation) -> Void)? = nil,
        validateMetadata: (SSDBlockMetadata) throws -> Void
    ) throws {
        guard SSDBlockStore.isSafeBlockURL(url), SSDBlockStore.isRealRegularFile(url) else {
            throw SSDBlockStoreError.ioFailure("unsafe block path")
        }
        handle = try SSDNoFollowIO.openRegularFileForReading(at: url, beforeOperation: beforeOperation)
        identity = tracksIdentity ? try SSDAuthenticatedFileIdentity(handle: handle) : nil
        let header = try SSDBlockStore.readHeader(from: handle, maximumMetadataBytes: maximumMetadataBytes,
                                                  maximumWrappedDEKBytes: maximumWrappedDEKBytes, beforeRead: beforeRead)
        onBytesRead(Int(header.bodyOffset))
        dek = try SSDBlockStore.unwrapDEK(wrapped: header.wrappedDEK, kekKey: kekKey, aad: header.metadataBytes)
        try SSDBlockStore.validateChunkSizes(header.metadata, maximumChunkBytes: maximumChunkBytes,
                                             maximumPlaintextBytes: maximumPlaintextBytes)
        try validateMetadata(header.metadata)
        let count = try SSDBlockStore.readExactly(4, from: handle, what: "chunk count", beforeRead: beforeRead)
        onBytesRead(4)
        guard Int(SSDBlockStore.readUInt32LE(count, at: 0)) == header.metadata.chunkPlaintextSizes.count else {
            throw SSDBlockStoreError.malformedHeader("streamed chunk count mismatch")
        }
        (metadata, aad, fileIV) = (header.metadata, header.metadataBytes, header.fileIV)
        (self.beforeRead, self.onBytesRead) = (beforeRead, onBytesRead)
    }

    /// The next chunk's plaintext, nil after the last; `skip` passes it unread.
    func next(skip: Bool = false) throws -> Data? {
        guard nextIndex < chunkCount else { return nil }
        let index = nextIndex, sealedBytes = metadata.chunkPlaintextSizes[index] + SSDBlockStore.gcmTagLength
        let length = try SSDBlockStore.readExactly(4, from: handle, what: "chunk length", beforeRead: beforeRead)
        guard Int(SSDBlockStore.readUInt32LE(length, at: 0)) == sealedBytes else {
            throw SSDBlockStoreError.malformedHeader("streamed ciphertext size mismatch")
        }
        nextIndex += 1
        if skip {
            try handle.seek(toOffset: try handle.offset() + UInt64(sealedBytes))
            return Data()
        }
        let sealed = try SSDBlockStore.readExactly(sealedBytes, from: handle, what: "chunk", beforeRead: beforeRead)
        onBytesRead(sealedBytes + 4)
        do {
            let nonce = try SSDBlockStore.deriveChunkNonce(dek: dek, fileIV: fileIV, chunkIndex: UInt32(index))
            return try AES.GCM.open(AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(SSDBlockStore.gcmTagLength),
                tag: sealed.suffix(SSDBlockStore.gcmTagLength)), using: dek, authenticating: aad)
        } catch {
            throw SSDBlockStoreError.authenticationFailed("streamed chunk \(index): \(error)")
        }
    }

    /// After the last chunk: the identity recorded at open, proven unchanged.
    func finish(requireEOF: Bool) throws -> SSDAuthenticatedFileIdentity? {
        guard nextIndex == chunkCount else {
            throw SSDBlockStoreError.malformedHeader("streamed read stopped before the last chunk")
        }
        if requireEOF {
            try beforeRead?(1)
            guard try handle.read(upToCount: 1)?.isEmpty ?? true else {
                throw SSDBlockStoreError.malformedHeader("unexpected trailing encrypted data")
            }
        }
        guard let identity, try SSDAuthenticatedFileIdentity(handle: handle) != identity else { return identity }
        throw SSDAuthenticatedFileChange.changedDuringRead
    }
}
