import MLX
import MLXLMCommon

/// Prefix tails may be a whole sliding window, longer than one legal page
/// write. Restore their original chronological positions in bounded writes.
enum CBv2PagedPrefixRestore {
    enum Failure: Error { case invalidShapeOrChunk }

    static func write(row: any CBv2SequenceKV, keys: MLXArray, values: MLXArray,
                      maximumChunkTokens: Int) throws {
        guard maximumChunkTokens > 0, keys.ndim == 4, keys.dim(0) == 1,
              values.shape == keys.shape, values.dtype == keys.dtype else {
            throw Failure.invalidShapeOrChunk
        }
        var offset = 0
        while offset < keys.dim(2) {
            let end = offset + min(maximumChunkTokens, keys.dim(2) - offset)
            _ = row.update(keys: keys[0..., 0..., offset..<end, 0...],
                           values: values[0..., 0..., offset..<end, 0...])
            offset = end
        }
    }
}
