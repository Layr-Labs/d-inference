import Foundation
import MLX

/// A sender that is wrong in exactly one way, so a check can show the receiver refuses it.
struct QwenStageFaultyByteSource: QwenStageTransferByteSource {
    enum Fault {
        case flippedBit(piece: Int)
        case truncated(piece: Int)
        /// Stored location to serve in place of another, keyed by `file|offset`.
        case substituted([String: (file: String, offset: Int)])
    }
    let source: QwenStageCheckpointByteSource
    let fault: Fault

    func read(_ piece: QwenStageTransferPlan.Piece, file: String, offset: Int) throws -> MLXArray {
        switch fault {
        case .flippedBit(let index) where index == piece.index:
            var data = try source.bytes(piece, file: file, offset: offset)
            data[data.startIndex] ^= 1
            return MLXArray(data, piece.shape, dtype: piece.dtype.native)
        case .truncated(let index) where index == piece.index:
            return try source.read(piece, file: file, offset: offset)[0 ..< (piece.shape[0] - 1)]
        case .substituted(let other):
            let location = other["\(file)|\(offset)"] ?? (file, offset)
            return try source.read(piece, file: location.file, offset: location.offset)
        default:
            return try source.read(piece, file: file, offset: offset)
        }
    }

    func placeholder(_ piece: QwenStageTransferPlan.Piece) throws -> MLXArray { try source.placeholder(piece) }
}
