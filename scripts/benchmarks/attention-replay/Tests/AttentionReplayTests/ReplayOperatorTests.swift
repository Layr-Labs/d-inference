import Foundation
import MLX
import Testing
@_spi(Benchmarking) import MLXLMCommon

/// GPU fixtures invoke actual operators. They are not model or release tests.
@Suite(.serialized)
struct ReplayOperatorTests {
    private func tensor(_ values: [Float], shape: [Int], dtype: DType) -> CBv2AttentionReplay.Tensor {
        var bytes = Data()
        for value in values {
            if dtype == .float32 {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            } else {
                let word: UInt16
                if dtype == .float16 { word = Float16(value).bitPattern }
                else {
                    let raw = value.bitPattern
                    word = UInt16((raw &+ 0x7fff &+ ((raw >> 16) & 1)) >> 16)
                }
                var bits = word.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
        }
        return .init(bytes: bytes, shape: shape, dtype: dtype)
    }

    private func floats(_ tensor: CBv2AttentionReplay.Tensor) -> [Float] {
        tensor.bytes.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: tensor.dtype.size).map { offset in
                if tensor.dtype == .float32 {
                    return Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                }
                let bits = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                return tensor.dtype == .float16 ? Float(Float16(bitPattern: bits)) : Float(bitPattern: UInt32(bits) << 16)
            }
        }
    }

    private func fixture(dtype: DType, dimension: Int, length: Int, widerQuery: Bool = false)
        -> CBv2AttentionReplay.Input {
        let heads = 16, kvHeads = 2
        let q = (0..<(heads * dimension)).map { widerQuery ? Float($0 % 7 - 3) * 0.01371 : 0 }
        let keys = (0..<(kvHeads * length * dimension)).map { Float($0 % 11 - 5) * 0.03125 }
        let values = (0..<(kvHeads * length * dimension)).map { index -> Float in
            let head = index / (length * dimension), token = (index / dimension) % length
            return Float(head + 1) + Float(index % dimension) / 1024
                + (token == length - 1 ? Float(length * 2) : 0)
        }
        let k = tensor(keys, shape: [1, kvHeads, length, dimension], dtype: dtype)
        let v = tensor(values, shape: k.shape, dtype: dtype)
        func tail(_ source: CBv2AttentionReplay.Tensor) -> CBv2AttentionReplay.Tensor {
            let rowBytes = dimension * dtype.size
            var raw = Data()
            for head in 0..<kvHeads {
                let start = (head * length + length - 1) * rowBytes
                raw.append(source.bytes[start..<(start + rowBytes)])
            }
            return .init(bytes: raw, shape: [1, kvHeads, 1, dimension], dtype: dtype)
        }
        return .init(queries: tensor(q, shape: [1, heads, 1, dimension], dtype: widerQuery ? .float32 : dtype),
            storedKeys: k, storedValues: v, incomingKeys: tail(k), incomingValues: tail(v),
            scaleBits: (1 / Float(dimension).squareRoot()).bitPattern)
    }

    /// Independent Double loop. Uniform-Q long fixtures reduce exactly to a mean;
    /// the nonuniform wider-Q fixture is kept short to bound CPU work.
    private func reference(_ input: CBv2AttentionReplay.Input) -> [Float] {
        let q = floats(input.queries), k = floats(input.storedKeys), v = floats(input.storedValues)
        let d = input.queries.shape[3], length = input.storedKeys.shape[2]
        let qh = input.queries.shape[1], kh = input.storedKeys.shape[1]
        let scale = Double(Float(bitPattern: input.scaleBits))
        var output = [Float](repeating: 0, count: qh * d)
        for head in 0..<qh {
            let kv = head / (qh / kh)
            var scores = [Double](repeating: 0, count: length)
            if q.contains(where: { $0 != 0 }) {
                for token in 0..<length {
                    for channel in 0..<d {
                        scores[token] += Double(q[head * d + channel]) * Double(k[(kv * length + token) * d + channel]) * scale
                    }
                }
            }
            let maximum = scores.max()!
            let weights = scores.map { exp($0 - maximum) }, denominator = weights.reduce(0, +)
            for channel in 0..<d {
                var value = 0.0
                for token in 0..<length { value += weights[token] * Double(v[(kv * length + token) * d + channel]) }
                output[head * d + channel] = Float(value / denominator)
            }
        }
        return output
    }

    private func verify(_ input: CBv2AttentionReplay.Input) throws {
        let expected = reference(input)
        var actual = [CBv2AttentionReplay.Arm: CBv2AttentionReplay.Result]()
        for arm in CBv2AttentionReplay.Arm.allCases {
            let result = try CBv2AttentionReplay.run(input, arm: arm)
            #expect(result.output.dtype == input.queries.dtype)
            #expect(result.offset == input.storedKeys.shape[2])
            if arm != .nativeSDPA {
                #expect(result.storedKeys?.bytes == input.storedKeys.bytes)
                #expect(result.storedValues?.bytes == input.storedValues.bytes)
                #expect(result.dispatch == (arm == .pagedFixed ? "paged_fixed_decode" : "paged_segmented_decode"))
            }
            actual[arm] = result
        }
        func error(_ arm: CBv2AttentionReplay.Arm) -> Double {
            let got = floats(actual[arm]!.output)
            let residual = zip(got, expected).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) }
            let magnitude = expected.reduce(0.0) { $0 + pow(Double($1), 2) }
            return sqrt(residual / magnitude)
        }
        // Existing CBv2PagedKernelTests differential bars, unchanged.
        let native = error(.nativeSDPA)
        #expect(native <= 1e-2)
        #expect(error(.pagedFixed) <= max(3 * native, 1e-2))
        #expect(error(.pagedSegmented) <= max(3 * native, 1e-2))
        #expect(actual[.pagedFixed]?.output.bytes == actual[.pagedSegmented]?.output.bytes)
    }

    @Test(arguments: [DType.float16, .bfloat16, .float32], [64, 128, 256, 512])
    func actualOperatorsAcrossNativeDtypesAndHeadDimensions(dtype: DType, dimension: Int) throws {
        try verify(fixture(dtype: dtype, dimension: dimension, length: 257))
    }

    @Test(arguments: [15, 16, 17, 255, 256, 257, 4095, 4096, 4097, 5585])
    func actualFusedTailAcrossPagePartitionAndSegmentBoundaries(length: Int) throws {
        try verify(fixture(dtype: .bfloat16, dimension: 256, length: length))
    }

    @Test(arguments: [DType.float16, .bfloat16])
    func actualOriginalWiderQueryAndOutwardDtype(dtype: DType) throws {
        try verify(fixture(dtype: dtype, dimension: 64, length: 33, widerQuery: true))
    }

    @Test func hostValidationRejectsTruncationNonfiniteAndChangedTailWithoutGPU() throws {
        let original = fixture(dtype: .float32, dimension: 64, length: 17)
        _ = try CBv2AttentionReplay.validate(original)
        for bytes in [Data(original.incomingValues.bytes.dropLast()),
                      Data(repeating: 0, count: original.incomingValues.bytes.count)] {
            let bad = CBv2AttentionReplay.Input(queries: original.queries, storedKeys: original.storedKeys,
                storedValues: original.storedValues, incomingKeys: original.incomingKeys,
                incomingValues: .init(bytes: bytes, shape: original.incomingValues.shape, dtype: .float32),
                scaleBits: original.scaleBits)
            #expect(throws: (any Error).self) { try CBv2AttentionReplay.validate(bad) }
        }
        let invalidQ = tensor([Float](repeating: .infinity, count: 16 * 64), shape: [1, 16, 1, 64], dtype: .float32)
        let bad = CBv2AttentionReplay.Input(queries: invalidQ, storedKeys: original.storedKeys,
            storedValues: original.storedValues, incomingKeys: original.incomingKeys,
            incomingValues: original.incomingValues, scaleBits: original.scaleBits)
        #expect(throws: (any Error).self) { try CBv2AttentionReplay.validate(bad) }
    }
}
