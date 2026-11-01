import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// One TP target's request-owned paged attention and recurrent history for
/// speculative verification. Both ranks must execute identical calls. This
/// seam neither selects tokens nor owns assistant state or peer publication.
/// Media keeps the ordinary target-only path, matching standalone MTP policy.
/// The owner serves every request through `QwenTensorParallelBatchSession`
/// (capacity one included); this lone target remains the decoder suites'
/// single-request fixture (`QwenTensorParallelMTPSessionTests`).
final class QwenTensorParallelMTPSession: QwenTensorParallelMTPTarget {
    typealias PromptResult = QwenTensorParallelMTPPromptResult
    let model: QwenTensorParallelModel
    let request: QwenLayerStageGenerationRequest
    let state: CBv2OwnedRequestState
    private(set) var schedule: QwenLayerStageGenerationSchedule
    private(set) var retired = false
    private var failed = false
    private var window: QwenTensorParallelTargetWindow?

    init(model: QwenTensorParallelModel, configuration: Data, host: CBv2StageKVHost,
         request: QwenLayerStageGenerationRequest, restored: QwenTensorParallelBatchPrefixState? = nil,
         permitContiguousDiagnostic: Bool = false) throws {
        guard case .shard(_, let size) = model.role, size == 2, !model.plan.routedExperts,
              sha256(configuration) == model.configurationSHA256,
              request.profile.hiddenSize == model.plan.hiddenSize,
              request.profile.vocabularySize == model.plan.vocabularySize,
              request.reusedPrefixTokens == (restored?.committedTokens ?? 0),
              request.reusedPrefixTokens % request.chunkSize == 0, request.qwenMedia == nil,
              host.kind == .paged || permitContiguousDiagnostic else {
            throw ProbeError("Qwen TP MTP requires a fresh matching dense text shard with paged ownership")
        }
        let geometry = try CBv2RequestGeometry(model: model.model, family: .qwen35,
            feedForwardKind: QwenRoutedExpertStageModel.feedForwardKind(model.model),
            layerCount: model.plan.layerCount, vocabularySize: model.plan.vocabularySize,
            configurationData: configuration, maximumTokens: request.maximumTokens, host: host)
        self.model = model; self.request = request
        if let restored {
            state = try CBv2OwnedRequestState(geometry: geometry, promptCount: request.promptCount,
                outputCount: request.outputCount, adoptingCommittedTokens: restored.committedTokens,
                attention: restored.attention, recurrent: restored.recurrent)
        } else {
            state = try CBv2OwnedRequestState(geometry: geometry, promptCount: request.promptCount,
                                            outputCount: request.outputCount)
        }
        schedule = .init(request: request)
    }

    func prefill(check: () throws -> Void) throws -> PromptResult {
        do {
            return try MLX.withError { error in
                func checked() throws { try error.check(); try check() }
                try requireOpen()
                let next = try request.frame(sequence: schedule.nextSequence)
                let frame = try schedule.admitPrefill(count: next.tokenCount, offset: next.tokenOffset,
                                                     final: next.finalPromptChunk)
                guard state.committedTokens == frame.tokenOffset else { throw ProbeError("Qwen TP MTP prompt frontier differs") }
                let range = frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)
                let tokens = MLXArray(request.promptTokenIDs[range].map(Int32.init)).reshaped([1, frame.tokenCount])
                var hidden: MLXArray?
                let output = try state.run(tokenCount: frame.tokenCount, check: checked, forward: { caches, evaluation in
                    let result = self.model.model.cbv2ForwardWithHidden(tokens,
                        caches: caches.map { $0 as! any KVCache }, recurrentState: [evaluation], positionIds: nil)
                    hidden = result.lastHidden
                    return frame.finalPromptChunk ? result.logits : result.lastHidden
                }, validateOutput: { output in
                    guard let hidden, hidden.shape == [1, frame.tokenCount, self.model.plan.hiddenSize],
                          String(describing: hidden.dtype) == self.request.profile.activationDType else {
                        throw ProbeError("Qwen TP MTP prompt hidden contract differs")
                    }
                    if frame.finalPromptChunk { try self.validateLogits(output, count: frame.tokenCount) }
                })
                try schedule.commit(frame)
                return PromptResult(hidden: hidden!, logits: frame.finalPromptChunk ? output[0..., -1, 0...] : nil)
            }
        } catch { failed = true; throw error }
    }

    func prefillForMTP(check: () throws -> Void) throws -> PromptResult {
        try prefill(check: check)
    }

    func beginWindow(tokens: MLXArray, offset: Int) throws -> (outputs: [MLXArray], roots: [MLXArray]) {
        do {
            try requireOpen()
            _ = try schedule.admitDecode(offset: offset)
            guard schedule.committedTokens == offset else { throw ProbeError("Qwen TP MTP schedule frontier differs") }
            let transaction = window ?? QwenTensorParallelTargetWindow(model: model, request: request, state: state)
            window = transaction
            return try transaction.begin(tokens: tokens, offset: offset)
        } catch { failed = true; throw error }
    }

    func confirmWindow(check: () throws -> Void) throws {
        do { try requireWindow().confirm(check: check) }
        catch { failed = true; throw error }
    }

    func settleWindow(keeping kept: Int) throws -> [MLXArray] {
        do { return try requireWindow().settle(keeping: kept) }
        catch { failed = true; throw error }
    }

    func confirmSettled(check: () throws -> Void) throws {
        do {
            let range = try requireWindow().confirmSettled(check: check)
            for offset in range { try schedule.commit(schedule.admitDecode(offset: offset)) }
            guard schedule.committedTokens == state.committedTokens else { throw ProbeError("Qwen TP MTP settlement lost its schedule") }
        } catch { failed = true; throw error }
    }

    private func requireWindow() throws -> QwenTensorParallelTargetWindow {
        guard !retired, !failed, let window else { throw ProbeError("Qwen TP MTP has no live target transaction") }
        return window
    }

    private func requireOpen() throws {
        guard !retired, !failed, window?.isIdle ?? true else { throw ProbeError("Qwen TP MTP history is retired or unfinished") }
        try state.requireOpen()
    }
    private func validateLogits(_ value: MLXArray, count: Int) throws {
        guard value.shape == [1, count, model.vocabularyRange.count],
              String(describing: value.dtype) == request.profile.selectedRowDType else {
            throw ProbeError("Qwen TP MTP logits differ from the actual vocabulary shard")
        }
    }
    func retire() throws {
        guard !retired else { return }
        try MLX.withError { error in
            try state.retire()
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
            guard state.isClosed else { throw ProbeError("Qwen TP MTP retirement retained native history") }
            window = nil; retired = true
        }
    }
}
