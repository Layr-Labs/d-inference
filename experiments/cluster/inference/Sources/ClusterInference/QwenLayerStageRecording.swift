import Foundation
import MLX
import MLXNN

/// Owns and retires one full-model request. The caller owns the LoadedModel and
/// must release it before loading stages; nothing native is stored in the result.
func recordQwenLayerStageBaseline(loaded: LoadedModel, plan: QwenLayerStagePlan,
    request: QwenLayerStageRecordedRequest, check: () throws -> Void
) throws -> QwenLayerStageBaselineEvidence {
    try MLX.withError { error in
        let source = try recordedQwenSourceIdentity(loaded: loaded, plan: plan, request: request)
        try error.check(); try check()
        let session = try CBv2RequestSession(loaded: loaded, promptCount: request.request.promptCount,
                                            outputCount: request.request.outputCount)
        do {
            var frames: [QwenRecordedFrameEvidence] = []
            for step in request.steps {
                let record = try autoreleasepool {
                    let output: MLXArray
                    switch step.frame.phase {
                    case .prefill:
                        output = try session.prefillChunk(step.tokenIDs, final: step.frame.finalPromptChunk,
                            check: { try error.check(); try check() })
                    case .decode:
                        output = try session.decode(step.tokenIDs[0],
                            check: { try error.check(); try check() })
                    }
                    let width = step.expectsLogits ? request.vocabularySize : 1
                    guard session.committedTokens == step.committedTokens, output.shape == [1, width],
                          [.float16, .bfloat16, .float32].contains(output.dtype) else {
                        throw ProbeError("Recorded baseline output or frontier differs from its timeline")
                    }
                    let snapshot = try session.snapshot(includeBytes: false,
                        check: { try error.check(); try check() })
                    let state = try QwenRecordedState(snapshots: [snapshot], plan: plan,
                                                       committedTokens: step.committedTokens)
                    let logits = step.expectsLogits
                        ? try QwenRecordedLogits(output, vocabularySize: request.vocabularySize,
                            check: { try error.check(); try check() }) : nil
                    try error.check(); try check()
                    return QwenRecordedFrameEvidence(frame: step.frame, committedTokens: step.committedTokens,
                        outputKind: step.expectsLogits ? "logits" : "evaluation_handle",
                        outputShape: output.shape, outputDType: String(describing: output.dtype),
                        state: state, logits: logits)
                }
                frames.append(record)
            }
            try session.close()
            try error.check(); try check()
            guard session.isClosed, !session.isFailed,
                  session.committedTokens == request.request.promptCount + request.teacherTokenIDs.count else {
                throw ProbeError("Recorded baseline did not retire its complete request cleanly")
            }
            return try QwenLayerStageBaselineEvidence(request: request, source: source, frames: frames)
        } catch {
            let primary = error
            var cleanup: [String] = []
            // Required tiny baseline hook: set isFailed=true, then existing close().
            // It also marks an external record/snapshot failure after the last frame.
            do {
                try MLX.withError { cleanupError in
                    try session.cancel()
                    try cleanupError.check()
                }
            } catch { cleanup.append(String(describing: error)) }
            if !session.isClosed || !session.isFailed { cleanup.append("baseline request was not failed and retired") }
            if !cleanup.isEmpty {
                throw ProbeError("Baseline recording failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
            }
            throw primary
        }
    }
}

private func recordedQwenSourceIdentity(loaded: LoadedModel, plan: QwenLayerStagePlan,
    request: QwenLayerStageRecordedRequest) throws -> QwenRecordedSourceIdentity {
    guard let receipt = loaded.verifiedDiagnosticLoad, receipt.schemaVersion == 1,
          loaded.family == .qwen35, loaded.feedForwardKind == "dense",
          loaded.partitionPlan == nil, loaded.partitionStorage == nil, loaded.directShardLoad == nil,
          loaded.configurationData == plan.originalConfiguration,
          loaded.configHash == sha256(plan.originalConfiguration),
          receipt.configurationSHA256 == loaded.configHash,
          receipt.parameterLayoutSHA256 == loaded.parameterLayoutSHA256,
          modelParameterLayout(loaded.model) == loaded.parameterLayoutSHA256,
          receipt.bf16ConversionEnabled == loaded.bf16ConversionEnabled,
          loaded.model.trainableParameters().flattened().isEmpty,
          !loaded.model.namedModules().contains(where: { $0.0 == "mtp" || $0.0.hasSuffix(".mtp") }),
          ["float16", "bfloat16", "float32"].contains(loaded.embeddingActivationDType),
          loaded.vocabularySize == request.vocabularySize, loaded.layerCount == plan.layers else {
        throw ProbeError("Recorded baseline requires the verified complete native dense Qwen source model")
    }
    return .init(artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
        sourceConfigurationSHA256: loaded.configHash,
        sourceParameterLayoutSHA256: loaded.parameterLayoutSHA256, planSHA256: plan.fingerprint,
        bf16ConversionEnabled: loaded.bf16ConversionEnabled,
        embeddingActivationDType: loaded.embeddingActivationDType,
        sourceModelTensorBytes: receipt.sourceModelTensorBytes,
        layerCount: loaded.layerCount, vocabularySize: loaded.vocabularySize)
}
