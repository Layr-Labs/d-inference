import Cmlx
import MLX
import MLXNN

private struct FFNBranchPrecisionCheckResult: Encodable {
    let kind = "ffn_branch_precision_boundary"
    let incomingDType: String
    let precision: String
    let graphsComparedExactly = 3
    let storedNormWeightsUnchanged = true
    let wholeModelQualification = false
}

/// Checks the boundary's rounding placement against direct MLX expressions.
/// Whole-model numerical observations remain separate from this contract test.
func checkFFNBranchPrecision() throws {
    for (dtype, precision) in [DType.float32, .bfloat16].flatMap({ dtype in
        [FFNBranchPrecision.float32, .float32ThroughNorm].map { (dtype, $0) }
    }) {
        let norm = RMSNorm(dimensions: 8, eps: 1e-5)
        try norm.update(parameters: ModuleParameters.unflattened([
            "weight": MLXArray((0..<8).map { 0.7 + Float($0) * 0.13 }).asType(dtype),
        ]), verify: [.all])
        let cast = FFNBranchCast()
        let inputNorm = try FFNBoundaryNorm(norm, after: cast.enter)
        let throughNorm = precision == .float32ThroughNorm
        let outputNorm = try FFNBoundaryNorm(norm,
            before: throughNorm ? nil : cast.leave,
            after: throughNorm ? cast.leave : nil)
        eval(norm, inputNorm, outputNorm)
        // Module.update retains the native array through _updateInternal; the
        // surrounding Swift MLXArray reference is not required to be identical.
        guard let sourceBytes = mlx_array_data_uint8(norm.weight.ctx),
            mlx_array_data_uint8(inputNorm.weight.ctx) == sourceBytes,
            mlx_array_data_uint8(outputNorm.weight.ctx) == sourceBytes,
            inputNorm.weight.asData().data == norm.weight.asData().data,
            outputNorm.weight.asData().data == norm.weight.asData().data else {
            throw ProbeError("FFN precision wrapper replaced stored normalization weights")
        }
        var actual: [MLXArray] = [], expected: [MLXArray] = []
        for rows in [1, 3, 1] {
            let x = MLXArray((0..<(rows * 8)).map { Float($0 + 1) / 31 }).reshaped(rows, 8).asType(dtype)
            let entered = inputNorm(x)
            let first = entered * 0.37631
            let second = entered * -0.27891
            let result = outputNorm(first + second)
            guard entered.dtype == .float32, result.dtype == dtype else {
                throw ProbeError("FFN boundary changed expected activation dtypes")
            }
            let normalized = norm(x).asType(.float32)
            let sum = (normalized * 0.37631) + (normalized * -0.27891)
            let reference = throughNorm ? norm(sum).asType(dtype) : norm(sum.asType(dtype))
            actual.append(result); expected.append(reference)
        }
        // Build multiple graphs before evaluating them: pairing is construction
        // state, not a dependency on when older graphs finish on the device.
        for (observed, reference) in zip(actual, expected) {
            guard observed.asData().data == reference.asData().data else {
                throw ProbeError("FFN boundary did not normalize/cast at the declared locations")
            }
        }
        try emitJSON(FFNBranchPrecisionCheckResult(incomingDType: String(describing: dtype),
                                                  precision: precision.rawValue))
    }
}
