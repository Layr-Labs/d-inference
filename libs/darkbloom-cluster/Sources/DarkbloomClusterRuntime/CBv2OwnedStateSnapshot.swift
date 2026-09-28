import Foundation
import MLX
import MLXLMCommon

/// CPU-owned diagnostic snapshots cannot retain a device view across the next
/// state mutation. Raw bytes are optional; digests always cover logical bytes.
struct CBv2OwnedStateSnapshot {
    struct Entry {
        let localLayerIndex: Int
        let globalLayerIndex: Int
        let component: String
        let shape: [Int]
        let dtype: String
        let byteCount: Int
        let sha256: String
        let bytes: Data?

        var identity: String {
            "\(globalLayerIndex)|\(component)|\(shape)|\(dtype)|\(byteCount)|\(sha256)"
        }
    }
    let committedTokens: Int
    let entries: [Entry]
    let fingerprint: String
}

extension CBv2OwnedStateSnapshot {
    /// Shared with the unchanged baseline owner's snapshot hook. Caller first
    /// proves no open evaluation and validates its own committed state/frontier.
    /// A full-model baseline uses Array(0..<fullLayerCount); a stage uses its
    /// descriptor's local-to-global list. No model forward/lifecycle is replaced.
    static func capture(geometry: CBv2RequestGeometry, rows: [CBv2SequenceKV?],
                        recurrent: CBv2RecurrentRequestState, committedTokens: Int,
                        globalLayerIndices: [Int], includeBytes: Bool,
                        check: () throws -> Void) throws -> CBv2OwnedStateSnapshot {
        guard committedTokens > 0,
            rows.count == geometry.kinds.count, recurrent.spec == geometry.recurrent,
            !recurrent.isReleased,
            globalLayerIndices.count == geometry.kinds.count + geometry.recurrent.layers.count,
            Set(globalLayerIndices).count == globalLayerIndices.count,
            globalLayerIndices.allSatisfy({ $0 >= 0 }) else {
            throw ProbeError("CBv2 snapshot needs a complete unique layer mapping and committed frontier")
        }
        guard let confirmed = recurrent.confirmedStateSnapshot(),
            Set(confirmed.keys) == Set(geometry.recurrent.modelLayerIndices) else {
            throw ProbeError("CBv2 snapshot cannot inspect pending or incomplete recurrent generations")
        }
        var entries: [CBv2OwnedStateSnapshot.Entry] = []
        func append(_ array: MLXArray, local: Int, component: String) throws {
            guard globalLayerIndices.indices.contains(local) else { throw ProbeError("Snapshot layer mapping is out of bounds") }
            let bytes = array.asData().data
            try check()
            guard bytes.count == array.nbytes else { throw ProbeError("Snapshot logical byte count differs") }
            entries.append(.init(localLayerIndex: local, globalLayerIndex: globalLayerIndices[local],
                component: component, shape: array.shape, dtype: String(describing: array.dtype),
                byteCount: bytes.count, sha256: sha256(bytes), bytes: includeBytes ? bytes : nil))
        }
        for (index, optionalRow) in rows.enumerated() {
            guard let row = optionalRow, row.absoluteOffset == committedTokens,
                row.retainedCount == committedTokens, geometry.caches[index].rows.count == 1,
                geometry.caches[index].rows[0] === row else {
                throw ProbeError("Snapshot row identity/frontier differs from committed request state")
            }
            let snapshot = row.snapshot()
            let layer = geometry.kinds[index].modelLayerIndex!
            try append(snapshot.keys, local: layer, component: "kv.keys")
            try append(snapshot.values, local: layer, component: "kv.values")
            try append(geometry.caches[index].positionOffsets, local: layer, component: "kv.position_offsets")
        }
        for layer in geometry.recurrent.modelLayerIndices {
            try append(confirmed[layer]!.conv!, local: layer, component: "conv")
            try append(confirmed[layer]!.ssm!, local: layer, component: "ssm")
        }
        entries.sort { ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component) }
        let fingerprint = sha256(Data((["cbv2-owned-state-v1", "tokens=\(committedTokens)"]
            + entries.map(\.identity)).joined(separator: "\n").utf8))
        return .init(committedTokens: committedTokens, entries: entries, fingerprint: fingerprint)
    }
}

extension CBv2OwnedRequestState {
    func snapshot(globalLayerIndices: [Int], includeBytes: Bool,
                  check: () throws -> Void) throws -> CBv2OwnedStateSnapshot {
        try requireOpen()
        try validateState(after: committedTokens)
        return try CBv2OwnedStateSnapshot.capture(geometry: geometry, rows: rows, recurrent: recurrent,
            committedTokens: committedTokens, globalLayerIndices: globalLayerIndices,
            includeBytes: includeBytes, check: check)
    }
}
