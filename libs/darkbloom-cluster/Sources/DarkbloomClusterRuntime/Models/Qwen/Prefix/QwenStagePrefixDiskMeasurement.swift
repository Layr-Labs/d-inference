import Foundation
import MLX

/// What a prompt-prefix record of one state stores, and gives back, under an
/// encoding: measured in memory with the writer's and the reader's own unit
/// code (`QwenStagePrefixDiskJob.attentionPlaintext`,
/// `QwenStagePrefixDiskRestoreWork.place`), so the restored arrays are those a
/// restore of the record's deepest frontier adopts. No file, key or tier.
///
/// Per attention entry: the rows stored encoded, the largest, mean and root
/// mean square absolute error of the restored rows against the captured ones
/// over those rows (the newest rows are copied and stay exact), the largest
/// captured magnitude there (the error's scale), and the entry's bytes stored
/// against a native record's. For measurements on real weights
/// (`QwenTensorParallelModel.generateAfterPrefixRecord`, the tensor-parallel
/// check's `--prefix-records`) and the tier's tests.
public struct QwenStagePrefixDiskMeasurement: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let layer: Int
        public let kind: String
        public let dtype: String
        public let heads: Int
        public let width: Int
        /// Rows of each head stored encoded (0: a native entry).
        public let encodedRows: Int
        public let maxAbsError: Double
        public let meanAbsError: Double
        public let rmsError: Double
        public let maxAbsValue: Double
        /// Whether every row from `encodedRows` on came back bit for bit.
        public let bandExact: Bool
        public let nativeBytes: Int
        public let storedBytes: Int
    }
    /// `QwenStagePrefixDiskEncoding.description` and its family.
    public let encoding: String
    public let family: String
    public let committedTokens: Int
    public let blockTokens: Int
    public let entries: [Entry]
    /// Attention plaintext bytes as stored, and as a native record stores them.
    public let attentionBytes: Int
    public let nativeAttentionBytes: Int
    /// Every sealed unit of the record (attention, recurrent, history, with
    /// their tags), and of a native record of the same state.
    public let recordDataBytes: Int
    public let nativeRecordDataBytes: Int
    /// Wall time to encode and decode every attention unit.
    public let seconds: Double

    /// Measures `state` (its attention rows at `committedTokens`, its
    /// recurrent state and history kept native) stored under `encoding` in
    /// units of `blockTokens` rows. Returns the measurement and the state a
    /// restore gives back: decoded attention, the same recurrent arrays and
    /// history (a native unit is a byte copy).
    static func measure(_ state: QwenStagePrefixState, encoding: QwenStagePrefixDiskEncoding,
                        blockTokens: Int) throws -> (measurement: Self, restored: QwenStagePrefixState) {
        let started = DispatchTime.now().uptimeNanoseconds
        let job = try QwenStagePrefixDiskJob.prepare(scope: "measurement", recordKey: "measurement", fileName: "measurement",
            rank: 0, deepest: state, frontiers: [(state, "measurement")], blockTokens: blockTokens, encoding: encoding)
        let native = encoding == .native ? job : try QwenStagePrefixDiskJob.prepare(scope: "measurement",
            recordKey: "measurement", fileName: "measurement", rank: 0, deepest: state, frontiers: [(state, "measurement")],
            blockTokens: blockTokens)
        let header = job.header, committed = header.committedTokens, b = header.blockTokens
        let buffers = try header.attention.map { item in
            try QwenStagePrefixRestoreBuffer(bytes: item.heads * committed * item.headDim * QwenStagePrefixDiskFormat.dtypes[item.dtype]!.size)
        }
        // Every unit is encoded and decoded independently, as the writer and
        // a restore do; their buffers are disjoint.
        let work = header.attention.indices.flatMap { entry in header.attention[entry].units.indices.map { (entry, $0) } }
        final class Failure: @unchecked Sendable { let lock = NSLock(); var error: Error? }
        let failure = Failure()
        DispatchQueue.concurrentPerform(iterations: work.count) { index in
            let (entry, block) = work[index]
            let item = header.attention[entry], first = block * b
            do {
                let plain = try job.attentionPlaintext(entry: entry, block: block)
                try plain.withUnsafeBytes { source in
                    try QwenStagePrefixDiskRestoreWork.place(source, into: buffers[entry].pointer, rows: job.encodedRows[entry],
                        heads: item.heads, rowBytes: item.headDim * QwenStagePrefixDiskFormat.dtypes[item.dtype]!.size,
                        frontier: committed, first: first, count: min(b, committed - first))
                }
            } catch {
                failure.lock.withLock { if failure.error == nil { failure.error = error } }
            }
        }
        if let error = failure.error { throw error }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        var attention: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        var keys: [Int: MLXArray] = [:]
        var entries: [Entry] = []
        for (entry, item) in header.attention.enumerated() {
            let dtype = QwenStagePrefixDiskFormat.dtypes[item.dtype]!
            let restored = buffers[entry].array([1, item.heads, committed, item.headDim], dtype: dtype)
            guard let pair = state.attention[item.layer] else { throw ProbeError("Prefix measurement lost a layer") }
            let original = item.kind == "keys" ? pair.keys : pair.values
            let encodedRows = item.nativeFrom ?? 0
            var maxError = 0.0, meanError = 0.0, rmsError = 0.0, maxValue = 0.0
            if encodedRows > 0 {
                let captured = original[0..., 0..., 0 ..< encodedRows, 0...].asType(.float32)
                let difference = abs(restored[0..., 0..., 0 ..< encodedRows, 0...].asType(.float32) - captured)
                let summary = [difference.max(), difference.mean(), (difference * difference).mean().sqrt(), abs(captured).max()]
                eval(summary)
                maxError = Double(summary[0].item(Float.self)); meanError = Double(summary[1].item(Float.self))
                rmsError = Double(summary[2].item(Float.self)); maxValue = Double(summary[3].item(Float.self))
            }
            var bandExact = true
            if encodedRows < committed {
                bandExact = MLX.arrayEqual(restored[0..., 0..., encodedRows..., 0...], original[0..., 0..., encodedRows..., 0...])
                    .item(Bool.self)
            }
            let tag = QwenStagePrefixDiskFormat.tagBytes
            entries.append(.init(layer: item.layer, kind: item.kind, dtype: item.dtype, heads: item.heads, width: item.headDim,
                encodedRows: encodedRows, maxAbsError: maxError, meanAbsError: meanError, rmsError: rmsError,
                maxAbsValue: maxValue, bandExact: bandExact,
                nativeBytes: item.heads * committed * item.headDim * dtype.size,
                storedBytes: item.units.reduce(0) { $0 + $1.length - tag }))
            if item.kind == "keys" { keys[item.layer] = restored }
            else if let key = keys.removeValue(forKey: item.layer) { attention[item.layer] = (keys: key, values: restored) }
        }
        var restored = QwenStagePrefixState(committedTokens: committed, attention: attention, recurrent: state.recurrent)
        restored.speculativeHistory = state.speculativeHistory
        let measurement = Self(encoding: encoding.description, family: encoding.family.rawValue, committedTokens: committed,
            blockTokens: b, entries: entries, attentionBytes: job.attentionBytes, nativeAttentionBytes: job.nativeAttentionBytes,
            recordDataBytes: header.dataBytes, nativeRecordDataBytes: native.header.dataBytes, seconds: seconds)
        return (measurement, restored)
    }

    /// The largest error over every encoded entry of `kind` (nil: none).
    public func maxAbsError(kind: String) -> Double? {
        entries.filter { $0.kind == kind && $0.encodedRows > 0 }.map(\.maxAbsError).max()
    }
}
