import Foundation
import MLXLMCommon

extension SSDHybridCheckpointStore {
    /// One open file of a restore chain; its stored bytes are consumed forward.
    struct ChainFile {
        let envelope: SSDHybridCheckpointEnvelope
        let cursor: SSDBlockChunkCursor
        let link: SSDHybridCheckpointEnvelope.Parent
        var chunk = Data(), offset = 0
        /// The next chunk this consumer takes (the manifest chunk is already read).
        var consumerIndex = 1
        /// Reads and opens this file's chunks ahead of `consume` when the stage is parallel.
        var prefetcher: SSDChunkPrefetcher?

        /// Takes (into `emit`) or drops the next `count` bytes; dropped chunks are skipped unread.
        mutating func consume(_ count: Int, take: Bool, check: () throws -> Void, emit: (Data) throws -> Void) throws {
            var remaining = count
            while remaining > 0 {
                if offset == chunk.count {
                    guard consumerIndex < cursor.chunkCount else { throw CBv2CompleteCheckpointError.invalidSegment }
                    let size = cursor.metadata.chunkPlaintextSizes[consumerIndex], skip = !take && size <= remaining
                    if !skip { try check() }
                    if let prefetcher {
                        chunk = try prefetcher.next(expectingIndex: consumerIndex, skip: skip)
                    } else {
                        chunk = try cursor.next(skip: skip) ?? Data()
                    }
                    (offset, consumerIndex) = (0, consumerIndex + 1)
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
        _ candidate: ReadCandidate, promptTokens: [Int], tracksIdentity: Bool, check: () throws -> Void,
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
            let manifest = try SSDHybridCheckpointEnvelope.decodeManifest(
                bytes, promptTokens: promptTokens, lookupKeys: lookupKeys)
            let envelope = try SSDHybridCheckpointEnvelope(
                manifest: manifest, lookupKeys: lookupKeys, maximumPlaintextBytes: config.maxReadBytes,
                parent: files.last?.link)
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
    /// `parallel` reads and authenticates each file's chunks ahead of the copy;
    /// `append` still receives the same bytes in the same order.
    func streamChain(
        _ files: inout [ChainFile], parallel: Bool, check: () throws -> Void, blame: (Data) -> Void,
        append: (Int, Int, Data) throws -> Void
    ) throws -> SSDAuthenticatedFileIdentity? {
        let steps = SSDCheckpointDeltaLayout.steps(root: files[0].link.manifest, deltas: files.compactMap(\.envelope.delta))
        let leaf = files[files.count - 1].link.manifest
        if parallel {
            let plans = Self.chunkPlans(steps: steps, chunkSizes: files.map { $0.cursor.metadata.chunkPlaintextSizes },
                                        firstIndices: files.map(\.consumerIndex))
            for index in files.indices where !plans[index].isEmpty && files[index].cursor.nextIndex == files[index].consumerIndex {
                files[index].prefetcher = SSDChunkPrefetcher(
                    cursor: files[index].cursor, plan: plans[index], depth: Self.parallelStageDepth)
            }
        }
        // Every exit waits until no read or decrypt touches a file.
        defer { for file in files { file.prefetcher?.cancel() } }
        for (tensor, tensorSteps) in steps.enumerated() {
            var offset = 0
            for step in tensorSteps {
                blame(files[step.file].link.tag16)
                try files[step.file].consume(step.bytes, take: step.take, check: check) { data in
                    statsBox.update { $0.maximumSegmentBytes = max($0.maximumSegmentBytes, data.count) }
                    // Stored as zeros; the prefix the digest proved supplies them.
                    let tokens = try SSDHybridCheckpointEnvelope.tokenTensorBytes(
                        manifest: leaf, tensor: tensor, offset: offset, count: data.count)
                    try append(tensor, offset, tokens ?? data)
                    offset += data.count
                }
            }
        }
        var identity: SSDAuthenticatedFileIdentity?
        for file in files {
            file.prefetcher?.finish()
            blame(file.link.tag16)
            guard file.offset == file.chunk.count else { throw CBv2CompleteCheckpointError.invalidSegment }
            try check()
            identity = try file.cursor.finish(requireEOF: true)
        }
        return identity
    }

    func fileURL(_ tag16: Data) -> URL { SSDBlockStore.fileURL(root: config.root, tag16Hex: tag16.hexString) }

    /// Chunks read but not yet consumed, per chain file.
    static let parallelStageDepth = 4

    /// Per file, the chunks `consume` will request for `steps`, in order, and
    /// whether it skips each one: the same decisions `ChainFile.consume` makes.
    /// A plan stops where `consume` would fail, so the failure surfaces there.
    static func chunkPlans(steps: [[(file: Int, bytes: Int, take: Bool)]], chunkSizes: [[Int]],
                           firstIndices: [Int]) -> [[SSDChunkPrefetcher.Planned]] {
        var plans = chunkSizes.map { _ in [SSDChunkPrefetcher.Planned]() }
        var next = firstIndices, available = chunkSizes.map { _ in 0 }, broken = chunkSizes.map { _ in false }
        for tensorSteps in steps {
            for step in tensorSteps where step.file < chunkSizes.count && !broken[step.file] {
                let f = step.file
                var remaining = step.bytes
                while remaining > 0 {
                    if available[f] == 0 {
                        guard next[f] < chunkSizes[f].count else { broken[f] = true; break }
                        let size = chunkSizes[f][next[f]], skip = !step.take && size <= remaining
                        plans[f].append(.init(index: next[f], skip: skip))
                        next[f] += 1
                        if skip { remaining -= size; continue }
                        available[f] = size
                    }
                    let length = min(remaining, available[f])
                    (available[f], remaining) = (available[f] - length, remaining - length)
                }
            }
        }
        return plans
    }
}
