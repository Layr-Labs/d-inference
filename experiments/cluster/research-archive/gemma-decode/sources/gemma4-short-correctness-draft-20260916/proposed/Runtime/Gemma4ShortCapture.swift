import Foundation
import MLX

enum Gemma4ShortCapture {
    static func row(_ array: MLXArray, ordinal: Int, sidecars: Gemma4ShortSidecars,
                    check: () throws -> Void) throws -> Gemma4ShortRow {
        try MLX.withError { native in
            func checked() throws { try native.check(); try check(); try native.check() }
            do {
                try checked()
                guard (0...1).contains(ordinal), array.shape == [1, 262_144],
                      [.float16, .bfloat16, .float32].contains(array.dtype) else { throw ProbeError("Gemma full row shape/type differs") }
                let selected = argMax(array), finite = all(isFinite(array))
                eval(array, selected, finite); try checked()
                guard selected.size == 1, selected.dtype == .uint32, finite.size == 1,
                      finite.item(Bool.self) else { throw ProbeError("Gemma native finite argmax differs") }
                let token = Int(selected.item(UInt32.self)); try checked()
                let recorded = try QwenRecordedLogits(array, vocabularySize: 262_144, check: checked)
                guard let maximum = recorded.record.values.max(),
                      let first = recorded.record.values.firstIndex(of: maximum), first == token else {
                    throw ProbeError("Gemma native argmax differs from full-row first maximum")
                }
                let file = try sidecars.write("row-\(ordinal).json", data: canonicalJSONData(recorded), check: checked)
                return .init(ordinal: ordinal, frontier: 32+ordinal, tokenID: token,
                    maximumTieCount: recorded.record.values.filter({ $0 == maximum }).count,
                    file: file, dtype: recorded.record.dtype, logicalBytesSHA256: recorded.record.logicalBytesSHA256)
            } catch { try native.check(); throw error }
        }
    }

    static func state(_ session: Gemma4OwnedForwardSession, sidecars: Gemma4ShortSidecars,
                      check: () throws -> Void) throws -> Gemma4ShortState {
        let snapshot = try session.snapshot(includeBytes: true, check: check)
        guard snapshot.committedTokens == 33 else { throw ProbeError("Gemma final snapshot frontier differs") }
        var entries: [Gemma4ShortState.Entry] = []
        for entry in snapshot.entries {
            guard let bytes = entry.bytes, bytes.count == entry.byteCount, sha256(bytes) == entry.sha256 else {
                throw ProbeError("Gemma actual snapshot lacks exact logical bytes")
            }
            let file = try sidecars.write("state-\(entry.globalLayerIndex)-\(entry.component).bin", data: bytes, check: check)
            entries.append(.init(localLayerIndex: entry.localLayerIndex, globalLayerIndex: entry.globalLayerIndex,
                component: entry.component, dtype: entry.dtype, sha256: entry.sha256, shape: entry.shape,
                byteCount: entry.byteCount, logicalRange: entry.logicalRange.map { [$0.lowerBound, $0.upperBound] } ?? [], file: file))
        }
        return .init(frontier: snapshot.committedTokens, fingerprint: snapshot.fingerprint, entries: entries)
    }
}
