import Foundation
import MLX

/// One selected token of a recorded speculative pipeline (`pipeline_mtp_v1`),
/// as rank 1 took it: the row it was selected from (the prompt's last frame
/// for the first token, then the kept column of a verify window), that row's
/// digest over its native bytes and its highest candidates with their exact
/// values. The fields are the qualification step's (`QualificationStep`), so
/// a pair's record carries its accepted timeline row by row: tokens are
/// judged against the single-Mac reference by the near-tie rule, and with
/// equal tokens each row's digest tells an exact row from a different one.
/// Drafts the target rejected are not steps: only accepted tokens are.
struct QwenRecordedStep: Encodable, Equatable {
    static let candidateCount = 4

    let ordinal: Int
    let frameSequence: Int
    let committedTokens: Int
    let tokenID: Int
    /// Highest first; equal values in ascending token order.
    let topTokenIDs: [Int]
    /// Exact float32 widenings of the native values.
    let topLogits: [Float]
    /// How many of the candidates hold the row's highest value.
    let maximumTieCount: Int
    let rowSHA256: String
    let rowDType: String

    init(ordinal: Int, frameSequence: Int, committedTokens: Int, tokenID: Int, rowBytes: Data, rowDType: String,
         sampled: Bool) throws {
        let top = try MiMoStepEvidence.candidates(rowBytes: rowBytes, dtype: rowDType, count: Self.candidateCount)
        guard ordinal >= 0, frameSequence >= 0, committedTokens > 0, top.count >= 2,
              top.allSatisfy({ $0.logit.isFinite }) else {
            throw ProbeError("Recorded step row has fewer than two finite candidates")
        }
        // A greedy token is its row's top candidate; a sampled one is a draw.
        guard sampled || top[0].tokenID == tokenID else {
            throw ProbeError("Recorded step row differs from the agreed target token")
        }
        self.ordinal = ordinal; self.frameSequence = frameSequence; self.committedTokens = committedTokens
        self.tokenID = tokenID; topTokenIDs = top.map(\.tokenID); topLogits = top.map(\.logit)
        maximumTieCount = top.filter { $0.logit == top[0].logit }.count
        rowSHA256 = sha256(rowBytes); self.rowDType = rowDType
    }

    /// From a [1, vocabulary] row in its native dtype (a verify window's
    /// column or a frame's last row).
    init(_ row: MLXArray, ordinal: Int, frame: QwenLayerStageFrame, tokenID: Int, vocabularySize: Int,
         rowDType: String, sampled: Bool) throws {
        guard row.shape == [1, vocabularySize], String(describing: row.dtype) == rowDType else {
            throw ProbeError("Recorded step row differs from one native vocabulary row of the profile's dtype")
        }
        let bytes = row.asData(access: .copy).data
        guard bytes.count == vocabularySize * row.dtype.size else { throw ProbeError("Recorded step row byte count differs") }
        try self.init(ordinal: ordinal, frameSequence: frame.sequence, committedTokens: frame.tokenOffset + frame.tokenCount,
            tokenID: tokenID, rowBytes: bytes, rowDType: rowDType, sampled: sampled)
    }
}
