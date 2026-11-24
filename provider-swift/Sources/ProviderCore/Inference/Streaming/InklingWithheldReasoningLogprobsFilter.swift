// Copyright © 2026 Eigen Labs.

/// Red control: the declarations the tests read, with today's behaviour. An
/// Inkling request keeps the `<think>` filter (`WithheldReasoningLogprobsFilter`),
/// and the scheduler is unchanged.
struct InklingWithheldReasoningLogprobsFilter {
    private var inner = WithheldReasoningLogprobsFilter()

    mutating func visible(_ entries: [SSETokenLogprob]) -> [SSETokenLogprob] {
        inner.visible(entries)
    }
}

/// Red control: the selection the tests read.
enum WithheldReasoningLogprobs {
    case think(WithheldReasoningLogprobsFilter)
    case inkling(InklingWithheldReasoningLogprobsFilter)

    static func forRequest(
        withholdsReasoning: Bool, logprobs: Bool, inklingChannels: Bool, startsInThought: Bool
    ) -> WithheldReasoningLogprobs? {
        guard withholdsReasoning, logprobs else { return nil }
        return inklingChannels
            ? .inkling(InklingWithheldReasoningLogprobsFilter())
            : .think(WithheldReasoningLogprobsFilter(startsInThought: startsInThought))
    }

    mutating func visible(_ entries: [SSETokenLogprob]) -> [SSETokenLogprob] {
        switch self {
        case .think(var filter):
            let out = filter.visible(entries)
            self = .think(filter)
            return out
        case .inkling(var filter):
            let out = filter.visible(entries)
            self = .inkling(filter)
            return out
        }
    }
}
