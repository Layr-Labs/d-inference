import Darwin
import Foundation
import Metal

private let m = 16
private let n = 32
private let k = 16
private let steelK = 8

private enum ProbeFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value):
            return value
        }
    }
}

private struct ProbeCase {
    let name: String
    let a: [UInt16]
    let b: [UInt16]
}

private struct Variant {
    let label: String
    let function: String
    let usesPaddedInputs: Bool
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

private func makeCancellationCase() -> ProbeCase {
    let patterns: [[Float]] = [
        [65_536, 1, 1, 1, 1, 1, 1, 1, -65_536, 1, 1, 1, 1, 1, 1, 1],
        [1, 1, 1, 1, 1, 1, 1, 65_536, 1, 1, 1, 1, 1, 1, 1, -65_536],
        [32_768, -32_768, 2, -2, 1, 1, 1, 1, 16_384, -16_384, 2, -2, 1, 1, 1, 1],
        [4_096, 0.5, -4_096, 0.5, 2_048, 0.25, -2_048, 0.25,
         1_024, 0.125, -1_024, 0.125, 512, 0.0625, -512, 0.0625],
    ]
    let rowScales: [Float] = [1, -1, 0.5, 2]
    var a = [UInt16](repeating: 0, count: m * k)
    var b = [UInt16](repeating: 0, count: k * n)
    for row in 0..<m {
        let scale = rowScales[row % rowScales.count]
        for inner in 0..<k {
            a[row * k + inner] = bfloatBits(scale)
        }
    }
    for inner in 0..<k {
        for column in 0..<n {
            b[inner * n + column] = bfloatBits(patterns[column % patterns.count][inner])
        }
    }
    return ProbeCase(name: "cancellation", a: a, b: b)
}

private func xorshift64(_ state: inout UInt64) -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
}

private func makeQMMScaleCase() -> ProbeCase {
    var state: UInt64 = 0x6a09_e667_f3bc_c909
    var a = [UInt16]()
    var b = [UInt16]()
    a.reserveCapacity(m * k)
    b.reserveCapacity(k * n)
    for _ in 0..<(m * k) {
        let raw = Int(xorshift64(&state) & 0x7ff) - 1024
        a.append(bfloatBits(Float(raw) / 256.0))
    }
    for _ in 0..<(k * n) {
        let raw = Int(xorshift64(&state) & 0x7ff) - 1024
        b.append(bfloatBits(Float(raw) / 512.0))
    }
    return ProbeCase(name: "qmm-scale", a: a, b: b)
}

private func makeMixedExponentCase() -> ProbeCase {
    var state: UInt64 = 0xbb67_ae85_84ca_a73b
    func sample() -> Float {
        let random = xorshift64(&state)
        let signedMantissa = Float(Int((random >> 8) & 0xff) - 128) / 128.0
        let exponent = Int((random >> 32) % 17) - 8
        return signedMantissa * Foundation.pow(2.0, Float(exponent))
    }
    return ProbeCase(
        name: "mixed-exponent",
        a: (0..<(m * k)).map { _ in bfloatBits(sample()) },
        b: (0..<(k * n)).map { _ in bfloatBits(sample()) }
    )
}

private func makePaddedInputs(_ testCase: ProbeCase) -> ([UInt16], [UInt16], [UInt16], [UInt16]) {
    var a0 = [UInt16](repeating: 0, count: m * k)
    var b0 = [UInt16](repeating: 0, count: k * n)
    var a1 = [UInt16](repeating: 0, count: m * k)
    var b1 = [UInt16](repeating: 0, count: k * n)
    for row in 0..<m {
        for inner in 0..<k {
            if inner < steelK {
                a0[row * k + inner] = testCase.a[row * k + inner]
            } else {
                a1[row * k + inner] = testCase.a[row * k + inner]
            }
        }
    }
    for inner in 0..<k {
        for column in 0..<n {
            if inner < steelK {
                b0[inner * n + column] = testCase.b[inner * n + column]
            } else {
                b1[inner * n + column] = testCase.b[inner * n + column]
            }
        }
    }
    return (a0, b0, a1, b1)
}

private func makeBuffer(device: MTLDevice, values: [UInt16]) throws -> MTLBuffer {
    try values.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress,
              let buffer = device.makeBuffer(
                  bytes: baseAddress,
                  length: bytes.count,
                  options: .storageModeShared)
        else {
            throw ProbeFailure.message("failed to allocate BF16 input buffer")
        }
        return buffer
    }
}

private func makeZeroOutput(device: MTLDevice) throws -> MTLBuffer {
    let length = m * n * MemoryLayout<Float>.stride
    guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
        throw ProbeFailure.message("failed to allocate FP32 output buffer")
    }
    memset(buffer.contents(), 0, length)
    return buffer
}

private final class Runner {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    private var pipelines: [String: MTLComputePipelineState] = [:]

    init(metallibPath: String) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ProbeFailure.message("Metal device unavailable")
        }
        guard let queue = device.makeCommandQueue() else {
            throw ProbeFailure.message("Metal command queue unavailable")
        }
        self.device = device
        self.queue = queue
        self.library = try device.makeLibrary(URL: URL(fileURLWithPath: metallibPath))
    }

    private func pipeline(named name: String) throws -> MTLComputePipelineState {
        if let cached = pipelines[name] {
            return cached
        }
        guard let function = library.makeFunction(name: name) else {
            throw ProbeFailure.message("metallib has no function \(name)")
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        guard pipeline.threadExecutionWidth == 32 else {
            throw ProbeFailure.message(
                "\(name) has unexpected SIMD width \(pipeline.threadExecutionWidth)")
        }
        pipelines[name] = pipeline
        return pipeline
    }

    func run(
        function name: String,
        inputs: [MTLBuffer],
        groups: MTLSize = MTLSize(width: 1, height: 1, depth: 1)
    ) throws -> [Float] {
        let pipeline = try pipeline(named: name)
        let output = try makeZeroOutput(device: device)
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw ProbeFailure.message("failed to create command encoder for \(name)")
        }
        encoder.label = name
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in inputs.enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }
        encoder.setBuffer(output, offset: 0, index: inputs.count)
        encoder.dispatchThreadgroups(
            groups,
            threadsPerThreadgroup: MTLSize(
                width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.status != .completed {
            let detail = commandBuffer.error?.localizedDescription ?? "no command-buffer error"
            throw ProbeFailure.message(
                "\(name) command status \(commandBuffer.status.rawValue): \(detail)")
        }
        let pointer = output.contents().bindMemory(to: Float.self, capacity: m * n)
        return Array(UnsafeBufferPointer(start: pointer, count: m * n))
    }
}

private func orderedFloatBits(_ value: Float) -> UInt32 {
    let bits = value.bitPattern
    return (bits & 0x8000_0000) == 0 ? bits | 0x8000_0000 : ~bits
}

private func fnv1a(_ values: [Float]) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for value in values {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
        }
    }
    return String(format: "%016llx", hash)
}

private func comparison(label: String, reference: [Float], actual: [Float]) -> String {
    var changedFP32 = 0
    var changedBF16 = 0
    var nonFinite = 0
    var maxAbsolute: Float = 0
    var maxULP: UInt64 = 0
    var qmmTolerance = true
    let referenceScale = reference.map(abs).max() ?? 0
    let qwenAbsoluteTolerance = max(Float(0.01), 4 * referenceScale / 256)
    var qwenTolerance = true

    for (expected, observed) in zip(reference, actual) {
        if !expected.isFinite || !observed.isFinite {
            nonFinite += 1
        }
        if expected.bitPattern != observed.bitPattern {
            changedFP32 += 1
        }
        if bfloatBits(expected) != bfloatBits(observed) {
            changedBF16 += 1
        }
        let difference = abs(expected - observed)
        maxAbsolute = max(maxAbsolute, difference)
        let expectedOrder = UInt64(orderedFloatBits(expected))
        let observedOrder = UInt64(orderedFloatBits(observed))
        maxULP = max(maxULP, expectedOrder > observedOrder
            ? expectedOrder - observedOrder
            : observedOrder - expectedOrder)
        qmmTolerance = qmmTolerance
            && difference <= Float(0.001) + Float(0.001) * abs(expected)
        qwenTolerance = qwenTolerance
            && difference <= qwenAbsoluteTolerance + Float(0.02) * abs(expected)
    }

    return [
        "VARIANT=\(label)",
        "status=ok",
        "hash=\(fnv1a(actual))",
        "fp32_changed=\(changedFP32)/\(reference.count)",
        "bf16_changed=\(changedBF16)/\(reference.count)",
        "max_abs=\(String(format: "%.9g", maxAbsolute))",
        "max_ulp=\(maxULP)",
        "qmm_1e-3=\(qmmTolerance ? "pass" : "fail")",
        "qwen_existing=\(qwenTolerance ? "pass" : "fail")",
        "nonfinite=\(nonFinite)",
    ].joined(separator: " ")
}

private func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw ProbeFailure.message("usage: mpp-reduction-probe <probe.metallib>")
    }
    let runner = try Runner(metallibPath: CommandLine.arguments[1])
    print("DEVICE=\(runner.device.name)")
    print("OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("SHAPE=M\(m)xN\(n)xK\(k) incumbent=two-K\(steelK)-Steel-calls strict=true")

    let variants = [
        Variant(
            label: "mpp-static-k16-macc-cooperative-inputs",
            function: "mpp_static_k16_macc_cooperative_inputs",
            usesPaddedInputs: false),
        Variant(
            label: "mpp-static-k16-macc-tensor-inputs",
            function: "mpp_static_k16_macc_tensor_inputs",
            usesPaddedInputs: false),
        Variant(
            label: "mpp-static-k16-multiply",
            function: "mpp_static_k16_multiply",
            usesPaddedInputs: false),
        Variant(
            label: "mpp-dynamic-k8-staged-macc",
            function: "mpp_dynamic_k8_staged_macc",
            usesPaddedInputs: false),
        Variant(
            label: "mpp-dynamic-k8-multiply-explicit-add",
            function: "mpp_dynamic_k8_multiply_explicit_add",
            usesPaddedInputs: false),
        Variant(
            label: "mpp-static-k16-zero-padded-multiply-explicit-add",
            function: "mpp_static_k16_padded_multiply_explicit_add",
            usesPaddedInputs: true),
    ]

    var runtimeErrors = 0
    for testCase in [makeQMMScaleCase(), makeMixedExponentCase(), makeCancellationCase()] {
        print("CASE=\(testCase.name)")
        let aBuffer = try makeBuffer(device: runner.device, values: testCase.a)
        let bBuffer = try makeBuffer(device: runner.device, values: testCase.b)
        let reference = try runner.run(
            function: "steel_k8x2_reference",
            inputs: [aBuffer, bBuffer],
            groups: MTLSize(width: n / 8, height: m / 8, depth: 1))
        print("REFERENCE=steel-k8x2 status=ok hash=\(fnv1a(reference))")

        let padded = makePaddedInputs(testCase)
        let paddedBuffers = try [
            makeBuffer(device: runner.device, values: padded.0),
            makeBuffer(device: runner.device, values: padded.1),
            makeBuffer(device: runner.device, values: padded.2),
            makeBuffer(device: runner.device, values: padded.3),
        ]
        for variant in variants {
            do {
                let inputs = variant.usesPaddedInputs ? paddedBuffers : [aBuffer, bBuffer]
                let actual = try runner.run(function: variant.function, inputs: inputs)
                print(comparison(label: variant.label, reference: reference, actual: actual))
            } catch {
                runtimeErrors += 1
                print("VARIANT=\(variant.label) status=error detail=\(error)")
            }
        }
    }
    print("RESULT=complete runtime_errors=\(runtimeErrors)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}
