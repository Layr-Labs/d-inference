import Foundation

/// The attention transient of one prefill frame on a stage that holds at least
/// one full-attention layer: the bytes a frame of `chunkTokens` queries needs
/// beside the KV it attends over. The owner's planner reserves this beside the
/// KV of every stage (oMLX `_sdpa_transient_for_stage`, U#3651: without it,
/// head dimension 256 models were oversold by about a quarter) and his prefill
/// guard prices it with the same formula.
///
/// MLX's fused full-attention kernel takes head dimensions 64, 72, 80, 96 and
/// 128. Any other (the dense Qwen's 256) takes the unfused path, which
/// materializes the `[query heads, queries, keys]` score matrix in float32
/// beside a float32 output. Query blocking (`DARKBLOOM_CBV2_ATTN_QUERY_BLOCK`)
/// bounds the matrix per block, but blocks of one frame may be evaluated
/// together, so the whole frame is priced: an upper bound, not a measurement.
/// Prefill layers run one after another under the rank's command-buffer
/// limits, so one layer's transient is the frame's. A decode step's command
/// buffers (`QwenLayerStageSession.decodeCommandBuffers`) can keep every
/// attending layer's temporaries alive at once: `decodeRows` is the number of
/// such rows, each layer's decode rows added up, priced as score rows over
/// the whole context, and the larger of the two is charged.
enum QwenResidentPrefillTransient {
    static let fusedHeadDimensions: Set<Int> = [64, 72, 80, 96, 128]
    static let scoreElementBytes = 4
    static let outputElementBytes = 4

    static func bytes(geometry g: QwenLongPrefillBudgetGeometry, stageHasAttention: Bool,
                      chunkTokens: Int, contextTokens: Int, decodeRows: Int = 0) throws -> Int {
        guard chunkTokens > 0, contextTokens > 0, decodeRows >= 0 else {
            throw QwenLongPrefillBudgetError.invalid("Attention transient needs a positive frame and context")
        }
        let product = QwenLongPrefillCheckedBytes.product
        let queries = max(stageHasAttention ? min(chunkTokens, contextTokens) : 0, decodeRows)
        guard queries > 0 else { return 0 }
        let output = try product([g.queryHeads, queries, g.headDimension, outputElementBytes])
        if fusedHeadDimensions.contains(g.headDimension) { return output }
        let scores = try product([g.queryHeads, queries, contextTokens, scoreElementBytes])
        return try QwenLongPrefillCheckedBytes.sum([scores, output])
    }
}
