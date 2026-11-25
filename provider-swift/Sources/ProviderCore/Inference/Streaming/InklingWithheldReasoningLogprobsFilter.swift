// Copyright © 2026 Eigen Labs.

/// Relay logprobs for every Inkling 2 request that asks for them, whether its
/// reasoning is returned or withheld (`Inkling2PromptContract.withholdsReasoning`):
/// `logprobs.content` holds the answer's tokens only, so they join to `content`.
/// Inkling does not reason in `<think>` spans: its output is a run of framed messages
/// (`[<|message_model|>NAME]<|content_KIND|>BODY<|end_message|>`, see
/// `Inkling2OutputChannels`), and a thought is a `thinking` message that may
/// come before, between or after answer and call messages.
///
/// Each entry's token text is read by its own `Inkling2OutputChannels`, the
/// lexer the router uses to split the output, so an entry is classified by
/// the message its token lands in, not by matching bytes:
/// - a token read inside an open `text` or call message is returned;
/// - a token read inside a `thinking` message is withheld;
/// - a token that opens, closes or switches a message (the frame markers,
///   including a marker spelled out from ordinary tokens), a header name, text
///   between messages and anything after the output ends is withheld.
/// A marker written inside a body is that body's text, as the router reads
/// it, so it never ends a thought early.
struct InklingWithheldReasoningLogprobsFilter {
    private var channels = Inkling2OutputChannels()

    /// The entries the client may receive.
    mutating func visible(_ entries: [SSETokenLogprob]) -> [SSETokenLogprob] {
        entries.filter { entry in
            let before = channels.openChannel
            _ = channels.parse(entry.token)
            let after = channels.openChannel
            guard let channel = after, channel == before else { return false }
            return channel != .reasoning
        }
    }
}

/// The withheld-reasoning logprob filter for one request: Inkling 2's framed
/// messages, or the `<think>` span every other withholding family uses.
enum WithheldReasoningLogprobs {
    case think(WithheldReasoningLogprobsFilter)
    case inkling(InklingWithheldReasoningLogprobsFilter)

    /// nil unless the request asked for logprobs. An Inkling 2 request always
    /// gets its filter: its frame markers and thoughts are never answer
    /// tokens, even when the thought is returned as reasoning. Other families
    /// filter only when they withhold reasoning.
    static func forRequest(
        withholdsReasoning: Bool, logprobs: Bool, inklingChannels: Bool, startsInThought: Bool
    ) -> WithheldReasoningLogprobs? {
        guard logprobs else { return nil }
        if inklingChannels { return .inkling(InklingWithheldReasoningLogprobsFilter()) }
        guard withholdsReasoning else { return nil }
        return .think(WithheldReasoningLogprobsFilter(startsInThought: startsInThought))
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
