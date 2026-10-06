import Foundation

/// The sole promoter certifies this exact recovery policy. Different windows
/// require independent qualification and an explicit policy revision.
struct DeadlineApplicability: Sendable, Hashable {
    let minimumWholeMacQuiescenceMs: Int
    let minimumNominalStabilityMs: Int
    let powerMode: String

    var isValid: Bool {
        minimumWholeMacQuiescenceMs == 20_000
            && minimumNominalStabilityMs == 5_000
            && powerMode == "automatic"
    }
}
