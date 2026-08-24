import Darwin
import Foundation
import Metal

private let tileM = 16
private let tileN = 32
private let groupK = 64
private let elementCount = tileM * tileN
private let qmmRTolerance: Float = 1e-3
private let qmmATolerance: Float = 1e-3

private enum ProbeFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value):
            return value
        }
    }
}

private struct Fixture {
    let activations: [UInt16]
    let codes: [UInt8]
    let scales: [UInt16]
    let biases: [UInt16]
}

private struct Comparison {
    let passed: Bool
    let mismatches: Int
    let maxAbsoluteError: Float
    let firstMismatch: String
}

private func bfloatBits(_ value: Float) -> UInt16 {
    if value.isNaN {
        return UInt16(value.bitPattern >> 16) | 0x0040
    }
    var bits = value.bitPattern
    bits &+= 0x7fff &+ ((bits >> 16) & 1)
    return UInt16(bits >> 16)
}

private func bfloatValue(_ bits: UInt16) -> Float {
    Float(bitPattern: UInt32(bits) << 16)
}

private func packLowNibbleFirst(_ codes: [UInt8]) throws -> [UInt8] {
    guard codes.count.isMultiple(of: 2) else {
        throw ProbeFailure.message("uint4 code count must be even")
    }
    var packed = [UInt8](repeating: 0, count: codes.count / 2)
    for index in stride(from: 0, to: codes.count, by: 2) {
        guard codes[index] < 16, codes[index + 1] < 16 else {
            throw ProbeFailure.message("uint4 fixture contains a code above 15")
        }
        packed[index / 2] = codes[index] | (codes[index + 1] << 4)
    }
    return packed
}

private func makeMappingFixture() -> Fixture {
    var activations = [UInt16](repeating: 0, count: tileM * groupK)
    for row in 0..<tileM {
        activations[row * groupK + row] = bfloatBits(1)
    }

    // Codes are logically [K,N]. Adjacent N elements occupy the low and high
    // nibbles of each byte. Varying both axes detects nibble reversal and
    // signed interpretation of codes 8...15.
    var codes = [UInt8](repeating: 0, count: groupK * tileN)
    for inner in 0..<groupK {
        for column in 0..<tileN {
            codes[inner * tileN + column] = UInt8((inner + column) % 16)
        }
    }
    return Fixture(
        activations: activations,
        codes: codes,
        scales: [UInt16](repeating: bfloatBits(1), count: tileN),
        biases: [UInt16](repeating: bfloatBits(0), count: tileN)
    )
}

private func makeRoundingAdversary() -> Fixture {
    // For every output column:
    //   x = [-7.125, 8.125], q = [15, 13], s = 3.609375, b = 2.984375
    //
    // Factored Candidate B:
    //   s * (-7.125*15 + 8.125*13) + b * (-7.125 + 8.125)
    //   = -1.52734375
    //
    // Incumbent one-round BF16 weight reconstruction:
    //   BF16(15*s+b) = 57, BF16(13*s+b) = 50
    //   -7.125*57 + 8.125*50 = 0.125
    //
    // The 1.65234375 difference is far outside rtol=atol=1e-3 and does
    // not depend on a long or ill-conditioned reduction.
    var activations = [UInt16](repeating: 0, count: tileM * groupK)
    for row in 0..<tileM {
        activations[row * groupK] = bfloatBits(-7.125)
        activations[row * groupK + 1] = bfloatBits(8.125)
    }

    var codes = [UInt8](repeating: 0, count: groupK * tileN)
    for column in 0..<tileN {
        codes[column] = 15
        codes[tileN + column] = 13
    }
    return Fixture(
        activations: activations,
        codes: codes,
        scales: [UInt16](repeating: bfloatBits(3.609375), count: tileN),
        biases: [UInt16](repeating: bfloatBits(2.984375), count: tileN)
    )
}

private func factoredReference(_ fixture: Fixture) -> [Float] {
    var output = [Float](repeating: 0, count: elementCount)
    for row in 0..<tileM {
        var sumX: Float = 0
        for inner in 0..<groupK {
            sumX += bfloatValue(fixture.activations[row * groupK + inner])
        }
        for column in 0..<tileN {
            var qDot: Float = 0
            for inner in 0..<groupK {
                let x = bfloatValue(fixture.activations[row * groupK + inner])
                qDot += x * Float(fixture.codes[inner * tileN + column])
            }
            let scale = bfloatValue(fixture.scales[column])
            let bias = bfloatValue(fixture.biases[column])
            output[row * tileN + column] = scale * qDot + bias * sumX
        }
    }
    return output
}

private func incumbentReference(_ fixture: Fixture) -> [Float] {
    var output = [Float](repeating: 0, count: elementCount)
    for row in 0..<tileM {
        for column in 0..<tileN {
            let scale = bfloatValue(fixture.scales[column])
            let bias = bfloatValue(fixture.biases[column])
            var accumulator: Float = 0
            for inner in 0..<groupK {
                let x = bfloatValue(fixture.activations[row * groupK + inner])
                let reconstructed =
                    scale * Float(fixture.codes[inner * tileN + column]) + bias
                let roundedWeight = bfloatValue(bfloatBits(reconstructed))
                accumulator += x * roundedWeight
            }
            output[row * tileN + column] = accumulator
        }
    }
    return output
}

private func compare(
    expected: [Float],
    actual: [Float],
    rtol: Float,
    atol: Float
) -> Comparison {
    precondition(expected.count == actual.count)
    var mismatches = 0
    var maxAbsoluteError: Float = 0
    var firstMismatch = "none"
    for index in expected.indices {
        let expectedValue = expected[index]
        let actualValue = actual[index]
        let difference = abs(expectedValue - actualValue)
        maxAbsoluteError = max(maxAbsoluteError, difference)
        let close =
            expectedValue.isFinite && actualValue.isFinite
            && difference <= atol + rtol * abs(expectedValue)
        if !close {
            mismatches += 1
            if firstMismatch == "none" {
                firstMismatch =
                    "index=\(index) expected=\(expectedValue) actual=\(actualValue)"
            }
        }
    }
    return Comparison(
        passed: mismatches == 0,
        mismatches: mismatches,
        maxAbsoluteError: maxAbsoluteError,
        firstMismatch: firstMismatch
    )
}

private func comparisonLine(_ label: String, _ comparison: Comparison) -> String {
    "\(label)=\(comparison.passed ? "pass" : "fail")"
        + " mismatches=\(comparison.mismatches)/\(elementCount)"
        + " max_abs=\(String(format: "%.9g", comparison.maxAbsoluteError))"
        + " first=\"\(comparison.firstMismatch)\""
}

private func makeBuffer<T>(
    device: MTLDevice,
    values: [T],
    label: String
) throws -> MTLBuffer {
    try values.withUnsafeBytes { bytes in
        guard let address = bytes.baseAddress,
              let buffer = device.makeBuffer(
                  bytes: address,
                  length: bytes.count,
                  options: .storageModeShared)
        else {
            throw ProbeFailure.message("failed to allocate \(label) buffer")
        }
        buffer.label = label
        return buffer
    }
}

private final class PreparedDispatch {
    let inputs: [MTLBuffer]
    let output: MTLBuffer

    init(device: MTLDevice, fixture: Fixture) throws {
        inputs = try [
            makeBuffer(device: device, values: fixture.activations, label: "activations-bf16"),
            makeBuffer(
                device: device,
                values: packLowNibbleFirst(fixture.codes),
                label: "codes-uint4"),
            makeBuffer(device: device, values: fixture.scales, label: "scales-bf16"),
            makeBuffer(device: device, values: fixture.biases, label: "biases-bf16"),
        ]
        let byteCount = elementCount * MemoryLayout<Float>.stride
        guard let output = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw ProbeFailure.message("failed to allocate FP32 output buffer")
        }
        output.label = "candidate-output-fp32"
        memset(output.contents(), 0, byteCount)
        self.output = output
    }

    func values() -> [Float] {
        let pointer = output.contents().bindMemory(to: Float.self, capacity: elementCount)
        return Array(UnsafeBufferPointer(start: pointer, count: elementCount))
    }
}

private final class Runner {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    init(metallibPath: String) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ProbeFailure.message("Metal device unavailable")
        }
        guard let queue = device.makeCommandQueue() else {
            throw ProbeFailure.message("Metal command queue unavailable")
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: metallibPath))
        guard let function = library.makeFunction(name: "e9_native_uint4_affine_group64") else {
            throw ProbeFailure.message("metallib lacks E9 kernel")
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        guard pipeline.threadExecutionWidth == 32 else {
            throw ProbeFailure.message(
                "expected SIMD width 32, got \(pipeline.threadExecutionWidth)")
        }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    private func encode(_ encoder: MTLComputeCommandEncoder, prepared: PreparedDispatch) {
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in prepared.inputs.enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }
        encoder.setBuffer(prepared.output, offset: 0, index: 4)
        encoder.dispatchThreadgroups(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1)
        )
    }

    private func submit(prepared: PreparedDispatch, dispatches: Int) throws {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw ProbeFailure.message("failed to create Metal command encoder")
        }
        for _ in 0..<dispatches {
            encode(encoder, prepared: prepared)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.status != .completed {
            let detail = commandBuffer.error?.localizedDescription ?? "no command-buffer error"
            throw ProbeFailure.message(
                "command status \(commandBuffer.status.rawValue): \(detail)")
        }
    }

    func run(_ fixture: Fixture) throws -> [Float] {
        let prepared = try PreparedDispatch(device: device, fixture: fixture)
        try submit(prepared: prepared, dispatches: 1)
        return prepared.values()
    }

    func benchmark(_ fixture: Fixture) throws -> (medianNanoseconds: Double, tflops: Double) {
        let prepared = try PreparedDispatch(device: device, fixture: fixture)
        try submit(prepared: prepared, dispatches: 20)

        let dispatchesPerSample = 2_000
        var samples: [Double] = []
        for _ in 0..<7 {
            let start = DispatchTime.now().uptimeNanoseconds
            try submit(prepared: prepared, dispatches: dispatchesPerSample)
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / Double(dispatchesPerSample))
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let usefulOperations = 2.0 * Double(tileM * tileN * groupK)
        let tflops = usefulOperations / (median * 1e-9) / 1e12
        return (median, tflops)
    }
}

private func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw ProbeFailure.message("usage: e9-native-uint4 <kernel.metallib>")
    }
    let runner = try Runner(metallibPath: CommandLine.arguments[1])
    print("DEVICE=\(runner.device.name)")
    print("OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("SHAPE=M\(tileM)xK\(groupK)xN\(tileN) representative_of=M64xK2048xN1024")
    print("MPP=bfloat_x_uint4b_format_to_float relaxed_precision=false")
    print("PACKING=logical_KxN_low_nibble_first")

    let mapping = makeMappingFixture()
    let mappingExpected = factoredReference(mapping)
    let mappingActual = try runner.run(mapping)
    let mappingComparison = compare(
        expected: mappingExpected,
        actual: mappingActual,
        rtol: 0,
        atol: 0
    )
    print(comparisonLine("UNSIGNED_CODE_MAPPING", mappingComparison))
    guard mappingComparison.passed else {
        print("TIMING=skipped reason=unsigned_code_mapping")
        print("VERDICT=reject reason=uint4_unsigned_or_packing_contract")
        exit(2)
    }

    let adversary = makeRoundingAdversary()
    let factored = factoredReference(adversary)
    let incumbent = incumbentReference(adversary)
    let candidate = try runner.run(adversary)
    let implementationComparison = compare(
        expected: factored,
        actual: candidate,
        rtol: qmmRTolerance,
        atol: qmmATolerance
    )
    print(comparisonLine("FACTORED_ALGEBRA", implementationComparison))
    print(
        "ADVERSARY_VALUES"
            + " candidate=\(candidate[0])"
            + " factored=\(factored[0])"
            + " incumbent=\(incumbent[0])"
    )
    guard implementationComparison.passed else {
        print("TIMING=skipped reason=factored_algebra_mismatch")
        print("VERDICT=reject reason=kernel_or_runtime_mismatch")
        exit(2)
    }

    let incumbentComparison = compare(
        expected: incumbent,
        actual: candidate,
        rtol: qmmRTolerance,
        atol: qmmATolerance
    )
    print(comparisonLine("ADVERSARIAL_INCUMBENT", incumbentComparison))
    let incumbentBF16 = incumbent.map { bfloatValue(bfloatBits($0)) }
    let candidateBF16 = candidate.map { bfloatValue(bfloatBits($0)) }
    let incumbentBF16Comparison = compare(
        expected: incumbentBF16,
        actual: candidateBF16,
        rtol: qmmRTolerance,
        atol: qmmATolerance
    )
    print(comparisonLine("ADVERSARIAL_INCUMBENT_BF16_OUTPUT", incumbentBF16Comparison))
    guard incumbentComparison.passed, incumbentBF16Comparison.passed else {
        print("TIMING=skipped reason=adversarial_incumbent_tolerance")
        print("VERDICT=reject reason=per_weight_bf16_rounding_contract")
        exit(2)
    }

    guard ProcessInfo.processInfo.environment["E9_ALLOW_TIMING"] == "1" else {
        print("TIMING=skipped reason=power_posture")
        print("VERDICT=correctness-pass timing=not-run")
        return
    }
    let timing = try runner.benchmark(adversary)
    print(
        "TIMING=run"
            + " median_ns=\(String(format: "%.1f", timing.medianNanoseconds))"
            + " useful_tflops=\(String(format: "%.4f", timing.tflops))"
    )
    print("VERDICT=correctness-pass timing=measured_no-serving-claim")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}
