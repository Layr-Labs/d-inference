import Foundation

/// Source/input admission and host-only checks for the uncaptured control.
/// This deliberately does not reuse the snapshotting recorded replay driver.
enum QwenLayerStagePrefillComparisonValidation {
    static func admit(baseline: QwenLayerStageBaselineEvidence,
        stages: [LoadedQwenLayerStage], plan: QwenLayerStagePlan
    ) throws -> QwenRecordedFrameEvidence {
        let request = baseline.request, source = baseline.source
        guard baseline.allRequestStateRetired, stages.count == 2, plan.stages.count == 2,
              (1...128).contains(request.request.promptCount),
              (1...32).contains(request.request.chunkSize), request.request.outputCount == 1,
              request.teacherTokenIDs.isEmpty, request.steps.allSatisfy({ $0.frame.phase == .prefill }),
              baseline.frames.count == request.steps.count, !baseline.frames.isEmpty,
              baseline.frames.count <= 128, source.planSHA256 == plan.fingerprint,
              source.sourceConfigurationSHA256 == sha256(plan.originalConfiguration),
              source.layerCount == plan.layers, source.vocabularySize == request.vocabularySize,
              stages[0].receipt.storageCommitmentSHA256 == stages[1].receipt.storageCommitmentSHA256,
              let final = baseline.frames.last, final.frame == request.steps.last?.frame,
              final.frame.finalPromptChunk, final.committedTokens == request.request.promptCount,
              final.state.committedTokens == final.committedTokens, let logits = final.logits,
              final.outputKind == "logits", final.outputShape == [1, request.vocabularySize],
              final.outputDType == logits.record.dtype else {
            throw ProbeError("Uncaptured comparison requires a complete prefill-only baseline and matching stages")
        }
        for (index, stage) in stages.enumerated() {
            let receipt = stage.receipt
            guard stage.stageIndex == index, stage.vocabularySize == source.vocabularySize,
                  stage.plan.fingerprint == plan.fingerprint,
                  receipt.sourceConfigurationSHA256 == source.sourceConfigurationSHA256,
                  receipt.verifiedAggregateSHA256 == source.artifactAggregateSHA256,
                  receipt.sourceParameterLayoutSHA256 == source.sourceParameterLayoutSHA256,
                  receipt.sourceModelTensorBytes == source.sourceModelTensorBytes,
                  receipt.bf16ConversionEnabled == source.bf16ConversionEnabled,
                  receipt.embeddingActivationDType == source.embeddingActivationDType else {
                throw ProbeError("Uncaptured stage \(index) differs from the baseline source or native transformation")
            }
        }
        for (step, original) in zip(request.steps, baseline.frames) {
            guard original.frame == step.frame, original.committedTokens == step.committedTokens,
                  original.outputKind == (step.expectsLogits ? "logits" : "evaluation_handle"),
                  original.outputShape == [1, step.expectsLogits ? request.vocabularySize : 1],
                  ["float16", "bfloat16", "float32"].contains(original.outputDType),
                  (original.logits != nil) == step.expectsLogits else {
                throw ProbeError("Uncaptured baseline metadata differs from its exact prompt timeline")
            }
        }
        return final
    }

    static func frame(_ commits: [QwenLayerStagePrefillCommit],
        expected: QwenLayerStageBoundaryWireExpectation,
        original: QwenRecordedFrameEvidence, step: QwenLayerStageRecordedRequest.Step,
        request: QwenLayerStageRecordedRequest, identities: [QwenLayerStageSessionIdentity]
    ) throws -> QwenLayerStagePrefillFrameComparison {
        guard commits.count == 2, identities.count == 2 else {
            throw ProbeError("Uncaptured frame requires two stage commits")
        }
        for (index, commit) in commits.enumerated() {
            guard commit.identity == identities[index], commit.identity.stageIndex == index,
                  commit.recordedRequestFingerprint == request.fingerprint,
                  commit.frame == step.frame, commit.committedTokens == step.committedTokens else {
                throw ProbeError("Uncaptured commit differs from its stage identity or prompt frontier")
            }
        }
        guard commits[0].outputKind == "hidden", commits[0].outputShape == expected.shape,
              commits[0].outputDType == expected.dtype,
              commits[1].outputKind == original.outputKind,
              commits[1].outputShape == original.outputShape,
              commits[1].outputDType == original.outputDType else {
            throw ProbeError("Uncaptured stage output metadata differs from the full-width baseline path")
        }
        return .init(frame: step.frame, committedTokens: step.committedTokens, stageCommits: commits)
    }

    static func token(_ selected: QwenLayerStagePrefillTokenReceipt,
        baseline: QwenRecordedLogits, request: QwenLayerStageRecordedRequest,
        identity: QwenLayerStageSessionIdentity
    ) throws -> QwenLayerStagePrefillTokenComparison {
        let record = baseline.record, values = record.values
        let elementBytes = try qwenStageWireElementBytes(record.dtype)
        guard (1...262_144).contains(request.vocabularySize),
              record.shape == [1, request.vocabularySize], values.count == request.vocabularySize,
              record.byteCount == request.vocabularySize * elementBytes,
              values.allSatisfy(\.isFinite), let first = values.first,
              selected.identity == identity, selected.identity.stageIndex == 1,
              selected.recordedRequestFingerprint == request.fingerprint,
              selected.frame == request.steps.last?.frame,
              selected.committedTokens == request.request.promptCount,
              selected.vocabularySize == request.vocabularySize, selected.outputOrdinal == 0,
              selected.selectionPolicy == "mlx_argmax_all_axes_with_finite_guard_v1",
              selected.logitsShape == record.shape, selected.logitsDType == record.dtype,
              selected.selectionDType == "uint32", selected.allLogitsFinite else {
            throw ProbeError("Uncaptured token receipt differs from the finite baseline vocabulary row")
        }
        // Pinned Metal ArgMax.reduce selects the lower index on equality; its
        // ascending lane scan and CPU implementation update only on greater.
        // F16/BF16 baseline values widen exactly to Float32, preserving ties.
        var maximum = first, tokenID = 0, ties = 1
        for index in values.indices.dropFirst() {
            if values[index] > maximum { maximum = values[index]; tokenID = index; ties = 1 }
            else if values[index] == maximum { ties += 1 }
        }
        guard selected.tokenID == tokenID else {
            throw ProbeError("Uncaptured native argmax differs from the baseline first-index maximum")
        }
        return .init(policy: "finite_maximum_lowest_vocabulary_index_v1",
            baselineTokenID: tokenID, selectedTokenID: selected.tokenID,
            maximumLogit: maximum, maximumTieCount: ties, tokenExact: true)
    }
}
