import MLX

/// Native-only consumable capture. Construction follows actual local state and
/// schedule commit; the MTP owner separately requires both frame acknowledgements.
final class QwenLayerStageMTPCommittedFrame {
    let identity: QwenLayerStageSessionIdentity
    let frame: QwenLayerStageFrame
    let tokenIDs: [Int]
    private var hidden: MLXArray?

    fileprivate init(identity: QwenLayerStageSessionIdentity, frame: QwenLayerStageFrame,
                     tokens: [Int], hidden: MLXArray) {
        self.identity = identity; self.frame = frame; tokenIDs = tokens; self.hidden = hidden
    }
    func takeHidden() throws -> MLXArray {
        guard let hidden else { throw ProbeError("MTP committed hidden was already consumed") }
        self.hidden = nil
        return hidden
    }
    func discard() { hidden = nil }
}

struct QwenLayerStageMTPOutput {
    let output: QwenLayerStageOutput
    let committed: QwenLayerStageMTPCommittedFrame
}

final class QwenLayerStageMTPCapture {
    private let shape: [Int]
    private let dtype: DType
    private var hidden: MLXArray?
    var evaluationTargets: [MLXArray] { hidden.map { [$0] } ?? [] }

    init(tokens: Int, hiddenSize: Int, dtype: DType) {
        shape = [1, tokens, hiddenSize]; self.dtype = dtype
    }
    func stage(_ value: MLXArray) throws {
        guard hidden == nil else { throw ProbeError("MTP capture staged more than one target forward") }
        hidden = value
        try validate()
    }
    func validate() throws {
        guard let hidden, hidden.shape == shape, hidden.dtype == dtype else {
            throw ProbeError("MTP pre-norm capture shape/dtype differs from the final target")
        }
    }
    func takeCommitted(identity: QwenLayerStageSessionIdentity, frame: QwenLayerStageFrame,
                       tokens: [Int], nativeCommittedTokens: Int) throws -> QwenLayerStageMTPCommittedFrame {
        try validate()
        guard identity.stageIndex == 1, nativeCommittedTokens == frame.tokenOffset + frame.tokenCount,
              tokens.count == frame.tokenCount else { throw ProbeError("MTP capture lacks actual final-rank commit") }
        let value = QwenLayerStageMTPCommittedFrame(identity: identity, frame: frame, tokens: tokens, hidden: hidden!)
        hidden = nil
        return value
    }
    func discard() { hidden = nil }
}
