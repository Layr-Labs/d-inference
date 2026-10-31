import Foundation

extension QwenResidentContextLimits {
    /// The request bounds a registered model advertises and admits: its
    /// declared context cut to the standard request, or the whole declared
    /// context for a row that serves it (`nativeOutputTokens`); the earlier
    /// reservation for a model without a row. Kept apart from the
    /// specification, which tools compile without these limits.
    init(specification: QwenDenseRegisteredSpecification) throws {
        guard let declared = specification.declaredContextTokens else { self = .reservation; return }
        self = try .init(declaredContextTokens: declared,
            ceiling: specification.nativeOutputTokens.map { .native(outputTokens: $0) } ?? .standard)
    }

    /// The request every LOAD gate and the memory plan size a registered model
    /// for: the standard request cut to its declared context, which is its
    /// advertised limits unless the row serves its native context. The
    /// pipeline modes serve up to it; tensor parallel charges a longer request
    /// at its own context when a rank reserves it.
    init(memoryOf specification: QwenDenseRegisteredSpecification) throws {
        self = try .derived(declaredContextTokens: specification.declaredContextTokens)
    }
}
