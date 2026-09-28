import Foundation
import MLX
import MLXNN

private func precisionRoundBF16(_ value: Float) -> Float {
    let bits = value.bitPattern
    let rounded = (bits &+ 0x7fff &+ ((bits >> 16) & 1)) & 0xffff0000
    return Float(bitPattern: rounded)
}

private func precisionBF16Data(_ values: [Float]) -> Data {
    var bytes = Data()
    for value in values {
        precondition(value.isFinite && value.bitPattern & 0xffff == 0)
        var bits = UInt16(value.bitPattern >> 16).littleEndian
        withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
    }
    return bytes
}

private struct PrecisionProjectionFixture {
    let rows: Int
    let inputWidth: Int
    let outputWidth = 128
    let words: [UInt32]
    let scales: [Float]
    let offsets: [Float]
    let input: [Float]

    init(rows: Int, inputWidth: Int) {
        self.rows = rows; self.inputWidth = inputWidth
        var words: [UInt32] = [], scales: [Float] = [], offsets: [Float] = []
        for output in 0..<128 {
            for group in 0..<(inputWidth / 64) {
                let scale = precisionRoundBF16(Float((output * 13 + group * 7) % 17 + 9) / 1024)
                scales.append(scale)
                offsets.append(precisionRoundBF16(-7 * scale + Float((output + group) % 5 - 2) / 1024))
            }
            for word in 0..<(inputWidth / 8) {
                var packed: UInt32 = 0
                for lane in 0..<8 {
                    let column = word * 8 + lane
                    let quantized = UInt32((output * 17 + column * 7 + (column / 64) * 3) % 16)
                    packed |= quantized << UInt32(4 * lane)
                }
                words.append(packed)
            }
        }
        var state: UInt32 = 0x5EED317
        var input: [Float] = []
        for _ in 0..<(rows * inputWidth) {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            input.append(precisionRoundBF16(Float(Int(state % 4093) - 2046) / 4093))
        }
        self.words = words; self.scales = scales; self.offsets = offsets; self.input = input
    }

    func arrays() -> (linear: QuantizedLinear, input: MLXArray) {
        let weight = MLXArray(words).reshaped(outputWidth, inputWidth / 8)
        let metadataShape = [outputWidth, inputWidth / 64]
        let linear = QuantizedLinear(weight: weight,
            scales: MLXArray(precisionBF16Data(scales), metadataShape, dtype: .bfloat16),
            biases: MLXArray(precisionBF16Data(offsets), metadataShape, dtype: .bfloat16),
            groupSize: 64, bits: 4, mode: .affine)
        let x = MLXArray(precisionBF16Data(input), [rows, inputWidth], dtype: .bfloat16)
        return (linear, x)
    }

    /// Decode each little-endian W4 nibble, apply its stored BF16 affine
    /// parameters, and dot against BF16-rounded input using CPU Double sums.
    /// No MLX dequantization or GPU floating reference participates in this oracle.
    func oracle(columns: Range<Int>) -> [Double] {
        var result: [Double] = []
        for row in 0..<rows {
            for output in 0..<outputWidth {
                var total = 0.0
                for column in columns {
                    let word = words[output * (inputWidth / 8) + column / 8]
                    let nibble = (word >> UInt32((column % 8) * 4)) & 0xf
                    let group = output * (inputWidth / 64) + column / 64
                    let weight = Double(nibble) * Double(scales[group]) + Double(offsets[group])
                    total += Double(input[row * inputWidth + column]) * weight
                }
                result.append(total)
            }
        }
        return result
    }
}

private struct PrecisionProjectionError: Encodable {
    let comparedValues: Int
    let maximumAbsoluteError: Double
    let relativeRMSError: Double
}

private func precisionProjectionError(_ array: MLXArray, reference: [Double], dtype: DType,
                                      rows: Int) throws -> PrecisionProjectionError {
    guard array.dtype == dtype, array.shape == [rows, 128] else {
        throw ProbeError("Attention precision check observed an incorrect output dtype or shape")
    }
    let actual = array.asType(.float32).asArray(Float.self)
    guard actual.count == reference.count else { throw ProbeError("Precision oracle length mismatch") }
    var maximum = 0.0, squares = 0.0, referenceSquares = 0.0
    for (value, expected) in zip(actual, reference) {
        guard value.isFinite, expected.isFinite else { throw ProbeError("Nonfinite attention projection value") }
        let delta = Double(value) - expected
        maximum = max(maximum, abs(delta)); squares += delta * delta
        referenceSquares += expected * expected
    }
    return PrecisionProjectionError(comparedValues: actual.count, maximumAbsoluteError: maximum,
                                    relativeRMSError: sqrt(squares / max(referenceSquares, 1e-30)))
}

private func precisionProjectionShard(_ source: QuantizedLinear, columns: Range<Int>) throws -> QuantizedLinear {
    let words = (columns.lowerBound / 8)..<(columns.upperBound / 8)
    let groups = (columns.lowerBound / 64)..<(columns.upperBound / 64)
    return try QuantizedLinear(
        weight: copySelectedTensor(source.weight, selection: .axis(1, [words])),
        scales: copySelectedTensor(source.scales, selection: .axis(1, [groups])),
        biases: source.biases.map { try copySelectedTensor($0, selection: .axis(1, [groups])) },
        groupSize: 64, bits: 4, mode: .affine)
}

private struct PrecisionProjectionResult: Encodable {
    let kind = "attention_output_precision_projection"
    let rows: Int
    let inputWidth: Int
    let outputWidth = 128
    let groupSize = 64
    let groupsPerShard: Int
    let inputDType = "bfloat16"
    let metadataDType = "bfloat16"
    let packedWeightDType = "uint32"
    let float32AbsoluteTolerance = 0.00005
    let float32RelativeRMSTolerance = 0.00002
    let float32Solo: PrecisionProjectionError
    let float32Partials: [PrecisionProjectionError]
    let float32TwoPartSum: PrecisionProjectionError
    let float32SoloCastBack: PrecisionProjectionError
    let float32TwoPartCastBack: PrecisionProjectionError
    let nativeSolo: PrecisionProjectionError
    let nativeTwoPartSum: PrecisionProjectionError
    let promoteOnlyAfterLocalResult: PrecisionProjectionError
    let promoteOnlyAfterLocalResultIsDiagnostic = true
    let cpuOracleUsesStoredBF16ParametersAndDoubleAccumulation = true
    let float32RetainedThroughManualReduction = true
    let wrapperRetainsExactStoredParameterArrays = true
    let wrapperCastBackMatchesFloat32Projection = true
    let realCollectiveExercised = false
    let correctnessOnly = true
}

func checkPrecisionProjection() throws {
    // Four/six/eight source G64 groups exercise two/three/four local groups;
    // the odd three-group shard is deliberately not a power-of-two-only case.
    for width in [256, 384, 512] {
        for rows in [1, 32] { try emitJSON(checkPrecisionProjection(rows: rows, width: width)) }
    }
}

private func checkPrecisionProjection(rows: Int, width: Int) throws -> PrecisionProjectionResult {
    let fixture = PrecisionProjectionFixture(rows: rows, inputWidth: width)
    let (source, input) = fixture.arrays()
    let native = try AttentionOutputLinear(source: source, precision: .native)
    let precise = try AttentionOutputLinear(source: source, precision: .float32)
    for wrapper in [native, precise] {
        guard wrapper.weight === source.weight, wrapper.scales === source.scales,
            wrapper.biases === source.biases else { throw ProbeError("Precision wrapper replaced stored parameter arrays") }
    }
    let reference = fixture.oracle(columns: 0..<width)
    let rawSolo = precise(input.asType(.float32))
    let preciseSolo = precise(input)
    let nativeSolo = native(input)
    guard preciseSolo.dtype == .bfloat16, nativeSolo.dtype == .bfloat16,
        preciseSolo.asData().data == rawSolo.asType(.bfloat16).asData().data,
        nativeSolo.asData().data == source(input).asData().data else {
        throw ProbeError("Precision wrapper changed native behavior or cast before its projection")
    }
    var f32Parts: [MLXArray] = [], nativeParts: [MLXArray] = []
    var partialErrors: [PrecisionProjectionError] = []
    for rank in 0..<2 {
        let columns = (rank * width / 2)..<((rank + 1) * width / 2)
        let shard = try precisionProjectionShard(source, columns: columns)
        let localInput = try copySelectedTensor(input, selection: .axis(1, [columns]))
        let localF32 = try AttentionOutputLinear(source: shard, precision: .float32)(localInput.asType(.float32))
        let localNative = try AttentionOutputLinear(source: shard, precision: .native)(localInput)
        guard localF32.dtype == .float32, localNative.dtype == .bfloat16 else {
            throw ProbeError("Attention projection did not retain the requested local precision")
        }
        partialErrors.append(try precisionProjectionError(localF32,
            reference: fixture.oracle(columns: columns), dtype: .float32, rows: rows))
        f32Parts.append(localF32); nativeParts.append(localNative)
    }
    // This manual reduction reproduces the wrapper's F32-before-sum ordering;
    // it deliberately does not pretend to test transport or collective execution.
    let f32Sum = f32Parts[0] + f32Parts[1]
    let nativeSum = nativeParts[0] + nativeParts[1]
    let latePromotedSum = nativeParts[0].asType(.float32) + nativeParts[1].asType(.float32)
    guard f32Sum.dtype == .float32, latePromotedSum.dtype == .float32 else {
        throw ProbeError("Attention precision reduction lost Float32")
    }
    let soloError = try precisionProjectionError(rawSolo, reference: reference, dtype: .float32, rows: rows)
    let sumError = try precisionProjectionError(f32Sum, reference: reference, dtype: .float32, rows: rows)
    for error in [soloError, sumError] + partialErrors {
        guard error.maximumAbsoluteError <= 0.00005, error.relativeRMSError <= 0.00002 else {
            throw ProbeError("Float32 attention projection differs from decoded CPU dot oracle: max=\(error.maximumAbsoluteError), RMS=\(error.relativeRMSError)")
        }
    }
    guard source.weight.dtype == .uint32, source.scales.dtype == .bfloat16,
        source.biases?.dtype == .bfloat16, source.weight.asArray(UInt32.self) == fixture.words,
        source.scales.asData().data == precisionBF16Data(fixture.scales),
        source.biases?.asData().data == precisionBF16Data(fixture.offsets) else {
        throw ProbeError("Precision projection changed stored packed weights or metadata")
    }
    return try PrecisionProjectionResult(rows: rows, inputWidth: width, groupsPerShard: width / 128,
        float32Solo: soloError, float32Partials: partialErrors, float32TwoPartSum: sumError,
        float32SoloCastBack: precisionProjectionError(preciseSolo, reference: reference, dtype: .bfloat16, rows: rows),
        float32TwoPartCastBack: precisionProjectionError(f32Sum.asType(.bfloat16), reference: reference, dtype: .bfloat16, rows: rows),
        nativeSolo: precisionProjectionError(nativeSolo, reference: reference, dtype: .bfloat16, rows: rows),
        nativeTwoPartSum: precisionProjectionError(nativeSum, reference: reference, dtype: .bfloat16, rows: rows),
        promoteOnlyAfterLocalResult: precisionProjectionError(latePromotedSum.asType(.bfloat16),
            reference: reference, dtype: .bfloat16, rows: rows))
}
