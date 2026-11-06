import MLX

/// Explicit private experiment; callers select it directly. No default/env gate.
/// Supports the registered attention W4 and dense/router W8 matrix geometries.
enum GemmaSmallDenseQMV {
    struct Geometry {
        let k: Int, n: Int, bits: Int
        var label: String { "w\(bits)-k\(k)-n\(n)" }
        var valuesPerLane: Int {
            let singlePack = 32 / bits
            return k % (singlePack * 2 * 32) == 0 ? singlePack * 2 : singlePack
        }
    }
    static let geometries: [Geometry] = [
        .init(k:2816,n:4096,bits:4), .init(k:2816,n:2048,bits:4),
        .init(k:2816,n:8192,bits:4), .init(k:2816,n:1024,bits:4),
        .init(k:4096,n:2816,bits:4), .init(k:8192,n:2816,bits:4),
        .init(k:2816,n:2112,bits:8), .init(k:2112,n:2816,bits:8),
        .init(k:2816,n:128,bits:8),
    ]
    static func project(_ x: MLXArray, weight: MLXArray, scales: MLXArray,
                        biases: MLXArray, geometry g: Geometry) throws -> MLXArray {
        guard geometries.contains(where: { $0.k == g.k && $0.n == g.n && $0.bits == g.bits }),
              x.ndim == 2, (1...3).contains(x.dim(0)), x.dim(1) == g.k,
              [DType.bfloat16,.float32].contains(x.dtype), weight.dtype == .uint32,
              scales.dtype == x.dtype, biases.dtype == x.dtype,
              weight.shape == [g.n,g.k*g.bits/32], scales.shape == [g.n,g.k/64],
              biases.shape == scales.shape else { throw ProbeError("Dense small QMV contract differs") }
        return kernel([x,weight,scales,biases],
            template:[("T",x.dtype),("K",g.k),("N",g.n),("M",x.dim(0)),
                      ("VPT",g.valuesPerLane),("Bits",g.bits),("TokenRows",false)],
            grid:(64,g.n/8,1),threadGroup:(64,1,1),
            outputShapes:[[x.dim(0),g.n]],outputDTypes:[x.dtype])[0]
    }
    static func ordinary(_ x: MLXArray, weight: MLXArray, scales: MLXArray,
                         biases: MLXArray, bits: Int) -> MLXArray {
        quantizedMM(x,weight,scales:scales,biases:biases,transpose:true,
                    groupSize:64,bits:bits,mode:.affine)
    }
    static let kernel = MLXFast.metalKernel(
        name:"gemma_small_dense_m1_order_qmv_v1",
        inputNames:["x","w","scales","biases"],outputNames:["out"],
        source:#"""
        const uint lane = thread_position_in_threadgroup.x % 32;
        const uint simd = thread_position_in_threadgroup.x / 32;
        const uint out_row = threadgroup_position_in_grid.y * 8 + simd * 4;
        const uint expert = 0;
        const uint count = M;
        const uint members[3] = {0,1,2};
        """# + GemmaSmallQMVArithmetic.body,
        ensureRowContiguous:true)
}
