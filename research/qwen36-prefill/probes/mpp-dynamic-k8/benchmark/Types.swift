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

struct ShapeParameters {
    var m: UInt32
    var n: UInt32
    var k: UInt32
}

struct BenchmarkCell {
    let name: String
    let m: Int
    let n: Int
    let k: Int
    let modelDispatchCount: Int

    var elementCountA: Int { m * k }
    var elementCountB: Int { k * n }
    var elementCountC: Int { m * n }
    var flops: Double { 2.0 * Double(m) * Double(n) * Double(k) }

    var parameters: ShapeParameters {
        ShapeParameters(m: UInt32(m), n: UInt32(n), k: UInt32(k))
    }

    func validate() throws {
        guard m > 0, n > 0, k > 0 else {
            throw ProbeFailure.message("\(name): dimensions must be positive")
        }
        guard m % 16 == 0, n % 32 == 0 else {
            throw ProbeFailure.message(
                "\(name): M must be divisible by 16 and N by 32")
        }
        guard k % 16 == 0 else {
            throw ProbeFailure.message(
                "\(name): K must be divisible by both K=8 and K=16 controls")
        }
        guard m <= Int(UInt32.max), n <= Int(UInt32.max), k <= Int(UInt32.max) else {
            throw ProbeFailure.message("\(name): dimensions exceed UInt32")
        }
    }
}

enum KernelVariant: String, CaseIterable {
    case steelK8 = "steel-k8"
    case mppStaticK16 = "mpp-static-k16"
    case mppDynamicK8 = "mpp-dynamic-k8"

    var functionName: String {
        switch self {
        case .steelK8:
            return "steel_k8_explicit_fp32"
        case .mppStaticK16:
            return "mpp_static_k16_explicit_fp32"
        case .mppDynamicK8:
            return "mpp_dynamic_k8_explicit_fp32"
        }
    }
}

enum InputFixture: String, CaseIterable {
    case qmmScale = "qmm-scale"
    case mixedExponent = "mixed-exponent"
    case cancellation = "cancellation"
}

struct ExecutionTiming {
    let gpuMilliseconds: Double
    let cpuMilliseconds: Double
}

struct TimingSummary {
    let minimum: Double
    let p10: Double
    let median: Double
    let p90: Double
    let maximum: Double
}

struct ComparisonResult {
    let changedFP32: Int
    let changedBF16: Int
    let maxAbsolute: Float
    let maxULP: UInt64
    let qmmTolerance: Bool
    let qwenTolerance: Bool
    let nonFinite: Int
    let referenceHash: String
    let actualHash: String

    var legal: Bool {
        qmmTolerance && qwenTolerance && nonFinite == 0
    }

    func line(prefix: String, elementCount: Int) -> String {
        [
            prefix,
            "fp32_changed=\(changedFP32)/\(elementCount)",
            "bf16_changed=\(changedBF16)/\(elementCount)",
            "max_abs=\(formatSignificant(Double(maxAbsolute)))",
            "max_ulp=\(maxULP)",
            "qmm_1e-3=\(qmmTolerance ? "pass" : "fail")",
            "qwen_existing=\(qwenTolerance ? "pass" : "fail")",
            "nonfinite=\(nonFinite)",
            "reference_hash=\(referenceHash)",
            "actual_hash=\(actualHash)",
        ].joined(separator: " ")
    }
}

func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
    precondition(!sortedValues.isEmpty)
    let position = fraction * Double(sortedValues.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    if lower == upper {
        return sortedValues[lower]
    }
    let weight = position - Double(lower)
    return sortedValues[lower] * (1.0 - weight) + sortedValues[upper] * weight
}

func summarize(_ values: [Double]) throws -> TimingSummary {
    guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
        throw ProbeFailure.message("timing sample set is empty or non-finite")
    }
    let sorted = values.sorted()
    return TimingSummary(
        minimum: sorted[0],
        p10: percentile(sorted, fraction: 0.10),
        median: percentile(sorted, fraction: 0.50),
        p90: percentile(sorted, fraction: 0.90),
        maximum: sorted[sorted.count - 1])
}

func deliveredTFLOPS(flops: Double, milliseconds: Double) -> Double {
    flops / (milliseconds * 1.0e9)
}

func formatMilliseconds(_ value: Double) -> String {
    String(format: "%.6f", value)
}

func formatTFLOPS(_ value: Double) -> String {
    String(format: "%.4f", value)
}

func formatSignificant(_ value: Double) -> String {
    String(format: "%.9g", value)
}
