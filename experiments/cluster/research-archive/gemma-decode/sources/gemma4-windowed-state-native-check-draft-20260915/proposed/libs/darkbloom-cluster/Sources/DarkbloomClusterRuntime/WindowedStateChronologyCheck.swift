#if CBV2_WINDOW_STATE_FIXTURE
import Foundation
import MLX
import MLXLMCommon

enum WindowedStateChronologyCheck {
    static func require(_ value: Bool, _ message: String) throws {
        try WindowedStateFixtureOwner.require(value, message)
    }

    /// CPU encoding is independent of row slicing and MLX conversion.
    static func expectedBytes(layer: Int, range: Range<Int>, values: Bool, constant: Bool) -> Data {
        let kind = WindowedStateFixtureModel.kinds[layer]
        var result = Data()
        for head in 0..<kind.kvHeads {
            for position in range {
                for dimension in 0..<kind.headDim {
                    let value = WindowedStateFixtureModel.value(position: position, head: head,
                        dimension: dimension, values: values, constant: constant)
                    if layer == 0 {
                        var bits = UInt16(value.bitPattern >> 16).littleEndian
                        withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
                    } else {
                        var bits = value.bitPattern.littleEndian
                        withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
                    }
                }
            }
        }
        return result
    }

    static func assertSnapshot(_ value: CBv2OwnedStateSnapshot, constant: Bool = false) throws {
        try require(value.entries.count == 6, "Snapshot contains unexpected recurrent/shared state")
        for layer in 0..<2 {
            let kind = WindowedStateFixtureModel.kinds[layer]
            let start = layer == 0 ? 0 : max(0, value.committedTokens - WindowedStateFixtureModel.window)
            let range = start..<value.committedTokens
            let entries = value.entries.filter { $0.localLayerIndex == layer }
            try require(entries.count == 3, "Snapshot owner coverage differs")
            for entry in entries {
                try require(entry.globalLayerIndex == WindowedStateFixtureModel.globals[layer], "Snapshot global mapping differs")
                if entry.component == "kv.position_offsets" {
                    var position = Int32(value.committedTokens).littleEndian
                    let expected = withUnsafeBytes(of: &position) { Data($0) }
                    try require(entry.bytes == expected && entry.logicalRange == nil && entry.shape == [1], "Position bytes differ")
                } else {
                    try require(entry.component == "kv.keys" || entry.component == "kv.values", "Unexpected snapshot component")
                    let expected = expectedBytes(layer: layer, range: range, values: entry.component == "kv.values", constant: constant)
                    try require(entry.shape == [1, kind.kvHeads, range.count, kind.headDim]
                        && entry.logicalRange == range && entry.bytes == expected
                        && entry.byteCount == expected.count && entry.sha256 == sha256(expected), "Chronological native bytes differ from CPU token ledger")
                }
            }
        }
    }

    static func run(check: @escaping () throws -> Void) throws -> [String] {
        weak var full: AnyObject?, window: AnyObject?
        try autoreleasepool {
            let owner = try WindowedStateFixtureOwner(check: check)
            defer { try? owner.close() }
            full = owner.state.rows[0]; window = owner.state.rows[1]
            let layout = owner.state.geometry.attentionLayout!
            try require(layout.exactKVCapacityBytes == 8192 && layout.conservativeKVCapacityBytes == 12288
                && layout.windowTemporaryBytes == 14336 && owner.state.backend.bytesReserved == 12288,
                "Actual two-row admission differs from the fixed geometry ledger")
            var frontier = 0
            var retained: [(CBv2OwnedStateSnapshot, [Data?])] = []
            for count in [1, 1, 1, 1, 1, 7, 4, 5] {
                frontier += count
                try owner.advance(count)
                try require(owner.state.backend.bytesInUse == 8192 && owner.state.backend.bytesReserved == 12288,
                    "Mixed native types differ from exact/reserved row accounting")
                let snapshot = try owner.snapshot()
                try require(snapshot.committedTokens == frontier && owner.state.committedTokens == frontier, "Committed frontier differs")
                try assertSnapshot(snapshot)
                try require(owner.state.recurrent.spec.layers.isEmpty && owner.state.recurrent.confirmedStateSnapshot() == nil
                    && owner.state.recurrent.materializedByteCount == 0, "Empty recurrence gained state")
                if frontier == 5 { retained.append((snapshot, snapshot.entries.map(\.bytes))) }
                for (prior, bytes) in retained {
                    try require(prior.entries.map(\.bytes) == bytes, "CPU snapshot mutated with native ring")
                    try assertSnapshot(prior)
                }
                if frontier == 12 {
                    let before = snapshot.fingerprint, inUse = owner.state.backend.bytesInUse
                    let reserved = owner.state.backend.bytesReserved
                    let ids = owner.state.rows.map { ObjectIdentifier($0!) }
                    // This loop retains metadata only. It neither calls snapshot
                    // nor accesses cache roots; the next snapshot is outside it.
                    for _ in 0..<64 {
                        for (index, row) in owner.state.rows.enumerated() {
                            let metadata = (row! as! any CBv2ContiguousKVMetadataProviding).cbv2ContiguousMetadata
                            try owner.state.geometry.attentionLayout!.validate(metadata, layer: index, frontier: frontier)
                        }
                    }
                    try require(owner.state.backend.bytesInUse == inUse && owner.state.backend.bytesReserved == reserved
                        && owner.state.rows.map { ObjectIdentifier($0!) } == ids, "Metadata inspection changed storage ownership")
                    try require(try owner.snapshot().fingerprint == before, "Metadata inspection changed native bytes")
                }
            }
            try owner.close()
        }
        try require(full == nil && window == nil, "Retired cache rows remained owned")
        try identities(check: check)
        return ["actual-prefill2-decode1-type-probe", "mixed-bf16-fp32-full-window",
            "below-at-after-window-and-large-chunks", "multiple-wraps-cpu-chronology",
            "metadata-only-inspection", "cpu-snapshot-survives-mutation", "empty-recurrent-and-row-retirement",
            "range-global-layout-fingerprint-separation"]
    }

    static func identities(check: @escaping () throws -> Void) throws {
        let owner = try WindowedStateFixtureOwner(check: check, constant: true)
        defer { try? owner.close() }
        try owner.advance(4); let a = try owner.snapshot()
        try owner.advance(1); let b = try owner.snapshot()
        let ak = a.entries.first { $0.localLayerIndex == 1 && $0.component == "kv.keys" }!
        let bk = b.entries.first { $0.localLayerIndex == 1 && $0.component == "kv.keys" }!
        try require(ak.bytes == bk.bytes && ak.logicalRange != bk.logicalRange && ak.identity != bk.identity,
            "Equal retained window bytes lost their absolute chronology")
        let old = owner.state.geometry.attentionLayout!
        for change in ["global", "layout"] {
            var geometry = owner.state.geometry
            let layers = old.layers.enumerated().map { index, layer in
                LayerAttentionStateLayout.Layer(globalIndex: layer.globalIndex + (change == "global" ? 10 : 0),
                    kvHeads: layer.kvHeads, headDimension: layer.headDimension, window: layer.window, element: layer.element)
            }
            geometry.attentionLayout = try .init(layers: layers, maximumTokens: old.maximumTokens,
                maximumChunkTokens: change == "layout" ? 6 : old.maximumChunkTokens)
            let alternative = try CBv2OwnedStateSnapshot.capture(geometry: geometry, rows: owner.state.rows,
                recurrent: owner.state.recurrent, committedTokens: owner.state.committedTokens,
                globalLayerIndices: layers.map(\.globalIndex), includeBytes: true, check: check)
            try require(alternative.entries.map(\.bytes) == b.entries.map(\.bytes)
                && alternative.fingerprint != b.fingerprint, "Equal bytes lost global/layout identity")
        }
        try owner.close()
    }
}
#endif
