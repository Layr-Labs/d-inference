import Foundation
import MLX
import MLXNN

/// Both experiments hold the captured model input and selected packed rows
/// fixed. Results remain operator diagnostics, not a model precision policy.
func evaluateGDNArithmetic(inputs: GDNProjectionInputs, input: MLXArray,
                           check: () throws -> Void) throws -> GDNArithmeticVariants {
    guard input.shape.count == 3, input.shape[0] == 1, (1...32).contains(input.shape[1]),
          input.shape[2] == inputs.plan.hiddenSize,
          [DType.float16, .bfloat16, .float32].contains(input.dtype) else {
        throw ProbeError("GDN arithmetic variants require the bounded native captured input")
    }
    // Sequential scopes release all temporary MLX matrices between variants.
    // Four full F32-metadata triplets cover selected pieces, zero padding,
    // concatenation and transient copies. The remaining terms reserve retained
    // native/variant captures plus temporary Float32 conversion. This estimate
    // excludes the loaded model and is not a guarantee about allocator/OS peaks.
    let estimatedBytes = try QwenGDNInputAdmission.arithmeticEstimatedBytes(
        hiddenSize: inputs.plan.hiddenSize, fusedWidth: inputs.fusedWidth, tokens: input.shape[1])
    var wide: [GDNFloat32ProjectionEvaluation] = []
    for rank in [nil, 0, 1] as [Int?] {
        wide.append(try autoreleasepool {
            try evaluateGDNFloat32(inputs: inputs, input: input, rank: rank, check: check)
        })
    }
    var padded: [GDNPaddedProjectionEvaluation] = []
    for rank in 0..<2 {
        padded.append(try autoreleasepool {
            try evaluateGDNPadded(inputs: inputs, input: input, rank: rank, check: check)
        })
    }
    return GDNArithmeticVariants(estimatedAdditionalTensorAndCaptureBytes: estimatedBytes,
        float32: GDNFloat32ProjectionVariant(evaluations: wide),
        paddedNative: GDNPaddedProjectionVariant(evaluations: padded))
}

private func evaluateGDNFloat32(inputs: GDNProjectionInputs, input: MLXArray, rank: Int?,
                                check: () throws -> Void) throws -> GDNFloat32ProjectionEvaluation {
    let parameters = try inputs.fusedParameters(rank: rank, check: check)
    let x = input.asType(.float32)
    let scales = parameters.scales.asType(.float32), biases = parameters.biases.asType(.float32)
    eval(x, scales, biases)
    try check()
    let projection = QuantizedLinear(weight: parameters.weight, scales: scales, biases: biases,
                                     groupSize: 64, bits: 4, mode: .affine)
    projection.freeze()
    let output = projection(x)
    eval(output)
    try check()
    let castBack = output.asType(input.dtype)
    eval(castBack)
    try check()
    let width = rank == nil ? inputs.fusedWidth : inputs.fusedWidth / 2
    guard output.shape == [1, input.shape[1], width], output.dtype == .float32,
          castBack.shape == output.shape, castBack.dtype == input.dtype else {
        throw ProbeError("Float32 GDN projection or final cast changed geometry/dtype")
    }
    return GDNFloat32ProjectionEvaluation(rank: rank,
        input: try GDNProjectionTensorIdentity(x, check: check),
        fusedWeight: try GDNProjectionTensorIdentity(parameters.weight, check: check),
        fusedScales: try GDNProjectionTensorIdentity(scales, check: check),
        fusedBiases: try GDNProjectionTensorIdentity(biases, check: check),
        selections: parameters.selections, selectionSHA256: sha256(try canonicalJSONData(parameters.selections)),
        components: parameters.components,
        output: try GDNProjectionValues(output, maximumValues: 32 * 32768, check: check),
        nativeCastOutput: try GDNProjectionValues(castBack, maximumValues: 32 * 32768, check: check))
}

private func evaluateGDNPadded(inputs: GDNProjectionInputs, input: MLXArray, rank: Int,
                               check: () throws -> Void) throws -> GDNPaddedProjectionEvaluation {
    let parameters = try inputs.fusedParameters(rank: rank, check: check)
    let realRows = inputs.fusedWidth / 2, zeroRows = inputs.fusedWidth - realRows
    func appendZeros(_ source: MLXArray) throws -> MLXArray {
        guard source.ndim == 2, source.shape[0] == realRows else {
            throw ProbeError("GDN end padding received invalid selected rows")
        }
        let zeros = MLXArray.zeros([zeroRows, source.shape[1]], dtype: source.dtype)
        let padded = concatenated([source, zeros], axis: 0)
        eval(padded)
        try check()
        // Byte verification covers packed words and both floating affine terms.
        // Use contiguous row slices, so no second full matrix host allocation is
        // needed. The independent CPU oracle also reconstructs these same bytes.
        let tail = padded[realRows..<inputs.fusedWidth]
        let zeroData = tail.asData(access: .noCopyIfContiguous).data
        try check()
        guard zeroData.allSatisfy({ $0 == 0 }) else {
            throw ProbeError("GDN appended affine-zero rows have nonzero bytes")
        }
        return padded
    }
    let weight = try appendZeros(parameters.weight)
    let scales = try appendZeros(parameters.scales)
    let biases = try appendZeros(parameters.biases)
    let projection = QuantizedLinear(weight: weight, scales: scales, biases: biases,
                                     groupSize: 64, bits: 4, mode: .affine)
    projection.freeze()
    let paddedOutput = projection(input)
    eval(paddedOutput)
    try check()
    let output = paddedOutput[0..., 0..., 0..<realRows]
    eval(output)
    try check()
    guard paddedOutput.shape == [1, input.shape[1], inputs.fusedWidth],
          output.shape == [1, input.shape[1], realRows],
          paddedOutput.dtype == input.dtype, output.dtype == input.dtype else {
        throw ProbeError("Padded GDN projection or cropping changed geometry/dtype")
    }
    return GDNPaddedProjectionEvaluation(rank: rank, realRows: realRows, paddedRows: inputs.fusedWidth,
        appendedZeroRows: zeroRows, cropRows: [0, realRows], zeroPaddingValidated: true,
        input: try GDNProjectionTensorIdentity(input, check: check),
        selections: parameters.selections, selectionSHA256: sha256(try canonicalJSONData(parameters.selections)),
        components: parameters.components,
        fusedWeight: try GDNProjectionTensorIdentity(weight, check: check),
        fusedScales: try GDNProjectionTensorIdentity(scales, check: check),
        fusedBiases: try GDNProjectionTensorIdentity(biases, check: check),
        paddedOutput: try GDNProjectionValues(paddedOutput, maximumValues: 32 * 32768, check: check),
        output: try GDNProjectionValues(output, maximumValues: 32 * 32768, check: check))
}
