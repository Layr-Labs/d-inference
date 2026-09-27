import Foundation
import MLXLMCommon

extension SSDHybridCheckpointStore {
    /// Concurrent prefills can reach the same prefix boundary using different
    /// chunk sizes. Keep the first complete checkpoint, including its original
    /// execution geometry; never compare its envelope to the donor's or combine
    /// tensors from the two executions.
    func validateDurableCheckpoint(_ job: WriteJob, at url: URL) throws {
        let incoming = job.source.manifest
        var metadata: SSDBlockMetadata?
        var storedEnvelope: SSDHybridCheckpointEnvelope?
        statsBox.update { $0.filesRead += 1 }
        try SSDBlockStore.readStreaming(
            from: url, kekKey: kekKey,
            maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
            maximumPlaintextBytes: config.maxReadBytes,
            maximumMetadataBytes: 1 << 20, maximumWrappedDEKBytes: 60, requireEOF: true,
            checkCancellation: { try self.checkWrite(job) },
            onBytesRead: { count in
                self.statsBox.update { $0.bytesRead += count; $0.donationReadBytes += count }
            }, validateMetadata: { header in
                guard header.lookupTag == job.tag.hexString,
                    header.weightHash == self.identity.modelAggregateHash,
                    header.layoutEpoch == SSDHybridCheckpointEnvelope.layoutEpoch(
                        identity: self.identity, backendLayout: self.config.backendLayout),
                    header.blockSize == PrefixCachePolicy.blockSize,
                    let firstSize = header.chunkPlaintextSizes.first,
                    firstSize > 0, firstSize <= CBv2CompleteCheckpointManifest.maximumEncodedBytes
                else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
                metadata = header
            }, consumeChunk: { index, bytes in
                if index == 0 {
                    let stored = try SSDHybridCheckpointEnvelope.decodeManifest(bytes)
                    guard stored.identity == incoming.identity,
                        stored.backendLayout == incoming.backendLayout,
                        stored.position == incoming.position,
                        stored.prefixTokens == incoming.prefixTokens,
                        stored.cacheSalt == incoming.cacheSalt,
                        stored.assistantCodecID == incoming.assistantCodecID,
                        stored.tensors == incoming.tensors,
                        stored.attentionLayers == incoming.attentionLayers,
                        let metadata
                    else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
                    let envelope = try SSDHybridCheckpointEnvelope(
                        manifest: stored, maximumPlaintextBytes: self.config.maxReadBytes)
                    guard bytes == envelope.manifestBytes,
                        envelope.matches(metadata, tag: job.tag, identity: self.identity,
                                         backendLayout: self.config.backendLayout)
                    else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
                    storedEnvelope = envelope
                } else {
                    guard let storedEnvelope,
                        storedEnvelope.segments.indices.contains(index - 1),
                        bytes.count == storedEnvelope.segments[index - 1].bytes
                    else { throw CBv2CompleteCheckpointError.invalidSegment }
                }
            })
        // readStreaming authenticates every declared segment and requires EOF;
        // an authenticated manifest alone is not durable checkpoint evidence.
        guard storedEnvelope != nil else { throw CBv2CompleteCheckpointError.incompleteTransfer }
        try checkWrite(job)
    }
}
