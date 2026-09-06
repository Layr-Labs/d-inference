// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLXLMCommon

/// DBK3's public header describes opaque byte segments only. Token IDs, tenant
/// scope, exact checkpoint position and tensor layout stay in encrypted chunk 0.
struct SSDHybridCheckpointEnvelope {
    enum EncodingError: Error { case sizeExceeded }
    struct Segment: Sendable {
        let tensor: Int
        let offset: Int
        let bytes: Int
    }

    let manifestBytes: Data
    let segments: [Segment]
    let plaintextBytes: Int

    init(manifest: CBv2CompleteCheckpointManifest, maximumPlaintextBytes: Int) throws {
        let tensorBytes = try manifest.validateStructure()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        manifestBytes = try encoder.encode(manifest)
        guard manifestBytes.count <= CBv2CompleteCheckpointManifest.maximumEncodedBytes else {
            throw EncodingError.sizeExceeded
        }
        let (total, overflow) = tensorBytes.addingReportingOverflow(manifestBytes.count)
        guard !overflow, total <= maximumPlaintextBytes else {
            throw EncodingError.sizeExceeded
        }
        plaintextBytes = total
        var result: [Segment] = []
        for (index, tensor) in manifest.tensors.enumerated() {
            var offset = 0
            while offset < tensor.byteCount {
                let count = min(CBv2CompleteCheckpointManifest.maximumSegmentBytes, tensor.byteCount - offset)
                result.append(Segment(tensor: index, offset: offset, bytes: count))
                offset += count
            }
        }
        segments = result
    }

    func metadata(
        tag: Data, identity: CBv2CompleteCheckpointIdentity, createdAt: Int64,
        backendLayout: String = CBv2CompleteCheckpointManifest.layout
    ) -> SSDBlockMetadata {
        let sizes = [manifestBytes.count] + segments.map(\.bytes)
        return SSDBlockMetadata(
            lookupTag: tag.hexString, weightHash: identity.modelAggregateHash,
            layoutEpoch: Self.layoutEpoch(identity: identity, backendLayout: backendLayout), blockSize: PrefixCachePolicy.blockSize,
            layerCount: 1,
            chunks: sizes.enumerated().map {
                .init(layerIndex: 0, tensor: $0.offset, shape: [$0.element], dtype: "uint8")
            }, chunkPlaintextSizes: sizes, createdAt: createdAt)
    }

    func matches(
        _ metadata: SSDBlockMetadata, tag: Data, identity: CBv2CompleteCheckpointIdentity,
        backendLayout: String = CBv2CompleteCheckpointManifest.layout
    ) -> Bool {
        metadata == self.metadata(
            tag: tag, identity: identity, createdAt: metadata.createdAt, backendLayout: backendLayout)
    }

    static func decodeManifest(_ bytes: Data) throws -> CBv2CompleteCheckpointManifest {
        guard !bytes.isEmpty, bytes.count <= CBv2CompleteCheckpointManifest.maximumEncodedBytes else {
            throw CBv2CompleteCheckpointError.invalidManifest
        }
        let manifest = try JSONDecoder().decode(CBv2CompleteCheckpointManifest.self, from: bytes)
        _ = try manifest.validateStructure()
        return manifest
    }

    static func layoutEpoch(
        identity: CBv2CompleteCheckpointIdentity,
        backendLayout: String = CBv2CompleteCheckpointManifest.layout
    ) -> String {
        // Canonical fixed-order, length-delimited identity; no request-derived
        // material appears here or in the public header.
        var data = Data("darkbloom-complete-checkpoint-envelope-v1".utf8)
        for value in [identity.modelAggregateHash, identity.promptContractID,
                      identity.buildID, identity.numericsFingerprint,
                      backendLayout] {
            var count = UInt64(value.utf8.count).littleEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(contentsOf: value.utf8)
        }
        return Data(SHA256.hash(data: data)).hexString
    }
}
