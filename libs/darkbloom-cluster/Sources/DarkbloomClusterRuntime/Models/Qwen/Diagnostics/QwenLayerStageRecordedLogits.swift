import Foundation
import MLX

/// Encoded values are finite Float32 conversions of the entire vocabulary row.
/// Exact comparison uses the original logical bytes, including signed zeros.
struct QwenRecordedLogitValues: Encodable {
    let shape: [Int]
    let dtype: String
    let byteCount: Int
    let logicalBytesSHA256: String
    let values: [Float]
}

/// CPU storage only. No MLXArray, no-copy Data, or lazy graph escapes capture.
/// The native Data remains private and is deliberately omitted from encoding.
struct QwenRecordedLogits: Encodable {
    let record: QwenRecordedLogitValues
    private let logicalBytes: Data

    init(_ array: MLXArray, vocabularySize: Int, check: () throws -> Void) throws {
        guard (1...262_144).contains(vocabularySize), array.shape == [1, vocabularySize],
              array.size == vocabularySize, [.float16, .bfloat16, .float32].contains(array.dtype),
              array.nbytes == vocabularySize * array.dtype.size else {
            throw ProbeError("Recorded logits require one complete bounded native vocabulary row")
        }
        // Caller's MLX scope owns fault handling around these native reads.
        let bytes = array.asData(access: .copy).data
        try check()
        guard bytes.count == array.nbytes else { throw ProbeError("Recorded logit byte count differs") }
        let floating = array.asType(.float32)
        eval(floating)
        try check()
        let values = floating.asArray(Float.self)
        try check()
        guard values.count == vocabularySize, values.allSatisfy(\.isFinite) else {
            throw ProbeError("Recorded full-vocabulary logits contain nonfinite or missing values")
        }
        self.logicalBytes = bytes
        self.record = .init(shape: array.shape, dtype: String(describing: array.dtype),
            byteCount: bytes.count, logicalBytesSHA256: sha256(bytes), values: values)
    }

    func requireExact(_ candidate: QwenRecordedLogits, frontier: Int) throws {
        guard record.shape == candidate.record.shape, record.dtype == candidate.record.dtype,
              record.byteCount == candidate.record.byteCount,
              record.logicalBytesSHA256 == candidate.record.logicalBytesSHA256,
              logicalBytes == candidate.logicalBytes else {
            throw ProbeError("Recorded native full-vocabulary logits differ at frontier \(frontier)")
        }
    }

    func encode(to encoder: Encoder) throws { try record.encode(to: encoder) }

    /// Compare a final-only observation without converting its whole vocabulary
    /// to Float32 JSON. Both values retain independently copied CPU bytes.
    func requireExactNativeBytes(shape: [Int], dtype: String, bytes: Data, frontier: Int) throws {
        guard record.shape == shape, record.dtype == dtype, record.byteCount == bytes.count,
              record.logicalBytesSHA256 == sha256(bytes), logicalBytes == bytes else {
            throw ProbeError("Recorded native full-vocabulary logits differ at frontier \(frontier)")
        }
    }
}
