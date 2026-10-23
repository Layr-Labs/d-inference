import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Input ownership is request-local. A media owner supplies its authenticated
/// position slices and prompt embeddings; text keeps the cache's own offsets.
/// The callbacks and their captured features remain held until checked native
/// retirement. This seam neither loads media nor admits its memory.
struct QwenTensorParallelBatchInputs {
    let positions: (Range<Int>) throws -> MLXArray
    let promptEmbedding: (MLXArray, Range<Int>) throws -> MLXArray
}

/// A genuine TP shard's independent attention and recurrent history. The
/// scheduling owner must execute both ranks in identical lane order, admit
/// memory before construction and keep its charge until retirement succeeds.
final class QwenTensorParallelBatchSession {
    let model: QwenTensorParallelModel
    let request: QwenLayerStageGenerationRequest
    let state: CBv2OwnedRequestState
    private var inputs: QwenTensorParallelBatchInputs?
    private(set) var schedule: QwenLayerStageGenerationSchedule
    private(set) var retired = false
    var committedTokens: Int { state.committedTokens }

    init(model: QwenTensorParallelModel, configuration: Data, host: CBv2StageKVHost,
         request: QwenLayerStageGenerationRequest, inputs: QwenTensorParallelBatchInputs? = nil) throws {
        guard case .shard(_, let ranks) = model.role, ranks == 2, !model.plan.routedExperts,
              sha256(configuration) == model.configurationSHA256,
              request.profile.hiddenSize == model.plan.hiddenSize,
              request.profile.vocabularySize == model.plan.vocabularySize,
              request.reusedPrefixTokens == 0 else {
            throw ProbeError("Qwen TP batch session requires a matching dense shard and fresh request")
        }
        let geometry = try CBv2RequestGeometry(model: model.model, family: .qwen35,
            feedForwardKind: QwenRoutedExpertStageModel.feedForwardKind(model.model),
            layerCount: model.plan.layerCount, vocabularySize: model.plan.vocabularySize,
            configurationData: configuration, maximumTokens: request.maximumTokens, host: host)
        self.model = model; self.request = request; self.inputs = inputs
        state = try CBv2OwnedRequestState(geometry: geometry,
            promptCount: request.promptCount, outputCount: request.outputCount)
        schedule = QwenLayerStageGenerationSchedule(request: request)
    }

    func prefill(check: () throws -> Void) throws -> MLXArray? {
        try MLX.withError { error in
            func checked() throws { try error.check(); try check() }
            let proposed = try request.frame(sequence: schedule.nextSequence)
            let frame = try schedule.admitPrefill(count: proposed.tokenCount, offset: proposed.tokenOffset,
                final: proposed.finalPromptChunk)
            guard !retired, frame.phase == .prefill, state.committedTokens == frame.tokenOffset else {
                throw ProbeError("Qwen TP batch prefill frontier differs")
            }
            let range = frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)
            let input = MLXArray(request.promptTokenIDs[range].map(Int32.init)).reshaped([1, frame.tokenCount])
            let positions = try inputs.map { try $0.positions(range) }
            let embeddings = try inputs.map { try $0.promptEmbedding(input, range) }
            try validatePositions(positions, count: frame.tokenCount)
            if let embeddings {
                guard embeddings.shape == [1, frame.tokenCount, model.plan.hiddenSize],
                      String(describing: embeddings.dtype) == request.profile.activationDType else {
                    throw ProbeError("Qwen TP batch prompt embeddings differ from the shard")
                }
            }
            let final = range.upperBound == request.promptCount
            let output = try state.run(tokenCount: frame.tokenCount, check: checked, forward: { caches, evaluation in
                let native = self.model.model
                if !final {
                    return native.cbv2RecurrentPrefill(input, inputEmbedding: embeddings,
                        cache: caches.map { $0 as! any KVCache }, recurrentState: [evaluation],
                        positionIds: positions, requirement: .evaluationOnly)
                }
                // Preserve the solo TP final prompt head's rectangular graph;
                // project the full frame before taking its surviving last row.
                let output: MLXArray
                if let embeddings {
                    output = native.embeddingForward(input, inputEmbedding: embeddings,
                        cache: caches.map { $0 as! any KVCache }, recurrentState: [evaluation], positionIds: positions)
                } else {
                    output = native.cbv2Forward(input, caches: caches.map { $0 as! any KVCache },
                        recurrentState: [evaluation], positionIds: positions)
                }
                return output[0..., -1, 0...]
            }, validateOutput: { output in
                if final { try Self.validateLogits(output, rows: 1, model: self.model, request: self.request) }
                else if output.shape != [1, 1] && output.shape != [1, 1, 1] {
                    throw ProbeError("Qwen TP evaluation-only prompt handle differs")
                }
            })
            try schedule.commit(frame)
            return final ? output : nil
        }
    }

    static func decode(_ sessions: [QwenTensorParallelBatchSession], tokens: [Int],
                       check: () throws -> Void) throws -> MLXArray {
        guard let first = sessions.first, (1...8).contains(sessions.count), sessions.count == tokens.count,
              Set(sessions.map { ObjectIdentifier($0) }).count == sessions.count,
              sessions.allSatisfy({ $0.model === first.model && !$0.retired }) else {
            throw ProbeError("Qwen TP batch decode needs distinct sessions of one loaded shard")
        }
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check() }
            var frames: [QwenLayerStageFrame] = []
            var positionRows: [MLXArray] = []
            // If any lane carries explicit media positions, all rows supply
            // their own three axes, including ordinary text rows in the cohort.
            let positioned = sessions.contains { $0.inputs != nil }
            for (session, token) in zip(sessions, tokens) {
                guard (0..<first.model.plan.vocabularySize).contains(token),
                      session.state.committedTokens == session.schedule.committedTokens else {
                    throw ProbeError("Qwen TP decode token or committed frontier differs")
                }
                let frame = try session.schedule.admitDecode(offset: session.committedTokens)
                frames.append(frame)
                if positioned {
                    let range = frame.tokenOffset..<(frame.tokenOffset + 1)
                    let positions = try session.inputs.map { try $0.positions(range) }
                        ?? MLXArray(Array(repeating: Int32(frame.tokenOffset), count: 3)).reshaped([3, 1, 1])
                    try session.validatePositions(positions, count: 1)
                    positionRows.append(positions)
                }
            }
            let input = MLXArray(tokens.map(Int32.init)).reshaped([sessions.count, 1])
            let positions = positioned ? concatenated(positionRows, axis: 1) : nil
            let output = try CBv2OwnedRequestState.runBatch(sessions.map(\.state), tokenCount: 1, check: checked,
                forward: { caches, evaluations in
                    Qwen35BatchDecodeScope.$enabled.withValue(true) {
                        Qwen35BatchDecodeScope.$explicitPositionRows.withValue(sessions.map { $0.inputs != nil }) {
                            first.model.model.cbv2Forward(input, caches: caches.map { $0 as! any KVCache },
                                recurrentState: evaluations, positionIds: positions)[0..., -1, 0...]
                        }
                    }
                }, validateOutput: { output in
                    try validateLogits(output, rows: sessions.count, model: first.model, request: first.request)
                })
            for (session, frame) in zip(sessions, frames) { try session.schedule.commit(frame) }
            return output
        }
    }

    private func validatePositions(_ positions: MLXArray?, count: Int) throws {
        guard let positions else { return }
        guard positions.shape == [3, 1, count], positions.dtype == .int32,
              all(positions .>= 0).item(Bool.self) else {
            throw ProbeError("Qwen TP positions differ from request-owned three-axis slices")
        }
    }
    private static func validateLogits(_ value: MLXArray, rows: Int, model: QwenTensorParallelModel,
                                       request: QwenLayerStageGenerationRequest) throws {
        guard value.shape == [rows, model.vocabularyRange.count],
              String(describing: value.dtype) == request.profile.selectedRowDType,
              all(isFinite(value)).item(Bool.self) else {
            throw ProbeError("Qwen TP batched logits have an invalid shape, dtype or finite value")
        }
    }

    func retire() throws {
        guard !retired else { return }
        try MLX.withError { error in
            try state.retire()
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
            guard state.isClosed else { throw ProbeError("Qwen TP batch history remains owned") }
            inputs = nil
            retired = true
        }
    }
}
