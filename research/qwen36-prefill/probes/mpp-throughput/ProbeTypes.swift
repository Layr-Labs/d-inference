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

struct MPPCandidate: Hashable {
    let id: String
    let tileM: Int
    let tileN: Int
    let tileK: Int
    let scope: String
    let scopeSIMDGroups: Int
    let inputMode: String
    let metallibPath: String

    var threadsPerThreadgroup: Int {
        (scopeSIMDGroups == 1 ? 4 : scopeSIMDGroups) * 32
    }

    var outputTilesPerThreadgroup: Int {
        scopeSIMDGroups == 1 ? 4 : 1
    }

    static func loadManifest(path: String) throws -> [MPPCandidate] {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        var candidates: [MPPCandidate] = []
        var seen: Set<String> = []

        for (lineIndex, rawLine) in contents.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() {
            let line = String(rawLine)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let fields = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count == 8,
                  let tileM = Int(fields[1]),
                  let tileN = Int(fields[2]),
                  let tileK = Int(fields[3]),
                  let scopeSIMDGroups = Int(fields[5])
            else {
                throw ProbeFailure.message(
                    "invalid accepted-candidate manifest line \(lineIndex + 1): \(line)")
            }
            let candidate = MPPCandidate(
                id: fields[0],
                tileM: tileM,
                tileN: tileN,
                tileK: tileK,
                scope: fields[4],
                scopeSIMDGroups: scopeSIMDGroups,
                inputMode: fields[6],
                metallibPath: fields[7])
            try candidate.validateDefinition()
            guard seen.insert(candidate.id).inserted else {
                throw ProbeFailure.message("duplicate candidate id \(candidate.id)")
            }
            candidates.append(candidate)
        }
        return candidates
    }

    func validateDefinition() throws {
        guard !id.isEmpty,
              id.first?.isLetter == true,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else {
            throw ProbeFailure.message("\(id) is not a valid Metal function identifier")
        }
        guard tileM > 0, tileN > 0, tileK > 0,
              [16, 32, 64].contains(tileM),
              [16, 32, 64].contains(tileN),
              [16, 32].contains(tileK)
        else {
            throw ProbeFailure.message(
                "\(id) has out-of-sweep tile M\(tileM)N\(tileN)K\(tileK)")
        }
        let expectedScope: String
        switch scopeSIMDGroups {
        case 1:
            expectedScope = "execution_simdgroup"
        case 2:
            expectedScope = "execution_simdgroups_2"
        case 4:
            expectedScope = "execution_simdgroups_4"
        default:
            throw ProbeFailure.message(
                "\(id) has unsupported scope SIMD-group count \(scopeSIMDGroups)")
        }
        guard scope == expectedScope else {
            throw ProbeFailure.message(
                "\(id) scope \(scope) does not match \(scopeSIMDGroups) SIMD groups")
        }
        guard inputMode == "cooperative" || inputMode == "tensor" else {
            throw ProbeFailure.message(
                "\(id) has unsupported input mode \(inputMode)")
        }
    }
}

enum BenchmarkVariant: Hashable {
    case steel
    case mpp(MPPCandidate)

    var id: String {
        switch self {
        case .steel:
            return "steel_m16_n32_k8_sg1"
        case .mpp(let candidate):
            return candidate.id
        }
    }

    var candidate: MPPCandidate? {
        switch self {
        case .steel:
            return nil
        case .mpp(let candidate):
            return candidate
        }
    }
}

struct DenseShape {
    let label: String
    let m: Int
    let k: Int
    let n: Int

    var elementCount: Int {
        m * n
    }

    var usefulOperations: Double {
        2.0 * Double(m) * Double(k) * Double(n)
    }

    func validateForSteel() throws {
        guard m > 0, k > 0, n > 0,
              m.isMultiple(of: 16),
              k.isMultiple(of: 8),
              n.isMultiple(of: 32)
        else {
            throw ProbeFailure.message(
                "\(label) must be positive and divisible by Steel M16/K8/N32")
        }
        let outputTiles = (m / 16) * (n / 32)
        guard outputTiles.isMultiple(of: 4) else {
            throw ProbeFailure.message(
                "\(label) Steel output tile count must divide four SIMD groups")
        }
        guard m <= Int(UInt32.max), k <= Int(UInt32.max), n <= Int(UInt32.max) else {
            throw ProbeFailure.message("\(label) exceeds 32-bit Metal dimensions")
        }
    }

    func threadgroupCount(for variant: BenchmarkVariant) throws -> Int {
        try validateForSteel()
        guard let candidate = variant.candidate else {
            return ((m / 16) * (n / 32)) / 4
        }
        guard m.isMultiple(of: candidate.tileM),
              k.isMultiple(of: candidate.tileK),
              n.isMultiple(of: candidate.tileN)
        else {
            throw ProbeFailure.message(
                "\(candidate.id) does not tile \(label) exactly")
        }
        let outputTiles = (m / candidate.tileM) * (n / candidate.tileN)
        guard outputTiles.isMultiple(of: candidate.outputTilesPerThreadgroup) else {
            throw ProbeFailure.message(
                "\(candidate.id) output tile count does not fit its execution scope")
        }
        return outputTiles / candidate.outputTilesPerThreadgroup
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
    let variantID: String
    let round: Int
    let position: Int
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
    let kernelMedianSeconds: Double
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
        mppHash: String(format: "%016llx", mppHash))
}

private func percentile(_ sorted: [Double], fraction: Double) -> Double {
    precondition(!sorted.isEmpty)
    let index = Int((fraction * Double(sorted.count - 1)).rounded())
    return sorted[max(0, min(sorted.count - 1, index))]
}

private func median(_ sorted: [Double]) -> Double {
    precondition(!sorted.isEmpty)
    if sorted.count.isMultiple(of: 2) {
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
    return sorted[sorted.count / 2]
}

func summarize(_ samples: [TimingSample]) throws -> TimingSummary {
    guard samples.count >= 15 else {
        throw ProbeFailure.message(
            "timing summary requires >=15 samples, got \(samples.count)")
    }
    let gpu = samples.map(\.gpuSeconds).sorted()
    let kernel = samples.map(\.kernelSeconds).sorted()
    let cpu = samples.map(\.cpuSeconds).sorted()
    guard let gpuMinimum = gpu.first, let gpuMaximum = gpu.last else {
        throw ProbeFailure.message("timing summary received no samples")
    }

    return TimingSummary(
        sampleCount: samples.count,
        gpuMedianSeconds: median(gpu),
        gpuP10Seconds: percentile(gpu, fraction: 0.10),
        gpuP90Seconds: percentile(gpu, fraction: 0.90),
        gpuMinimumSeconds: gpuMinimum,
        gpuMaximumSeconds: gpuMaximum,
        kernelMedianSeconds: median(kernel),
        cpuMedianSeconds: median(cpu))
}

func usefulTFLOPS(operations: Double, seconds: Double) -> Double {
    operations / seconds / 1e12
}

func rotated<T>(_ values: [T], by offset: Int) -> [T] {
    guard !values.isEmpty else {
        return []
    }
    let normalized = offset % values.count
    return Array(values[normalized...]) + Array(values[..<normalized])
}
