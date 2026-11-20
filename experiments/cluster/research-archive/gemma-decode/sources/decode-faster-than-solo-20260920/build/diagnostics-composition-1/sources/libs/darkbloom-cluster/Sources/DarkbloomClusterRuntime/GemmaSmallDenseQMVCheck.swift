import Foundation
import MLX

enum GemmaSmallDenseQMVCheck {
    static func run(resources: GemmaSmallQMVResources, check: () throws -> Void,
                    native: () throws -> Void) throws -> [[String:Any]] {
        var reports: [[String:Any]] = []
        for dtype in [DType.bfloat16,.float32] {
            for (geometryIndex,g) in GemmaSmallDenseQMV.geometries.enumerated() {
                try resources.admit(experts:1,k:g.k,n:g.n,bits:g.bits,dtype:dtype); try check()
                try autoreleasepool {
                    let matrix = try GemmaSmallQMVFixture.matrix(experts:1,k:g.k,n:g.n,bits:g.bits,
                        dtype:dtype,salt:UInt32(101+geometryIndex),check:check)
                    eval(matrix.weight,matrix.scales,matrix.biases); try native()
                    try GemmaSmallQMVMeasurement.fence(native:native); try check()
                    for tokens in 1...3 {
                        for cancellation in [false,true] {
                            let row = try autoreleasepool { () throws -> [String:Any] in
                                try check()
                                let x = GemmaSmallQMVFixture.input(rows:tokens,k:g.k,dtype:dtype,cancellation:cancellation)
                                eval(x); try native(); try GemmaSmallQMVMeasurement.fence(native:native); try check()
                                return try GemmaSmallQMVMeasurement.compare(
                                    label:"dense/\(g.label)/\(dtype)/m\(tokens)/cancel-\(cancellation)",
                                    metadata:["kind":"dense","K":g.k,"N":g.n,"bits":g.bits,
                                        "dtype":"\(dtype)","rows":tokens,"valuesPerLane":g.valuesPerLane,
                                        "reference":"independent-ordinary-M1-quantizedMM","cancellationInput":cancellation],
                                    check:check,native:native,
                                    reference:{ (0..<tokens).map { row in
                                        GemmaSmallDenseQMV.ordinary(x[row..<(row+1)],weight:matrix.weight,
                                            scales:matrix.scales,biases:matrix.biases,bits:g.bits)
                                    } },
                                    candidate:{ [try GemmaSmallDenseQMV.project(x,weight:matrix.weight,
                                        scales:matrix.scales,biases:matrix.biases,geometry:g)] },
                                    ordinaryBatch:{ [GemmaSmallDenseQMV.ordinary(x,weight:matrix.weight,
                                        scales:matrix.scales,biases:matrix.biases,bits:g.bits)] })
                            }
                            reports.append(row); try check()
                        }
                    }
                }
                try GemmaSmallQMVMeasurement.fence(native:native)
                Memory.clearCache(); try check()
            }
        }
        return reports
    }
}
