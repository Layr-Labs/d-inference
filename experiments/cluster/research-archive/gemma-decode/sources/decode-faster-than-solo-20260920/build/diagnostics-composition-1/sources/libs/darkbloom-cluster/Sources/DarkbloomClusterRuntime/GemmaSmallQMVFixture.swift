import Foundation
import MLX

/// Stored packed matrices only; no quantize/model loader changes. Exact fixture
/// construction is outside every timed primitive. One matrix is live at a time.
enum GemmaSmallQMVFixture {
    struct Matrix {
        let weight: MLXArray, scales: MLXArray, biases: MLXArray
    }
    static func matrix(experts: Int, k: Int, n: Int, bits: Int,
                       dtype: DType, salt: UInt32, check: () throws -> Void) throws -> Matrix {
        try check()
        let shape = experts == 1 ? [n,k*bits/32] : [experts,n,k*bits/32]
        var packed = Data(count: experts*n*k*bits/8)
        packed.withUnsafeMutableBytes { bytes in
            let words = bytes.bindMemory(to:UInt32.self)
            for i in words.indices {
                let value = UInt32(i) &* 1_664_525 &+ salt &* 1_013_904_223
                words[i] = (value ^ (value >> 11)).littleEndian
            }
        }
        try check()
        let weight = MLXArray(packed,shape,dtype:.uint32); try check()
        let metadataShape = experts == 1 ? [n,k/64] : [experts,n,k/64]
        func metadata(_ bias: Bool) throws -> MLXArray {
            try check()
            var bytes = Data(count:experts*n*(k/64)*dtype.size)
            bytes.withUnsafeMutableBytes { raw in
                for i in 0..<(experts*n*k/64) {
                    let sign: Float = (i + Int(salt)) % 3 == 0 ? -1 : 1
                    let scale = Float(8 + (i * 7 + Int(salt)) % 23) / 2048
                    let value = bias ? sign * Float(1 + i % 11) * scale : scale
                    if dtype == .bfloat16 {
                        raw.bindMemory(to:UInt16.self)[i] = UInt16(value.bitPattern >> 16).littleEndian
                    } else {
                        raw.bindMemory(to:UInt32.self)[i] = value.bitPattern.littleEndian
                    }
                }
            }
            try check()
            let value = MLXArray(bytes,metadataShape,dtype:dtype); try check(); return value
        }
        return try Matrix(weight:weight,scales:metadata(false),biases:metadata(true))
    }
    static func input(rows: Int, k: Int, dtype: DType, cancellation: Bool) -> MLXArray {
        var values: [Float] = []; values.reserveCapacity(rows*k)
        let magnitudes: [Float] = [1/128,1/4,1,4,16]
        for row in 0..<rows {
            for column in 0..<k {
                let value = Float((row*31+column*7)%97-48) / 64
                let magnitude = cancellation ? magnitudes[(column/2+row)%magnitudes.count] : 1
                let sign: Float = cancellation && column%2 == 0 ? -1 : 1
                values.append(value*magnitude*sign)
            }
        }
        return MLXArray(values,[rows,k]).asType(dtype)
    }
}
