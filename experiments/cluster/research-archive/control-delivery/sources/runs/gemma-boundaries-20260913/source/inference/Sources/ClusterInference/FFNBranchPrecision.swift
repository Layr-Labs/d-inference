import MLX
import MLXNN

/// An explicit arithmetic policy, separate from stored weight precision.
/// Float32 widens the entire Gemma FFN branch after its ordinary input norm.
enum FFNBranchPrecision: String { case native, float32 }

/// Paired within one graph-construction call. No state crosses forwards, and
/// no evaluation is introduced at either boundary.
final class FFNBranchCast {
    private var incomingDType: DType?

    func enter(_ normalized: MLXArray) -> MLXArray {
        precondition(incomingDType == nil, "FFN branch entered twice before its output")
        precondition([DType.float16, .bfloat16, .float32].contains(normalized.dtype),
                     "FFN precision requires floating activations")
        incomingDType = normalized.dtype
        return normalized.asType(.float32)
    }

    func leave(_ reduced: MLXArray) -> MLXArray {
        guard let dtype = incomingDType else { preconditionFailure("FFN output has no matching input") }
        precondition(reduced.dtype == .float32, "FFN branch narrowed before its reduction boundary")
        incomingDType = nil
        return reduced.asType(dtype)
    }
}

/// Open RMSNorm boundaries let adapters preserve the model's typed FFN modules.
/// The stored norm parameter is retained unchanged; only explicit transforms
/// around the ordinary normalization operation are added.
final class FFNBoundaryNorm: RMSNorm {
    let before: ((MLXArray) -> MLXArray)?
    let after: ((MLXArray) -> MLXArray)?

    init(_ source: RMSNorm, before: ((MLXArray) -> MLXArray)? = nil,
         after: ((MLXArray) -> MLXArray)? = nil) throws {
        self.before = before; self.after = after
        super.init(dimensions: source.weight.size, eps: source.eps)
        try update(parameters: source.parameters(), verify: [.all])
    }

    override func callAsFunction(_ input: MLXArray) -> MLXArray {
        let normalized = super.callAsFunction(before?(input) ?? input)
        return after?(normalized) ?? normalized
    }
}
