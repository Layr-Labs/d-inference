import MLX

/// Explicit experiment entry, never a default GatherQMM dispatch replacement.
/// Routing stays on-device. No sort, padding, CPU route readback or reduction
/// of expert outputs is introduced. The caller still owns admission/evaluation.
enum GemmaSmallGatherQMV {
    enum InputLayout: String, CaseIterable { case tokenRows, assignmentRows }

    static func project(_ x: MLXArray, weight: MLXArray, scales: MLXArray,
                        biases: MLXArray, indices: MLXArray,
                        layout: InputLayout) throws -> MLXArray {
        guard indices.ndim == 2, (1...3).contains(indices.dim(0)), indices.dim(1) == 8,
              indices.dtype == .uint32, weight.ndim == 3, (8...128).contains(weight.dim(0)),
              weight.dtype == .uint32, [DType.bfloat16, .float32].contains(x.dtype),
              scales.dtype == x.dtype, biases.dtype == x.dtype else {
            throw ProbeError("Small gathered QMV requires exact BF16/F32 W4/G64 three-row geometry")
        }
        let tokens = indices.dim(0), n = weight.dim(1), k = weight.dim(2) * 8
        guard (k == 2816 && n == 704) || (k == 704 && n == 2816),
              scales.shape == [weight.dim(0),n,k/64], biases.shape == scales.shape,
              x.shape == (layout == .tokenRows ? [tokens,k] : [tokens,8,k]) else {
            throw ProbeError("Small gathered QMV projection or input layout differs")
        }
        return GemmaSmallGatherQMVKernel.value([x, weight, scales, biases, indices],
            template: [("T", x.dtype), ("K", k), ("N", n),
                       ("A", tokens * 8), ("E", weight.dim(0)), ("VPT", 8), ("Bits", 4), ("TokenRows", layout == .tokenRows)],
            grid: (64,n/8,tokens*8), threadGroup: (64,1,1),
            outputShapes: [[tokens,8,n]], outputDTypes: [x.dtype])[0]
    }

    /// Actual unchanged gathered-QMV baseline, with the same broadcast geometry
    /// as unsorted SwitchLinear; never pass a sorted hint for this layout.
    static func reference(_ x: MLXArray, weight: MLXArray, scales: MLXArray,
                          biases: MLXArray, indices: MLXArray,
                          layout: InputLayout) -> MLXArray {
        let input = layout == .tokenRows
            ? expandedDimensions(x, axes: [-2,-3]) : expandedDimensions(x, axis: -2)
        return gatherQuantizedMM(input, weight, scales: scales, biases: biases,
            rhsIndices: indices, transpose: true, groupSize: 64, bits: 4,
            mode: .affine, sortedIndices: false).squeezed(axis: -2)
    }
}
