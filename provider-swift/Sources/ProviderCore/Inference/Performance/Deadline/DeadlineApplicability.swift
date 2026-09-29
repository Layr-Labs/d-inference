import Foundation

/// Preconditions measured with this deadline profile. Zero quiescence is an
/// explicit independently reviewed policy; an omitted field never means zero.
struct DeadlineApplicability: Sendable, Hashable {
    let minimumWholeMacQuiescenceMs: Int
    let minimumNominalStabilityMs: Int
    let powerMode: String

    var isValid: Bool {
        (0...180_000).contains(minimumWholeMacQuiescenceMs)
            && (5_000...180_000).contains(minimumNominalStabilityMs)
            && powerMode == "automatic"
    }
}
