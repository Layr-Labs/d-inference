// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// A complete checkpoint at D stored against a parent at P < D. Native recurrent
/// layouts export restored rows again unchanged, so token-axis tensors keep
/// only the rows the parent lacks; the rest is stored whole.
struct SSDCheckpointDeltaLayout {
    /// Per block of the leading dimensions, rows `start..<start + stored`.
    struct Rows: Equatable { let blocks: Int, start: Int, stored: Int, rowBytes: Int }
    struct Tensor {
        let byteCount: Int
        let rows: Rows?
        var storedBytes: Int { rows.map { $0.blocks * $0.stored * $0.rowBytes } ?? byteCount }
    }

    /// A restore opens every file of a chain and holds one chunk of each.
    static let maximumChainFiles = 8
    let tensors: [Tensor]

    init?(parent: CBv2CompleteCheckpointManifest, child: CBv2CompleteCheckpointManifest) {
        guard [CBv2CompleteCheckpointManifest.pagedLayout, CBv2CompleteCheckpointManifest.layout].contains(child.backendLayout),
            parent.backendLayout == child.backendLayout, parent.identity == child.identity,
            parent.cacheSalt == child.cacheSalt, parent.assistantCodecID == child.assistantCodecID,
            parent.mediaIdentity == nil, child.mediaIdentity == nil, parent.position > 0,
            parent.position < child.position, parent.prefixTokens.count == parent.position,
            child.prefixTokens.starts(with: parent.prefixTokens), parent.tensors.count == child.tensors.count
        else { return nil }
        var tensors: [Tensor] = []
        for (old, new) in zip(parent.tensors, child.tensors) {
            guard old.role == new.role, old.layer == new.layer, old.dtype == new.dtype,
                old.shape.count == new.shape.count else { return nil }
            // K/V are [1, kvHeads, position, headDim]; MTP history is [1, position - 1, …].
            let axis = [.keys, .values].contains(new.role) ? 2 : [.assistantHidden, .assistantTokens].contains(new.role) ? 1 : 0
            guard axis > 0 else {
                guard [.convolution, .recurrent, .assistantFrontier].contains(new.role), old.shape == new.shape
                else { return nil }
                tensors.append(Tensor(byteCount: new.byteCount, rows: nil))
                continue
            }
            let offset = axis == 1 ? -1 : 0, blocks = new.shape[..<axis].reduce(1, *)
            guard old.shape[axis] == parent.position + offset, new.shape[axis] == child.position + offset,
                old.shape.indices.allSatisfy({ $0 == axis || old.shape[$0] == new.shape[$0] }) else { return nil }
            tensors.append(Tensor(byteCount: new.byteCount, rows: Rows(
                blocks: blocks, start: parent.position + offset, stored: child.position - parent.position,
                rowBytes: new.byteCount / (blocks * new.shape[axis]))))
        }
        self.tensors = tensors
    }

    /// Stored segments in file order, each within one row block.
    func segments(maximumBytes: Int) -> [SSDHybridCheckpointEnvelope.Segment] {
        var result: [SSDHybridCheckpointEnvelope.Segment] = []
        for (index, tensor) in tensors.enumerated() {
            let blockBytes = tensor.rows.map { $0.stored * $0.rowBytes } ?? tensor.byteCount
            for block in 0..<(tensor.rows?.blocks ?? 1) {
                for start in stride(from: 0, to: blockBytes, by: maximumBytes) {
                    result.append(.init(tensor: index, offset: block * blockBytes + start,
                                        bytes: min(maximumBytes, blockBytes - start)))
                }
            }
        }
        return result
    }

    /// Offset in the complete tensor of a stored segment's first byte.
    func completeOffset(of segment: SSDHybridCheckpointEnvelope.Segment) -> Int {
        guard let rows = tensors[segment.tensor].rows else { return segment.offset }
        let blockBytes = rows.stored * rows.rowBytes
        return (segment.offset / blockBytes * (rows.start + rows.stored) + rows.start) * rows.rowBytes
            + segment.offset % blockBytes
    }

    /// Per tensor, the forward reads that rebuild the leaf of `[root] + deltas`:
    /// (file, bytes, take) takes or skips the next stored bytes of one file.
    static func steps(root: CBv2CompleteCheckpointManifest, deltas: [Self]) -> [[(file: Int, bytes: Int, take: Bool)]] {
        guard let leaf = deltas.last else { return root.tensors.map { [(0, $0.byteCount, true)] } }
        return leaf.tensors.indices.map { index in
            guard let rows = leaf.tensors[index].rows else {
                // Only the leaf's copy of a replaced tensor is read.
                let skipped = [root.tensors[index].byteCount] + deltas.dropLast().map { $0.tensors[index].storedBytes }
                return skipped.enumerated().map { ($0.offset, $0.element, false) }
                    + [(deltas.count, leaf.tensors[index].storedBytes, true)]
            }
            // Per row block: the root's leading rows, then each delta's rows.
            let stored = deltas.map { $0.tensors[index].rows?.stored ?? 0 }
            let fileRows = [rows.start + rows.stored - stored.reduce(0, +)] + stored
            return (0..<rows.blocks).flatMap { _ in
                fileRows.enumerated().map { ($0.offset, $0.element * rows.rowBytes, true) }
            }
        }
    }
}
