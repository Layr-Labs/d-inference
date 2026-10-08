import Foundation

/// Closed qualification envelope, not a serving capacity/admission policy.
/// Gemma E128 reaches the sorted-RHS path at64 prompt rows; both64 and128
/// are compared to the unchanged full-bank operator before any serving claim.
enum ExpertAxisQualificationLimits {
    static let maximumTokens = 128
    static let maximumAssignments = maximumTokens * 8
    static let baseCases = [1, 7, 8, 9, 33]
    static let extendedCases = baseCases + [64, 128]
    static func cases(experts: Int) -> [Int] {
        // Small synthetic cardinalities retain their qualified domain. Their
        // extreme local density can cross a different kernel tile threshold.
        experts == 128 ? extendedCases : baseCases
    }
}
