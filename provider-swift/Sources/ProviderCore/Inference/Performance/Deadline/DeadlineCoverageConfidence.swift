import Foundation

enum DeadlineCoverageConfidence {
    /// Verify the Python qualifier's minimum one-sided 95% Clopper-Pearson
    /// bound: P[X >= covered | p=target] <= .05. The cell validator first bounds
    /// the combined training/validation population to 10000 and requires
    /// 0 < target < 1. Log-space accumulation avoids underflow and allocation;
    /// the empirical coverage fraction alone is insufficient evidence.
    static func supports(total: Int, covered: Int, target: Double) -> Bool {
        let logN: Double = lgamma(Double(total + 1))
        var maximum = -Double.infinity, sum = 0.0
        for count in covered...total {
            let term = logN - lgamma(Double(count + 1)) - lgamma(Double(total - count + 1))
                + Double(count) * log(target) + Double(total - count) * log1p(-target)
            if term > maximum {
                sum = sum * exp(maximum - term) + 1
                maximum = term
            } else {
                sum += exp(term - maximum)
            }
        }
        return exp(maximum) * sum <= 0.05
    }
}
