import Foundation
import MLX

/// Diagnostic scales for independently partitioned recurrent buffers. BF16 ULP
/// scales describe projection rounding; they are not a bound on FP32 recurrence.
struct GDNErrorSummary: Encodable {
    let values: Int
    let maximumAbsoluteError: Double
    let peakReferenceMagnitude: Double
    let referenceRMS: Double
    let relativeRMS: Double
    let referenceAtMaximumError: Double
    let candidateAtMaximumError: Double
    let peakBF16ULPSize: Double?
    let maximumErrorInPeakBF16ULPs: Double?
    // Local ULP scale at the element with the greatest absolute error only.
    let errorAtMaximumAbsoluteErrorInLocalBF16ULPs: Double?
}

struct GDNErrorAccumulator {
    private var values = 0
    private var maximum = 0.0, peak = 0.0, referenceSquares = 0.0, errorSquares = 0.0
    private var worstReference = 0.0, worstCandidate = 0.0

    mutating func add(_ reference: MLXArray, _ candidate: MLXArray) throws {
        guard reference.shape == candidate.shape else { throw ProbeError("GDN diagnostic buffer shape mismatch") }
        let lhs = reference.asType(.float32).asArray(Float.self)
        let rhs = candidate.asType(.float32).asArray(Float.self)
        for (x, y) in zip(lhs, rhs) {
            guard x.isFinite, y.isFinite else { throw ProbeError("Nonfinite GDN diagnostic buffer") }
            let a = Double(x), b = Double(y), delta = a - b
            if abs(delta) > maximum {
                maximum = abs(delta); worstReference = a; worstCandidate = b
            }
            peak = max(peak, abs(a)); referenceSquares += a * a; errorSquares += delta * delta
            values += 1
        }
    }

    func summary(bf16Scale: Bool = false) -> GDNErrorSummary {
        func ulp(_ magnitude: Double) -> Double {
            magnitude == 0 ? pow(2, -133) : pow(2, max(-133, floor(log2(abs(magnitude))) - 7))
        }
        return GDNErrorSummary(values: values, maximumAbsoluteError: maximum, peakReferenceMagnitude: peak,
            referenceRMS: sqrt(referenceSquares / Double(max(1, values))),
            relativeRMS: sqrt(errorSquares / max(referenceSquares, 1e-30)),
            referenceAtMaximumError: worstReference, candidateAtMaximumError: worstCandidate,
            peakBF16ULPSize: bf16Scale ? ulp(peak) : nil,
            maximumErrorInPeakBF16ULPs: bf16Scale ? maximum / ulp(peak) : nil,
            errorAtMaximumAbsoluteErrorInLocalBF16ULPs: bf16Scale ? maximum / ulp(worstReference) : nil)
    }
}

/// Each buffer has its own units and error scale. These are bounded synthetic
/// test budgets, not a quality qualification for a real checkpoint or workload.
struct GDNStateBudgetResult: Encodable {
    let observed: GDNErrorSummary
    let absoluteTolerance: Double
    let relativeRMSTolerance: Double?
    let peakBF16ULPTolerance: Double?
    let passed: Bool

    init(observed: GDNErrorSummary, absoluteTolerance: Double,
         relativeRMSTolerance: Double? = nil, peakBF16ULPTolerance: Double? = nil) {
        self.observed = observed; self.absoluteTolerance = absoluteTolerance
        self.relativeRMSTolerance = relativeRMSTolerance; self.peakBF16ULPTolerance = peakBF16ULPTolerance
        passed = observed.maximumAbsoluteError <= absoluteTolerance
            && (relativeRMSTolerance.map { observed.relativeRMS <= $0 } ?? true)
    }
}
