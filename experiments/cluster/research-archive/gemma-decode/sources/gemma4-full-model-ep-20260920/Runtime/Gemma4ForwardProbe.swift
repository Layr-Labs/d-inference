import Foundation
import MLX
import MLXLMCommon

struct Gemma4ForwardProbe {
    let observed: CBv2NativeKVTypeProbe.Result
    let parameterLayoutSHA256: String
    let planSHA256: String
    let outgoingResidualDType: DType?
    let incomingResidualDType: DType?
    fileprivate init(observed: CBv2NativeKVTypeProbe.Result, parameterLayoutSHA256: String,
                     planSHA256: String, outgoingResidualDType: DType?, incomingResidualDType: DType?) {
        self.observed = observed; self.parameterLayoutSHA256 = parameterLayoutSHA256
        self.planSHA256 = planSHA256; self.outgoingResidualDType = outgoingResidualDType
        self.incomingResidualDType = incomingResidualDType
    }
}

extension Gemma4LoadedForwardModel {
    /// Real prefill2/decode1 using the existing recorder. A final stage must
    /// receive actual rank0 residuals for those exact token frontiers. The
    /// caller binds/admits their model, phase, shape, byte count and dtype.
    /// Neither embedding metadata nor a fabricated tensor can establish this
    /// cross-stage profile. No probe array is retained in the returned value.
    func probe(incomingDType: DType? = nil,
               incoming: ((CBv2NativeKVTypeProbe.Phase, Int) throws -> MLXArray)? = nil,
               observeIngress: ((CBv2NativeKVTypeProbe.Phase, MLXArray) throws -> Void)? = nil,
               expertOperation: (any Gemma4ExpertForwardOperation)? = nil,
               check: () throws -> Void) throws -> Gemma4ForwardProbe {
        guard model.isResidualConsumer == (incoming != nil),
              model.isResidualConsumer == (incomingDType != nil),
              incomingDType.map({ [.float16, .bfloat16, .float32].contains($0) }) ?? true else {
            throw ProbeError("Gemma probe residual responsibility/type differs")
        }
        if let expertOperation {
            guard expertOperation.binding.purpose == .probe,
                  expertOperation.partition == model.expertPartition,
                  expertOperation.binding.artifactSHA256 == receipt.artifactSHA256,
                  expertOperation.binding.configurationSHA256 == receipt.configurationSHA256 else {
                throw ProbeError("Gemma EP probe operation differs from actual model/source")
            }
        }
        return try MLX.withError { native in
            func checked() throws { try native.check(); try check(); try native.check() }
            do {
                try checked()
                let caches = model.freshCaches()
                var outgoing: DType?
                let observed = try CBv2NativeKVTypeProbe.run(layerKinds: model.kinds, caches: caches) { phase, count, bound in
                    // The recorder owns a separate handler. Preserve faults
                    // from this callback before any Swift validation/cancel throw.
                    return try MLX.withError { callbackError in
                        func callbackChecked() throws {
                            try callbackError.check(); try checked(); try callbackError.check()
                        }
                        do {
                            try callbackChecked()
                            let residual = try incoming?(phase, count)
                            if let residual {
                                guard residual.shape == [1, count, plan.artifact.text.hiddenSize],
                                      residual.dtype == incomingDType else { throw ProbeError("Gemma probe boundary differs") }
                            }
                            let frame = QwenLayerStageFrame(sequence: phase == .prefill ? 0 : 1,
                                phase: phase == .prefill ? .prefill : .decode,
                                tokenOffset: phase == .prefill ? 0 : 2, tokenCount: count,
                                finalPromptChunk: phase == .prefill)
                            let output = try model.forward(tokens: Array(repeating: 0, count: count),
                                residual: residual, frame: frame, caches: bound, nativeTypes: nil,
                                expertOperation: expertOperation, check: callbackChecked)
                            try callbackChecked()
                            if model.isIngressStage {
                                guard output.shape == [1, count, plan.artifact.text.hiddenSize],
                                      [.float16, .bfloat16, .float32].contains(output.dtype),
                                      outgoing == nil || outgoing == output.dtype else {
                                    throw ProbeError("Gemma residual dtype changes between native probe phases")
                                }
                                outgoing = output.dtype
                                // Explicit correctness/probe boundary only. Materialize
                                // before the caller transports a phase's actual bytes.
                                eval(output); try callbackChecked()
                                try observeIngress?(phase, output); try callbackChecked()
                            }
                            return output
                        } catch { try callbackError.check(); throw error }
                    }
                }
                try checked()
                guard caches.allSatisfy({ $0.rows.isEmpty }) else { throw ProbeError("Gemma probe retained request rows") }
                return .init(observed: observed, parameterLayoutSHA256: receipt.parameterLayoutSHA256,
                    planSHA256: plan.fingerprint, outgoingResidualDType: outgoing,
                    incomingResidualDType: incomingDType)
            } catch { try native.check(); throw error }
        }
    }
}
