import MLX

/// Only the final-rank forwarding seam is shared. The original one-proposal
/// hook, ordinary generation and accepted-round driver retain separate owners.
protocol QwenGenerationHistoryOwner {
    func forward(tokens: [Int], frame: QwenLayerStageFrame,
                 incoming: QwenLayerStageBoundary, check: () throws -> Void) throws -> QwenLayerStageOutput
}
extension QwenLayerStageMTPProbe: QwenGenerationHistoryOwner {}
