import Foundation
import MLXLMCommon

extension SSDHybridCheckpointStore {
    /// One open file of a restore chain; its stored bytes are consumed forward.
    struct ChainFile {
        let envelope: SSDHybridCheckpointEnvelope
        let cursor: SSDBlockChunkCursor
        let link: SSDHybridCheckpointEnvelope.Parent
        var chunk = Data(), offset = 0

        /// Takes (into `emit`) or drops the next `count` bytes; dropped chunks are skipped unread.
        mutating func consume(_ count: Int, take: Bool, check: () throws -> Void, emit: (Data) throws -> Void) throws {
            var remaining = count
            while remaining > 0 {
                if offset == chunk.count {
                    guard cursor.nextIndex < cursor.chunkCount else { throw CBv2CompleteCheckpointError.invalidSegment }
                    let size = cursor.metadata.chunkPlaintextSizes[cursor.nextIndex], skip = !take && size <= remaining
                    if !skip { try check() }
                    (chunk, offset) = (try cursor.next(skip: skip) ?? Data(), 0)
                    if skip { remaining -= size; continue }
                }
                let length = min(remaining, chunk.count - offset)
                if take { try emit(length == chunk.count ? chunk : chunk.subdata(in: offset..<offset + length)) }
                (offset, remaining) = (offset + length, remaining - length)
            }
        }
    }

    /// Opens the chain root first and authenticates each manifest; each delta
    /// must commit to the file before it. Only the caller's held leaf proves its
    /// identity: ancestors are read unlocked, their chunks authenticated and
    /// pinned by the commitment, and an open handle survives removal. `blame`
    /// names the file in use.
    func openChain(
        _ candidate: ReadCandidate, tracksIdentity: Bool, check: () throws -> Void,
        beforeRead: @escaping (Int) throws -> Void, countRead: @escaping (Int) -> Void, blame: (Data) -> Void
    ) throws -> [ChainFile] {
        var files: [ChainFile] = []
        for (position, tag16) in candidate.chain.enumerated() {
            blame(tag16)
            try check()
            let cursor = try SSDBlockChunkCursor(
                url: fileURL(tag16), kekKey: kekKey, maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                maximumPlaintextBytes: config.maxReadBytes, maximumMetadataBytes: 1 << 20, maximumWrappedDEKBytes: 60,
                tracksIdentity: tracksIdentity && position == candidate.chain.count - 1, beforeRead: beforeRead, onBytesRead: countRead) { metadata in
                    guard position == candidate.chain.count - 1 ? metadata.lookupTag == candidate.tag.hexString
                            : metadata.lookupTag.hasPrefix(tag16.hexString),
                        metadata.weightHash == self.identity.modelAggregateHash,
                        metadata.layoutEpoch == SSDHybridCheckpointEnvelope.layoutEpoch(
                            identity: self.identity, backendLayout: self.config.backendLayout),
                        metadata.blockSize == PrefixCachePolicy.blockSize,
                        (metadata.chunkPlaintextSizes.first ?? Int.max) <= CBv2CompleteCheckpointManifest.maximumEncodedBytes,
                        metadata.parentCommitment == files.last?.link.commitment
                    else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
                }
            guard let bytes = try cursor.next(), let tag = SSDPrefixCache.hexDecode(cursor.metadata.lookupTag)
            else { throw CBv2CompleteCheckpointError.invalidManifest }
            let manifest = try SSDHybridCheckpointEnvelope.decodeManifest(bytes)
            let envelope = try SSDHybridCheckpointEnvelope(
                manifest: manifest, maximumPlaintextBytes: config.maxReadBytes, parent: files.last?.link)
            guard envelope.manifestBytes == bytes, envelope.matches(
                cursor.metadata, tag: tag, identity: identity, backendLayout: config.backendLayout)
            else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
            files.append(ChainFile(envelope: envelope, cursor: cursor, link: .init(
                tag16: tag16, manifest: manifest,
                commitment: lookupKeys.checkpointParentCommitmentHex(parentTag: tag, parentFileIV: cursor.fileIV))))
        }
        return files
    }

    /// Streams the leaf's tensors to `append`; every file must end at EOF unchanged.
    func streamChain(
        _ files: inout [ChainFile], check: () throws -> Void, blame: (Data) -> Void,
        append: (Int, Int, Data) throws -> Void
    ) throws -> SSDAuthenticatedFileIdentity? {
        let steps = SSDCheckpointDeltaLayout.steps(root: files[0].link.manifest, deltas: files.compactMap(\.envelope.delta))
        for (tensor, tensorSteps) in steps.enumerated() {
            var offset = 0
            for step in tensorSteps {
                blame(files[step.file].link.tag16)
                try files[step.file].consume(step.bytes, take: step.take, check: check) { data in
                    statsBox.update { $0.maximumSegmentBytes = max($0.maximumSegmentBytes, data.count) }
                    try append(tensor, offset, data)
                    offset += data.count
                }
            }
        }
        var identity: SSDAuthenticatedFileIdentity?
        for file in files {
            blame(file.link.tag16)
            guard file.offset == file.chunk.count else { throw CBv2CompleteCheckpointError.invalidSegment }
            try check()
            identity = try file.cursor.finish(requireEOF: true)
        }
        return identity
    }

    func fileURL(_ tag16: Data) -> URL { SSDBlockStore.fileURL(root: config.root, tag16Hex: tag16.hexString) }
}
