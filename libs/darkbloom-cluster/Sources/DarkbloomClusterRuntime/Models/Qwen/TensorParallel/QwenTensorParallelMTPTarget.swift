import MLX
import MLXLLM
import MLXLMCommon

struct QwenTensorParallelMTPPromptResult {
    let hidden: MLXArray
    let logits: MLXArray?
}

/// Speculation borrows the same request-owned target history used by ordinary
/// batching. Implementations retain their own schedule and retirement fence;
/// an assistant never creates a second target cache for a live request.
protocol QwenTensorParallelMTPTarget: AnyObject {
    var model: QwenTensorParallelModel { get }
    var request: QwenLayerStageGenerationRequest { get }
    var state: CBv2OwnedRequestState { get }
    var retired: Bool { get }
    func prefillForMTP(check: () throws -> Void) throws -> QwenTensorParallelMTPPromptResult
    func beginWindow(tokens: MLXArray, offset: Int) throws -> (outputs: [MLXArray], roots: [MLXArray])
    func confirmWindow(check: () throws -> Void) throws
    func settleWindow(keeping: Int) throws -> [MLXArray]
    func confirmSettled(check: () throws -> Void) throws
    func retire() throws
}

/// The captured target transaction is identical for the explicit singleton
/// owner and the resident batch owner. This object owns no additional history:
/// it operates on the session's existing CBv2 state and reports the settled
/// range only after evaluation and rollback have both been confirmed.
final class QwenTensorParallelTargetWindow {
    private let model: QwenTensorParallelModel
    private let request: QwenLayerStageGenerationRequest
    private let state: CBv2OwnedRequestState
    private var window: (offset: Int, count: Int, kept: Int?)?
    private var failed = false
    var isIdle: Bool { !failed && window == nil }

    init(model: QwenTensorParallelModel, request: QwenLayerStageGenerationRequest,
         state: CBv2OwnedRequestState) {
        self.model = model; self.request = request; self.state = state
    }

    func begin(tokens: MLXArray, offset: Int) throws -> (outputs: [MLXArray], roots: [MLXArray]) {
        do {
            return try MLX.withError { error in
                guard isIdle, request.qwenMedia == nil else { throw ProbeError("Qwen TP MTP window is unfinished or has media") }
                try state.requireOpen()
                let count = tokens.ndim == 2 ? tokens.dim(1) : 0
                guard tokens.ndim == 2, tokens.dim(0) == 1, tokens.dtype == .int32,
                      (1...5).contains(count), state.committedTokens == offset,
                      offset >= request.promptCount, count <= request.maximumTokens - offset,
                      all((tokens .>= 0) .&& (tokens .< model.plan.vocabularySize)).item(Bool.self) else {
                    throw ProbeError("Qwen TP MTP verify window differs from its committed frontier")
                }
                try error.check()
                let built = try state.beginWindow(tokenCount: count) { caches, evaluation in
                    let result = self.model.model.cbv2ForwardWithHiddenCaptured(tokens,
                        caches: caches.map { $0 as! any KVCache }, recurrentState: [evaluation], positionIds: nil)
                    return [result.logits, result.lastHidden]
                }
                guard built.outputs.count == 2,
                      built.outputs[0].shape == [1, count, model.vocabularyRange.count],
                      String(describing: built.outputs[0].dtype) == request.profile.selectedRowDType,
                      built.outputs[1].shape == [1, count, model.plan.hiddenSize],
                      String(describing: built.outputs[1].dtype) == request.profile.activationDType else {
                    throw ProbeError("Qwen TP MTP captured target output contract differs")
                }
                try error.check(); window = (offset, count, nil)
                return built
            }
        } catch { failed = true; throw error }
    }

    /// A single target forward owns all rows; the assistant's draft state is
    /// still request-local and is not batched by this seam.
    static func beginBatch(_ windows: [QwenTensorParallelTargetWindow], tokens: MLXArray,
                           offsets: [Int]) throws -> (outputs: [MLXArray], roots: [MLXArray]) {
        do {
            return try MLX.withError { error in
                guard let first = windows.first, (1...8).contains(windows.count),
                      Set(windows.map { ObjectIdentifier($0) }).count == windows.count,
                      offsets.count == windows.count,
                      windows.allSatisfy({ $0.model === first.model && $0.isIdle && $0.request.qwenMedia == nil }),
                      tokens.ndim == 2, tokens.dim(0) == windows.count, tokens.dtype == .int32,
                      (1...5).contains(tokens.dim(1)),
                      all((tokens .>= 0) .&& (tokens .< first.model.plan.vocabularySize)).item(Bool.self) else {
                    throw ProbeError("Qwen TP batched verify window differs from its request cohort")
                }
                let count = tokens.dim(1)
                for (window, offset) in zip(windows, offsets) {
                    guard window.state.committedTokens == offset, offset >= window.request.promptCount,
                          count <= window.request.maximumTokens - offset,
                          window.request.profile.activationDType == first.request.profile.activationDType,
                          window.request.profile.selectedRowDType == first.request.profile.selectedRowDType else {
                        throw ProbeError("Qwen TP batched verify row differs from its admitted frontier")
                    }
                }
                try error.check()
                // Each row keeps the arithmetic of its own single-request window
                // (decode columns too): quantized matmul picks its kernel from the
                // total row count, so one B·S product changes reduction order
                // once it reaches a device's vector limit.
                let built = try CBv2OwnedRequestState.beginBatchWindow(windows.map(\.state), tokenCount: count) { caches, evaluations in
                    let result = Qwen35BatchDecodeScope.$enabled.withValue(true) {
                        Qwen35BatchDecodeScope.$verifyRows.withValue(true) {
                            first.model.model.cbv2ForwardWithHiddenCaptured(tokens,
                                caches: caches.map { $0 as! any KVCache }, recurrentState: evaluations, positionIds: nil)
                        }
                    }
                    return [result.logits, result.lastHidden]
                }
                guard built.outputs.count == 2,
                      built.outputs[0].shape == [windows.count, count, first.model.vocabularyRange.count],
                      String(describing: built.outputs[0].dtype) == first.request.profile.selectedRowDType,
                      built.outputs[1].shape == [windows.count, count, first.model.plan.hiddenSize],
                      String(describing: built.outputs[1].dtype) == first.request.profile.activationDType else {
                    throw ProbeError("Qwen TP batched captured output contract differs")
                }
                try error.check()
                for (window, offset) in zip(windows, offsets) { window.window = (offset, count, nil) }
                return built
            }
        } catch { windows.forEach { $0.failed = true }; throw error }
    }

    static func confirmBatch(_ windows: [QwenTensorParallelTargetWindow], check: () throws -> Void) throws {
        do {
            guard windows.allSatisfy({ !$0.failed && $0.window != nil }) else {
                throw ProbeError("Qwen TP batched target has no live verification window")
            }
            try CBv2OwnedRequestState.confirmBatchWindow(windows.map(\.state), check: check)
        } catch { windows.forEach { $0.failed = true }; throw error }
    }

    static func settleBatch(_ windows: [QwenTensorParallelTargetWindow], keeping kept: [Int]) throws -> [MLXArray] {
        do {
            guard windows.count == kept.count,
                  windows.allSatisfy({ !$0.failed && $0.window != nil && $0.window?.kept == nil }) else {
                throw ProbeError("Qwen TP batched target cannot settle its request prefixes")
            }
            let roots = try CBv2OwnedRequestState.settleBatchWindow(windows.map(\.state), keeping: kept)
            for (window, count) in zip(windows, kept) {
                let current = window.window!
                window.window = (current.offset, current.count, count)
            }
            return roots
        } catch { windows.forEach { $0.failed = true }; throw error }
    }

    static func confirmBatchSettled(_ windows: [QwenTensorParallelTargetWindow],
                                    check: () throws -> Void) throws -> [Range<Int>] {
        do {
            let ranges = try windows.map { window -> Range<Int> in
                guard !window.failed, let current = window.window, let kept = current.kept else {
                    throw ProbeError("Qwen TP batched target has no settled request prefix")
                }
                return current.offset..<(current.offset + kept)
            }
            try CBv2OwnedRequestState.confirmBatchSettled(windows.map(\.state), check: check)
            windows.forEach { $0.window = nil }
            return ranges
        } catch { windows.forEach { $0.failed = true }; throw error }
    }

    func confirm(check: () throws -> Void) throws {
        do {
            try MLX.withError { error in
                guard !failed, window != nil else { throw ProbeError("Qwen TP MTP has no open window") }
                try state.confirmWindow(check: { try error.check(); try check() })
            }
        } catch { failed = true; throw error }
    }

    func settle(keeping kept: Int) throws -> [MLXArray] {
        do {
            return try MLX.withError { error in
                guard !failed, let current = window, current.kept == nil,
                      (1...current.count).contains(kept) else { throw ProbeError("Qwen TP MTP kept prefix is invalid") }
                let roots = try state.settleWindow(keeping: kept)
                try error.check(); window = (current.offset, current.count, kept)
                return roots
            }
        } catch { failed = true; throw error }
    }

    func confirmSettled(check: () throws -> Void) throws -> Range<Int> {
        do {
            return try MLX.withError { error in
                guard !failed, let current = window, let kept = current.kept else {
                    throw ProbeError("Qwen TP MTP has no settled prefix")
                }
                try state.confirmSettled(check: { try error.check(); try check() })
                let range = current.offset..<(current.offset + kept)
                window = nil
                return range
            }
        } catch { failed = true; throw error }
    }
}
