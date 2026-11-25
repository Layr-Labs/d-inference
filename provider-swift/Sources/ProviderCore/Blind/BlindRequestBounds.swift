import Foundation
import os

/// The signed bounds of one blind request, which the engine bridge holds every
/// submission of the request to (`EngineV2Bridge.submitTokenized`): every
/// engine path a request can take, the managed Super owner's included, submits
/// through it. The first submission's tokenized prompt must fit the prompt
/// bound; a later one (a loop exit's continuation) carries the request's own
/// output and is not compared. No submission may generate more than the output
/// bound.
final class BlindRequestBounds: Sendable {
    /// Set around a blind request's stream start; nil for every other request.
    @TaskLocal static var current: BlindRequestBounds?

    struct PromptBoundExceeded: Error, Equatable {}

    let maxTokens: Int
    let promptTokenBound: Int
    private let state = OSAllocatedUnfairLock<(admitted: Bool, exceeded: Bool)>(initialState: (false, false))

    init(_ terms: BlindServingTerms) {
        maxTokens = terms.maxTokens
        promptTokenBound = terms.promptTokenBound
    }

    /// The output a submission may generate: what it asks for, never more than
    /// the signed bound; the bound when it asks for nothing.
    func outputLimit(requested: Int?) -> Int {
        min(requested ?? maxTokens, maxTokens)
    }

    /// Whether a submission of `promptTokens` tokens may proceed: the first
    /// one only within the prompt bound, every later one.
    func admit(promptTokens: Int) -> Bool {
        state.withLock { state in
            guard !state.admitted else { return true }
            state.admitted = true
            state.exceeded = promptTokens > promptTokenBound
            return !state.exceeded
        }
    }

    /// Whether a submission reached the bridge, so the bounds were applied.
    var wereApplied: Bool { state.withLock { $0.admitted } }

    /// Whether the first submission's prompt was over the bound.
    var promptBoundExceeded: Bool { state.withLock { $0.exceeded } }
}
