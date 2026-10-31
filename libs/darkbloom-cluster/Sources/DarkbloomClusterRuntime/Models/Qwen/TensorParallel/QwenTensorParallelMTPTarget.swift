import Foundation
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
    /// A deferred check that the window's tokens lie in the vocabulary
    /// (`deferTokenRangeCheck`), evaluated with the window, read in `confirm`.
    private var pendingTokenRange: MLXArray?
    var isIdle: Bool { !failed && window == nil }

    /// The caller vouches for a window's tokens (the assistant's drafts, an
    /// argmax over the vocabulary rows that both ranks read from the same
    /// exchange) and has not evaluated them yet: their range check is
    /// evaluated with the window and read in `confirm` instead of
    /// synchronizing on the drafts before the window can be built. Every
    /// rank derives the same drafts, so a refusal is the same on both.
    @TaskLocal static var deferTokenRangeCheck = false

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
                let deferred = Self.deferTokenRangeCheck
                let inRange = all((tokens .>= 0) .&& (tokens .< model.plan.vocabularySize))
                guard tokens.ndim == 2, tokens.dim(0) == 1, tokens.dtype == .int32,
                      (1...5).contains(count), state.committedTokens == offset,
                      offset >= request.promptCount, count <= request.maximumTokens - offset,
                      deferred || inRange.item(Bool.self) else {
                    throw ProbeError("Qwen TP MTP verify window differs from its committed frontier")
                }
                try error.check()
                let stride = Self.layerStride(packed: state.packedStorage)
                let built = try state.beginWindow(tokenCount: count) { caches, evaluation in
                    let result = Qwen35LayerSubmission.$stride.withValue(stride) {
                        self.model.model.cbv2ForwardWithHiddenCaptured(tokens,
                            caches: caches.map { $0 as! any KVCache }, recurrentState: [evaluation], positionIds: nil)
                    }
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
                if deferred {
                    pendingTokenRange = inRange
                    return (outputs: built.outputs, roots: built.roots + [inRange])
                }
                return built
            }
        } catch { failed = true; throw error }
    }

    /// A window's forward is submitted to the GPU layer by layer, as a decode
    /// step's is (`QwenTensorParallelBatchSession.decodeLayerStride`): the GPU
    /// and the collectives run the layers already built while the host builds
    /// the rest, instead of idling for the whole graph construction.
    /// Evaluation order only: every primitive, input and rounded value is the
    /// one the whole-window evaluation computes, and each submission holds its
    /// layers' collectives in layer order on every rank. A packed-storage
    /// window is evaluated whole (its refused writes are checked after the
    /// graph is built and before any of it runs, `checkStepWrites`).
    static func layerStride(packed: Bool) -> Int {
        QwenTensorParallelBatchSession.layerStride
            ?? (packed || !submitsByLayer ? 0 : QwenTensorParallelBatchSession.decodeLayerStride)
    }

    /// Verify windows are evaluated whole by default. On two M5 Ultra 256 GB
    /// serving the 27B pair with the main-merged MLX core, layer-by-layer
    /// submission (an `asyncEval` after every decoder layer) made a solo
    /// request 15 % slower (51 against 60 tok/s) and four concurrent requests
    /// 5 % slower (90 against 95 tok/s aggregate), with identical outputs.
    /// Diagnostic only: `DARKBLOOM_QWEN_TP_WINDOW_LAYER_SUBMISSION=1` submits
    /// windows by layer again, for an A/B on the pair. An installed owner never
    /// forwards it to a rank; both ranks bind the choice into their load
    /// agreement (`agreementFields`), so a pair never mixes them. Evaluation
    /// order only: the same values.
    static let submitsByLayer =
        ProcessInfo.processInfo.environment["DARKBLOOM_QWEN_TP_WINDOW_LAYER_SUBMISSION"] == "1"

    /// Bound into the tensor-parallel load agreement.
    static var agreementFields: [String] {
        ["qwen-tensor-parallel-window-submission-v1", submitsByLayer ? "by-layer" : "whole"]
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
                let stride = layerStride(packed: windows.contains { $0.state.packedStorage })
                let built = try CBv2OwnedRequestState.beginBatchWindow(windows.map(\.state), tokenCount: count) { caches, evaluations in
                    let result = Qwen35BatchDecodeScope.$enabled.withValue(true) {
                        Qwen35BatchDecodeScope.$verifyRows.withValue(true) {
                            Qwen35LayerSubmission.$stride.withValue(stride) {
                                first.model.model.cbv2ForwardWithHiddenCaptured(tokens,
                                    caches: caches.map { $0 as! any KVCache }, recurrentState: evaluations, positionIds: nil)
                            }
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
                if let range = pendingTokenRange {
                    // Evaluated with the window's roots: no wait.
                    pendingTokenRange = nil
                    guard range.item(Bool.self) else {
                        throw ProbeError("Qwen TP MTP drafted tokens fall outside the vocabulary")
                    }
                }
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
