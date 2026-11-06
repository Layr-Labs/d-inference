import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// The raw all-sums the row-parallel projections of one wavefront phase issued
/// (`QwenTensorParallelRowLinear.issuedSums`). Confined to the thread that
/// builds the forward, which binds it and drains it after each phase.
final class QwenTensorParallelIssuedSums: @unchecked Sendable {
    var sums: [MLXArray] = []
}

/// Consecutive prompt frames of one plain text lane prefilled as one graph,
/// layer by layer (`Qwen35PromptWavefront`): a frame's mixer, its sealed sum
/// submitted at once, the next frame's mixer while that sum crosses the link;
/// then the MLPs the same way. At each layer a frame reads the attention rows
/// and the recurrent state the frame before it left, so every kernel sees the
/// frame's own rows: logits, KV rows, conv and SSM states are the per-frame
/// prefill's bytes, and each rank issues the same sums (two a layer a frame)
/// in the same order. Only when the GPU and the link run each piece changes.
enum QwenTensorParallelPromptWavefront {
    /// Frames one prompt step runs at most: 8 x 512 = 4,096 tokens a graph.
    static let maximumFrames = 8
    /// Frames one prompt step runs while another lane decodes, so a decoding
    /// lane waits for one merged step about as long as for one frame alone.
    static let framesBesideDecoding = 2
    /// Unfinished sums a step keeps submitted: building waits for the oldest
    /// beyond them. Unbounded, MLX encodes (and allocates) up to
    /// `MLX_MAX_ACTIVE_TASKS` tasks of independent frames ahead, beyond
    /// `inFlightBytes`. Evaluation order only: the sums and their order are unchanged.
    static let sumsInFlight = 4
    /// Diagnostic only: `DARKBLOOM_QWEN_TP_PROMPT_WAVEFRONT=0` runs one frame a
    /// step, as before. Bound into the load agreement (`agreementFields`).
    static let enabled = ProcessInfo.processInfo.environment["DARKBLOOM_QWEN_TP_PROMPT_WAVEFRONT"] != "0"
    /// A bench or test's own choice (nil: `enabled`).
    @TaskLocal static var enabledOverride: Bool?
    static var isEnabled: Bool { enabledOverride ?? enabled }

    /// Both ranks plan and validate merged prompt steps alike, or the pair refuses to load
    /// (`assisted-merge`: assisted lanes merge too, ending at their assistant's capture frontier).
    static var agreementFields: [String] {
        ["qwen-tensor-parallel-prompt-wavefront-v1",
         isEnabled ? "frames-\(maximumFrames)-beside-decoding-\(framesBesideDecoding)-assisted-merge" : "off"]
    }

    /// The frames one prompt step runs from frame `sequence`: consecutive
    /// prompt frames, at most `limit`, ending at the prompt's end or at the
    /// first capture frontier (`frontiers`, the capture plan's boundaries)
    /// they reach. Empty when frame `sequence` is not a prompt frame.
    static func frames(request: QwenLayerStageGenerationRequest, from sequence: Int, frontiers: [Int],
                       limit: Int) -> [QwenLayerStageFrame] {
        guard let first = try? request.frame(sequence: sequence), first.phase == .prefill else { return [] }
        var frames = [first]
        while frames.count < limit, let last = frames.last, !last.finalPromptChunk,
              !frontiers.contains(last.tokenOffset + last.tokenCount),
              let next = try? request.frame(sequence: last.sequence + 1), next.phase == .prefill {
            frames.append(next)
        }
        return frames
    }

    /// What one merged step holds beyond a lone frame, charged with the
    /// owner's shared prompt workspace (`QwenTensorParallelBatchBudget`): for
    /// each further frame, its two FP32 partials and two FP32 sums in flight
    /// and its BF16 residual rows, five times the frame's collective payload,
    /// allocator-bounded. Zero for routed experts, whose frames never merge.
    static func inFlightBytes(plan: QwenTensorParallelPlan, chunkTokens: Int,
                              allocationBound: (Int) throws -> Int) throws -> Int {
        guard !plan.routedExperts else { return 0 }
        let payload = try QwenLongPrefillCheckedBytes.product([chunkTokens, plan.maximumPartialBytesPerToken])
        return try QwenLongPrefillCheckedBytes.product([allocationBound(payload), 5, maximumFrames - 1])
    }

    /// The step the driver plans and both ranks validate for `frames`: the
    /// first frame's sequence and offset, every frame's tokens, the last's final flag.
    static func step(_ frames: [QwenLayerStageFrame]) -> QwenLayerStageFrame? {
        guard let first = frames.first, let last = frames.last else { return nil }
        return .init(sequence: first.sequence, phase: .prefill, tokenOffset: first.tokenOffset,
            tokenCount: frames.reduce(0) { $0 + $1.tokenCount }, finalPromptChunk: last.finalPromptChunk)
    }

    /// Whether a lane's frames merge: text without media inputs, native rows
    /// (a packed step is checked whole before it runs), a dense model.
    static func merges(model: QwenTensorParallelModel, request: QwenLayerStageGenerationRequest,
                       mediaInputs: Bool, packedStorage: Bool) -> Bool {
        isEnabled && !mediaInputs && request.qwenMedia == nil && !packedStorage
            && Qwen35PromptWavefront.supports(model.model)
    }

    /// `frames`' forward inside one `CBv2OwnedRequestState.run`: the
    /// wavefront, each phase's sums submitted as soon as it is built (at most
    /// `sumsInFlight` unfinished); returns what the last frame's own forward
    /// returns (its evaluation handle, or the final prompt row's logits from
    /// the whole frame's head, as `QwenTensorParallelBatchSession.prompt` keeps them).
    static func forward(model: QwenTensorParallelModel, request: QwenLayerStageGenerationRequest,
                        frames: [QwenLayerStageFrame], caches: [any CBv2AttendingLayerCache],
                        evaluation: CBv2RecurrentStateEvaluation) -> MLXArray {
        forward(model: model, request: request, frames: frames, caches: caches, evaluation: evaluation,
            capturingHidden: false).output
    }

    /// `forward`, and with `capturingHidden` each frame's last decoder layer
    /// rows (`[1, frame tokens, hidden]`, its own array) from the same graph:
    /// an assisted lane's step, whose assistant takes each frame's rows.
    static func forward(model: QwenTensorParallelModel, request: QwenLayerStageGenerationRequest,
                        frames: [QwenLayerStageFrame], caches: [any CBv2AttendingLayerCache],
                        evaluation: CBv2RecurrentStateEvaluation,
                        capturingHidden: Bool) -> (output: MLXArray, hidden: [MLXArray]?) {
        let chunks = frames.map { frame in
            MLXArray(request.promptTokenIDs[frame.tokenOffset ..< (frame.tokenOffset + frame.tokenCount)]
                .map(Int32.init)).reshaped([1, frame.tokenCount])
        }
        let final = frames.last?.finalPromptChunk ?? false
        let issued = QwenTensorParallelIssuedSums()
        var submitted: [MLXArray] = []
        func phaseBuilt() {
            guard !issued.sums.isEmpty else { return }
            asyncEval(issued.sums)
            submitted += issued.sums
            issued.sums.removeAll()
            while submitted.count > sumsInFlight { eval(submitted.removeFirst()) }
        }
        let built: (outputs: [MLXArray], hidden: [MLXArray]?) = QwenTensorParallelRowLinear.$issuedSums.withValue(issued) {
            let kv = caches.map { $0 as! any KVCache }
            guard capturingHidden else {
                return (Qwen35PromptWavefront.prefill(model.model, chunks: chunks, finalChunk: final,
                    caches: kv, recurrentState: evaluation, phaseBuilt: phaseBuilt), nil)
            }
            let step = Qwen35PromptWavefront.prefillWithHidden(model.model, chunks: chunks, finalChunk: final,
                caches: kv, recurrentState: evaluation, phaseBuilt: phaseBuilt)
            return (step.outputs, step.hidden)
        }
        let outputs = built.outputs
        // Earlier frames' last rows run too, as each frame's own output did; nothing reads them.
        asyncEval(Array(outputs.dropLast()))
        return (final ? outputs[outputs.count - 1][0..., -1, 0...] : outputs[outputs.count - 1], built.hidden)
    }
}
