import Foundation
import MLX

struct QwenRecordedFrameComparison: Encodable {
    let frame: QwenLayerStageFrame
    let committedTokens: Int
    let stateEntriesCompared: Int
    let logicalStateBytesPerSide: Int
    let globalStateSHA256: String
    let stateMetadataAndDigestsExact: Bool
    let logits: QwenRecordedLogitValues?
    let nativeLogitBytesExact: Bool?
}

struct QwenLayerStageRecordedComparison: Encodable {
    let kind = "qwen_layer_stage_recorded_comparison"
    let correctnessOnly = true
    let throughputMeasurementValid = false
    let sequentialOneProcessOnly = true
    let nativeBoundaryBytesCopied = true
    let baselineEvidenceSHA256: String
    let requestSHA256: String
    let source: QwenRecordedSourceIdentity
    let stageStorageCommitmentSHA256: String
    let frames: [QwenRecordedFrameComparison]
    let allRequestStateRetired: Bool
}

/// Replays the recorded timeline without retaining or referring to the baseline
/// model. State uses complete metadata+SHA comparison; logits use full raw bytes.
func compareQwenLayerStageRecordedRequest(baseline: QwenLayerStageBaselineEvidence,
    stages: [LoadedQwenLayerStage], plan: QwenLayerStagePlan, check: () throws -> Void
) throws -> QwenLayerStageRecordedComparison {
    try requireRecordedQwenStages(stages, baseline: baseline, plan: plan)
    return try MLX.withError { error in
        var sessions: [QwenLayerStageSession] = []
        do {
            let first = try QwenLayerStageSession(stage: stages[0], plan: plan, request: baseline.request.request)
            sessions.append(first)
            let second = try QwenLayerStageSession(stage: stages[1], plan: plan, request: baseline.request.request)
            sessions.append(second)
            let pair = try QwenSequentialStagePair(first: first, second: second)
            var frames: [QwenRecordedFrameComparison] = []
            for (step, original) in zip(baseline.request.steps, baseline.frames) {
                let record = try autoreleasepool {
                    let output: QwenLayerStageOutput
                    switch step.frame.phase {
                    case .prefill:
                        output = try pair.prefillChunk(step.tokenIDs, final: step.frame.finalPromptChunk,
                            check: { try error.check(); try check() })
                    case .decode:
                        output = try pair.decode(step.tokenIDs[0], check: { try error.check(); try check() })
                    }
                    let candidate: MLXArray
                    switch output {
                    case .logits(let array) where step.expectsLogits: candidate = array
                    case .evaluationHandle(let array) where !step.expectsLogits: candidate = array
                    default: throw ProbeError("Recorded stage replay returned the wrong output kind")
                    }
                    guard original.frame == step.frame,
                          original.committedTokens == step.committedTokens,
                          first.committedTokens == step.committedTokens,
                          second.committedTokens == step.committedTokens,
                          candidate.shape == original.outputShape,
                          String(describing: candidate.dtype) == original.outputDType else {
                        throw ProbeError("Recorded stage replay differs in frame, frontier, output shape or dtype")
                    }
                    let snapshots = try [first.snapshot(includeBytes: false,
                        check: { try error.check(); try check() }), second.snapshot(includeBytes: false,
                        check: { try error.check(); try check() })]
                    let state = try QwenRecordedState(snapshots: snapshots, plan: plan,
                                                       committedTokens: step.committedTokens)
                    try original.state.requireExact(state)
                    let logitRecord: QwenRecordedLogitValues?
                    if step.expectsLogits {
                        guard let reference = original.logits else { throw ProbeError("Recorded baseline omitted logits") }
                        let logits = try QwenRecordedLogits(candidate, vocabularySize: baseline.request.vocabularySize,
                            check: { try error.check(); try check() })
                        try reference.requireExact(logits, frontier: step.committedTokens)
                        logitRecord = logits.record
                    } else {
                        guard original.logits == nil else { throw ProbeError("Intermediate baseline frame has unexpected logits") }
                        logitRecord = nil
                    }
                    try error.check(); try check()
                    return QwenRecordedFrameComparison(frame: step.frame, committedTokens: step.committedTokens,
                        stateEntriesCompared: state.entries.count, logicalStateBytesPerSide: state.logicalByteCount,
                        globalStateSHA256: state.fingerprint, stateMetadataAndDigestsExact: true,
                        logits: logitRecord, nativeLogitBytesExact: step.expectsLogits ? true : nil)
                }
                frames.append(record)
            }
            try pair.close()
            try error.check(); try check()
            guard frames.count == baseline.frames.count,
                  sessions.allSatisfy({ $0.isClosed && !$0.isFailed }) else {
                throw ProbeError("Recorded stage replay did not complete and retire its full request")
            }
            return .init(baselineEvidenceSHA256: baseline.fingerprint, requestSHA256: baseline.request.fingerprint,
                source: baseline.source, stageStorageCommitmentSHA256: stages[0].receipt.storageCommitmentSHA256,
                frames: frames, allRequestStateRetired: true)
        } catch {
            let primary = error
            var cleanup: [String] = []
            for session in sessions {
                do { try session.cancel() } catch { cleanup.append(String(describing: error)) }
                if !session.isClosed || !session.isFailed { cleanup.append("stage request was not failed and retired") }
            }
            if !cleanup.isEmpty {
                throw ProbeError("Recorded stage replay failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
            }
            throw primary
        }
    }
}

private func requireRecordedQwenStages(_ stages: [LoadedQwenLayerStage],
    baseline: QwenLayerStageBaselineEvidence, plan: QwenLayerStagePlan) throws {
    guard baseline.allRequestStateRetired, stages.count == 2,
          baseline.frames.count == baseline.request.steps.count,
          !baseline.frames.isEmpty, baseline.frames.count <= 132,
          baseline.source.planSHA256 == plan.fingerprint,
          baseline.source.sourceConfigurationSHA256 == sha256(plan.originalConfiguration),
          baseline.source.layerCount == plan.layers,
          baseline.source.vocabularySize == baseline.request.vocabularySize else {
        throw ProbeError("Recorded stage replay requires complete matching baseline evidence and source plan")
    }
    for (index, stage) in stages.enumerated() {
        let receipt = stage.receipt, source = baseline.source
        guard stage.stageIndex == index, stage.vocabularySize == source.vocabularySize,
              stage.plan.fingerprint == plan.fingerprint,
              receipt.sourceConfigurationSHA256 == source.sourceConfigurationSHA256,
              receipt.verifiedAggregateSHA256 == source.artifactAggregateSHA256,
              receipt.sourceParameterLayoutSHA256 == source.sourceParameterLayoutSHA256,
              receipt.sourceModelTensorBytes == source.sourceModelTensorBytes,
              receipt.bf16ConversionEnabled == source.bf16ConversionEnabled,
              receipt.embeddingActivationDType == source.embeddingActivationDType else {
            throw ProbeError("Stage \(index) does not represent the recorded baseline artifact and native transformation")
        }
    }
}
