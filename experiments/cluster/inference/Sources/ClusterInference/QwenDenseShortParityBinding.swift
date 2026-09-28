import Foundation

/// CPU identity checks before any pair resource observation, file or model IO.
/// Numerical replay remains in the unchanged recorder and comparator.
enum QwenDenseShortParityBinding {
    static func requireBaseline(_ baseline: QwenLayerStageBaselineEvidence,
        admission: QwenDenseShortReferenceAdmission
    ) throws {
        let spec = admission.metadata.specification, source = baseline.source
        guard baseline.allRequestStateRetired,
              baseline.request.fingerprint == admission.request.fingerprint,
              try canonicalJSONData(baseline.request) == canonicalJSONData(admission.request),
              source.artifactAggregateSHA256 == spec.artifactSHA256,
              source.sourceConfigurationSHA256 == spec.configurationSHA256,
              source.planSHA256 == admission.metadata.plan.fingerprint,
              source.layerCount == spec.layers, source.vocabularySize == admission.request.vocabularySize,
              source.sourceModelTensorBytes == spec.sourceBytes, source.bf16ConversionEnabled,
              QwenDenseProfileIdentity.isSHA256(source.sourceParameterLayoutSHA256),
              ["float16", "bfloat16", "float32"].contains(source.embeddingActivationDType),
              baseline.frames.count == 3,
              baseline.frames.map(\.committedTokens) == [2, 3, 4],
              baseline.frames.map({ $0.logits != nil }) == [false, true, true] else {
            throw ProbeError("Short pair requires the released exact registered baseline and recorded history")
        }
        let rebuilt = try QwenLayerStageBaselineEvidence(request: admission.request,
            source: source, frames: baseline.frames)
        guard rebuilt.fingerprint == baseline.fingerprint else {
            throw ProbeError("Short baseline evidence fingerprint differs from its exact frames")
        }
    }
}
