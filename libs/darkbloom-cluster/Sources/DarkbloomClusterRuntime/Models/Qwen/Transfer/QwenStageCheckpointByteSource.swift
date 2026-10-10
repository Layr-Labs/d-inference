import Foundation
import MLX

/// The sending rank's bytes: one planned piece at a time from its verified
/// artifact, through the descriptor that was hashed. It holds one piece in host
/// memory and one as an array; it never materializes a stage.
struct QwenStageCheckpointByteSource: QwenStageTransferByteSource {
    let checkpoint: VerifiedCheckpoint

    func bytes(_ piece: QwenStageTransferPlan.Piece, file: String, offset: Int) throws -> Data {
        guard let stored = checkpoint.files[file] else {
            throw ProbeError("Stage transfer source file is not in the verified checkpoint")
        }
        var data = Data(count: piece.byteCount)
        try data.withUnsafeMutableBytes { _ = try stored.read(into: $0, offset: offset) }
        return data
    }

    func read(_ piece: QwenStageTransferPlan.Piece, file: String, offset: Int) throws -> MLXArray {
        MLXArray(try bytes(piece, file: file, offset: offset), piece.shape, dtype: piece.dtype.native)
    }

    func placeholder(_ piece: QwenStageTransferPlan.Piece) throws -> MLXArray {
        MLXArray.zeros(piece.shape, dtype: piece.dtype.native)
    }
}
