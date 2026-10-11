import Foundation

extension QwenResidentContextLimits {
    /// The request bounds of a registered model: derived from its declared
    /// context, or the earlier reservation for a model without a row. Kept
    /// apart from the specification, which tools compile without these limits.
    init(specification: QwenDenseRegisteredSpecification) throws {
        self = try .derived(declaredContextTokens: specification.declaredContextTokens)
    }
}
