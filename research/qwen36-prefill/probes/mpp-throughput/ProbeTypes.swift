import Foundation

enum ProbeFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value):
            return value
        }
    }
}

enum Arm: String, CaseIterable {
    case mpp
    case steel
}

struct DenseShape {
    let label: String
    let m: Int
    let k: Int
    let n: Int

    // Real-model useful linear work represented by this K/N cell. The units
    // are GFLOP per source token and come from note 026's 40-layer ledger.
    let modelGFLOPsPerToken: Double

    var elementCount: Int {
        m * n
    }

    var usefulOperations: Double {
        2.0 * Double(m) * Double(k) * Double(n)
    }

    var threadgroupCount: Int {
        let outputTiles = (m / 16) * (n / 32)
        return outputTiles / 4
    }

    func validate() throws {
        guard m > 0, k > 0, n > 0,
              m.isMultiple(of: 16),
              k.isMultiple(of: 16),
              n.isMultiple(of: 32)
        else {
            throw ProbeFailure.message(
                "\(label) must be positive and divisible by M16/K16/N32")
        }
        guard ((m / 16) * (n / 32)).isMultiple(of: 4) else {
            throw ProbeFailure.message(
                "\(label) output tile count must divide four SIMD groups")
        }
        guard m <= Int(UInt32.max), k <= Int(UInt32.max), n <= Int(UInt32.max) else {
            throw ProbeFailure.message("\(label) exceeds 32-bit Metal dimensions")
        }
    }
}

struct DenseShapeParameters {
    var m: UInt32
    var k: UInt32
    var n: UInt32

    init(_ shape: DenseShape) {
        m = UInt32(shape.m)
        k = UInt32(shape.k)
        n = UInt32(shape.n)
    }
}

struct TimingSample {
    let arm: Arm
    let block: Int
    let position: String
    let gpuStartSeconds: Double
    let gpuEndSeconds: Double
    let kernelStartSeconds: Double
    let kernelEndSeconds: Double
    let cpuSeconds: Double

    var gpuSeconds: Double {
        gpuEndSeconds - gpuStartSeconds
    }

    var kernelSeconds: Double {
        kernelEndSeconds - kernelStartSeconds
    }
}

struct TimingSummary {
    let sampleCount: Int
    let gpuMedianSeconds: Double
    let gpuP10Seconds: Double
    let gpuP90Seconds: Double
    let gpuMinimumSeconds: Double
    let gpuMaximumSeconds: Double
    let cpuMedianSeconds: Double
}

struct Comparison {
    let passed: Bool
    let elementCount: Int
    let fp32Changed: Int
    let bf16Changed: Int
    let nonFinite: Int
    let maxAbsoluteError: Float
    let maxRelativeError: Float
    let qmmTolerancePassed: Bool
    let steelHash: String
    let mppHash: String
}

func bfloatBits(_ value: Float) -> UInt16 {
    if value.isNaN {
        return UInt16(value.bitPattern >> 16) | 0x0040
    }
    var bits = value.bitPattern
    bits &+= 0x7fff &+ ((bits >> 16) & 1)
    return UInt16(bits >> 16)
}

private func xorshift64(_ state: inout UInt64) -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
}

func makeBF16Fixture(count: Int, seed: UInt64) -> [UInt16] {
    var state = seed
    var result = [UInt16](repeating: 0, count: count)
    for index in result.indices {
        let random = xorshift64(&state)
        let signed = Int(random & 0x7ff) - 1024
        result[index] = bfloatBits(Float(signed) / 1024.0)
    }
    return result
}

private func updateFNV1a(_ hash: inout UInt64, floatBits: UInt32) {
    var littleEndian = floatBits.littleEndian
    withUnsafeBytes(of: &littleEndian) { bytes in
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
    }
}

func compareOutputs(
    steel: UnsafePointer<Float>,
    mpp: UnsafePointer<Float>,
    count: Int
) -> Comparison {
    var fp32Changed = 0
    var bf16Changed = 0
    var nonFinite = 0
    var maxAbsoluteError: Float = 0
    var maxRelativeError: Float = 0
    var qmmTolerancePassed = true
    var steelHash: UInt64 = 0xcbf2_9ce4_8422_2325
    var mppHash: UInt64 = 0xcbf2_9ce4_8422_2325

    for index in 0..<count {
        let expected = steel[index]
        let observed = mpp[index]
        updateFNV1a(&steelHash, floatBits: expected.bitPattern)
        updateFNV1a(&mppHash, floatBits: observed.bitPattern)

        if !expected.isFinite || !observed.isFinite {
            nonFinite += 1
        }
        if expected.bitPattern != observed.bitPattern {
            fp32Changed += 1
        }
        if bfloatBits(expected) != bfloatBits(observed) {
            bf16Changed += 1
        }

        let absoluteError = abs(expected - observed)
        maxAbsoluteError = max(maxAbsoluteError, absoluteError)
        if expected != 0 {
            maxRelativeError = max(maxRelativeError, absoluteError / abs(expected))
        } else if absoluteError != 0 {
            maxRelativeError = .infinity
        }
        qmmTolerancePassed = qmmTolerancePassed
            && absoluteError <= Float(0.001) + Float(0.001) * abs(expected)
    }

    // The ordinary QMM gate is tolerance-based, while the current serving
    // projection boundary is BF16. Require both, without widening either.
    let passed = nonFinite == 0 && qmmTolerancePassed && bf16Changed == 0
    return Comparison(
        passed: passed,
        elementCount: count,
        fp32Changed: fp32Changed,
        bf16Changed: bf16Changed,
        nonFinite: nonFinite,
        maxAbsoluteError: maxAbsoluteError,
        maxRelativeError: maxRelativeError,
        qmmTolerancePassed: qmmTolerancePassed,
        steelHash: String(format: "%016llx", steelHash),
        mppHash: String(format: "%016llx", mppHash)
    )
}

private func percentile(_ sorted: [Double], fraction: Double) -> Double {
    precondition(!sorted.isEmpty)
    let index = Int((fraction * Double(sorted.count - 1)).rounded())
    return sorted[max(0, min(sorted.count - 1, index))]
}

func summarize(_ samples: [TimingSample]) throws -> TimingSummary {
    guard samples.count >= 15 else {
        throw ProbeFailure.message(
            "timing summary requires >=15 samples, got \(samples.count)")
    }
    let gpu = samples.map(\.gpuSeconds).sorted()
    let cpu = samples.map(\.cpuSeconds).sorted()
    guard let gpuMinimum = gpu.first, let gpuMaximum = gpu.last else {
        throw ProbeFailure.message("timing summary received no samples")
    }

    func median(_ sorted: [Double]) -> Double {
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }

    return TimingSummary(
        sampleCount: samples.count,
        gpuMedianSeconds: median(gpu),
        gpuP10Seconds: percentile(gpu, fraction: 0.10),
        gpuP90Seconds: percentile(gpu, fraction: 0.90),
        gpuMinimumSeconds: gpuMinimum,
        gpuMaximumSeconds: gpuMaximum,
        cpuMedianSeconds: median(cpu)
    )
}

func usefulTFLOPS(operations: Double, seconds: Double) -> Double {
    operations / seconds / 1e12
}

func weightedEffectiveTFLOPS(
    shapes: [DenseShape],
    summaries: [String: TimingSummary],
    useGPU: Bool
) throws -> Double {
    var totalWeight = 0.0
    var weightedSecondsPerTFLOP = 0.0
    for shape in shapes {
        guard let summary = summaries[shape.label] else {
            throw ProbeFailure.message("missing timing summary for \(shape.label)")
        }
        let seconds = useGPU ? summary.gpuMedianSeconds : summary.cpuMedianSeconds
        let rate = usefulTFLOPS(operations: shape.usefulOperations, seconds: seconds)
        totalWeight += shape.modelGFLOPsPerToken
        weightedSecondsPerTFLOP += shape.modelGFLOPsPerToken / rate
    }
    return totalWeight / weightedSecondsPerTFLOP
}
