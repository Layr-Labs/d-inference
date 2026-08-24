import Foundation
import Metal

func bfloatBits(_ value: Float) -> UInt16 {
    if value.isNaN {
        return UInt16(value.bitPattern >> 16) | 0x0040
    }
    var bits = value.bitPattern
    bits &+= 0x7fff &+ ((bits >> 16) & 1)
    return UInt16(bits >> 16)
}

func orderedFloatBits(_ value: Float) -> UInt32 {
    let bits = value.bitPattern
    return (bits & 0x8000_0000) == 0 ? bits | 0x8000_0000 : ~bits
}

@discardableResult
func xorshift64(_ state: inout UInt64) -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
}

func makeSharedBuffer(
    device: MTLDevice,
    elementCount: Int,
    elementStride: Int,
    label: String
) throws -> MTLBuffer {
    let (length, overflow) = elementCount.multipliedReportingOverflow(by: elementStride)
    guard !overflow, length > 0, UInt64(length) <= device.maxBufferLength else {
        throw ProbeFailure.message(
            "\(label): requested buffer length is invalid or exceeds maxBufferLength")
    }
    guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
        throw ProbeFailure.message("\(label): Metal buffer allocation failed")
    }
    buffer.label = label
    return buffer
}

func makeInputBuffers(
    device: MTLDevice,
    cell: BenchmarkCell,
    fixture: InputFixture
) throws -> (a: MTLBuffer, b: MTLBuffer) {
    let a = try makeSharedBuffer(
        device: device,
        elementCount: cell.elementCountA,
        elementStride: MemoryLayout<UInt16>.stride,
        label: "\(cell.name)-\(fixture.rawValue)-A-bf16")
    let b = try makeSharedBuffer(
        device: device,
        elementCount: cell.elementCountB,
        elementStride: MemoryLayout<UInt16>.stride,
        label: "\(cell.name)-\(fixture.rawValue)-B-bf16")
    let aValues = a.contents().bindMemory(
        to: UInt16.self, capacity: cell.elementCountA)
    let bValues = b.contents().bindMemory(
        to: UInt16.self, capacity: cell.elementCountB)

    switch fixture {
    case .qmmScale:
        var state: UInt64 = 0x6a09_e667_f3bc_c909
            ^ UInt64(cell.m) ^ (UInt64(cell.n) << 17) ^ (UInt64(cell.k) << 37)
        for index in 0..<cell.elementCountA {
            let raw = Int(xorshift64(&state) & 0x7ff) - 1024
            aValues[index] = bfloatBits(Float(raw) / 256.0)
        }
        for index in 0..<cell.elementCountB {
            let raw = Int(xorshift64(&state) & 0x7ff) - 1024
            bValues[index] = bfloatBits(Float(raw) / 512.0)
        }

    case .mixedExponent:
        var state: UInt64 = 0xbb67_ae85_84ca_a73b
            ^ UInt64(cell.m) ^ (UInt64(cell.n) << 19) ^ (UInt64(cell.k) << 41)
        func sample() -> Float {
            let random = xorshift64(&state)
            let signedMantissa = Float(Int((random >> 8) & 0xff) - 128) / 128.0
            let exponent = Int((random >> 32) % 17) - 8
            return signedMantissa * Foundation.pow(2.0, Float(exponent))
        }
        for index in 0..<cell.elementCountA {
            aValues[index] = bfloatBits(sample())
        }
        for index in 0..<cell.elementCountB {
            bValues[index] = bfloatBits(sample())
        }

    case .cancellation:
        let patterns: [[Float]] = [
            [
                65_536, 1, 1, 1, 1, 1, 1, 1,
                -65_536, 1, 1, 1, 1, 1, 1, 1,
            ],
            [
                1, 1, 1, 1, 1, 1, 1, 65_536,
                1, 1, 1, 1, 1, 1, 1, -65_536,
            ],
            [
                32_768, -32_768, 2, -2, 1, 1, 1, 1,
                16_384, -16_384, 2, -2, 1, 1, 1, 1,
            ],
            [
                4_096, 0.5, -4_096, 0.5, 2_048, 0.25, -2_048, 0.25,
                1_024, 0.125, -1_024, 0.125, 512, 0.0625, -512, 0.0625,
            ],
        ]
        let rowScales: [Float] = [1, -1, 0.5, 2]
        for row in 0..<cell.m {
            let scale = rowScales[row % rowScales.count]
            for inner in 0..<cell.k {
                aValues[row * cell.k + inner] = bfloatBits(scale)
            }
        }
        for inner in 0..<cell.k {
            for column in 0..<cell.n {
                let pattern = patterns[column % patterns.count]
                bValues[inner * cell.n + column] =
                    bfloatBits(pattern[inner % pattern.count])
            }
        }
    }

    return (a, b)
}

func fnv1a(_ values: UnsafePointer<Float>, count: Int) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for index in 0..<count {
        let bits = values[index].bitPattern
        hash ^= UInt64(bits & 0xff)
        hash &*= 0x0000_0100_0000_01b3
        hash ^= UInt64((bits >> 8) & 0xff)
        hash &*= 0x0000_0100_0000_01b3
        hash ^= UInt64((bits >> 16) & 0xff)
        hash &*= 0x0000_0100_0000_01b3
        hash ^= UInt64((bits >> 24) & 0xff)
        hash &*= 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", hash)
}

func compareOutputs(
    reference: MTLBuffer,
    actual: MTLBuffer,
    elementCount: Int
) -> ComparisonResult {
    let expectedValues = UnsafePointer(
        reference.contents().bindMemory(to: Float.self, capacity: elementCount))
    let observedValues = UnsafePointer(
        actual.contents().bindMemory(to: Float.self, capacity: elementCount))

    var referenceScale: Float = 0
    for index in 0..<elementCount {
        referenceScale = max(referenceScale, abs(expectedValues[index]))
    }
    let qwenAbsoluteTolerance = max(Float(0.01), 4 * referenceScale / 256)

    var changedFP32 = 0
    var changedBF16 = 0
    var nonFinite = 0
    var maxAbsolute: Float = 0
    var maxULP: UInt64 = 0
    var qmmTolerance = true
    var qwenTolerance = true

    for index in 0..<elementCount {
        let expected = expectedValues[index]
        let observed = observedValues[index]
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
        maxULP = max(
            maxULP,
            expectedOrder > observedOrder
                ? expectedOrder - observedOrder
                : observedOrder - expectedOrder)
        qmmTolerance = qmmTolerance
            && difference <= Float(0.001) + Float(0.001) * abs(expected)
        qwenTolerance = qwenTolerance
            && difference <= qwenAbsoluteTolerance + Float(0.02) * abs(expected)
    }

    return ComparisonResult(
        changedFP32: changedFP32,
        changedBF16: changedBF16,
        maxAbsolute: maxAbsolute,
        maxULP: maxULP,
        qmmTolerance: qmmTolerance,
        qwenTolerance: qwenTolerance,
        nonFinite: nonFinite,
        referenceHash: fnv1a(expectedValues, count: elementCount),
        actualHash: fnv1a(observedValues, count: elementCount))
}
