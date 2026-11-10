// Copyright © 2026 Eigen Labs.
// Turn continuation: after a reply, prefill the next turn's known prefix while
// the Mac is idle.

import Foundation
import MLXLMCommon
import MLXLMServer

/// The canonical positions a slot's prefix tiers keep, read once at load.
///
/// A follow-up prompt reuses state only at one of these positions, so the
/// continuation is cut at the last one inside the tokens the next turn is known
/// to start with. The cut is never a correctness input: the engine reuses state
/// only where a later prompt's tokens match.
public struct TurnContinuationCells: Sendable, Equatable {
    /// `CBv2SchedulerConfig.canonicalPrefillGridTokens`.
    let gridTokens: Int
    /// The slot's message-boundary rule; nil when the grid applies alone.
    let boundaryRule: CBv2CanonicalBoundaryRule?
    /// The resident recurrent bank keeps a state at the end of a prompt that
    /// ends on a canonical position. Without it only the durable tier is fed:
    /// that tier keeps grid multiples below the prompt's last token.
    let residentBank: Bool

    static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        var index = 0
        let limit = min(a.count, b.count)
        while index < limit, a[index] == b[index] { index += 1 }
        return index
    }

    /// The prompt of the continuation request, or nil when the turn that just
    /// ended already left state at the last canonical position of `shared`.
    ///
    /// - Parameters:
    ///   - source: the prompt of the turn that just ended.
    ///   - shared: the tokens the next turn's prompt is known to start with.
    func continuationTokens(source: [Int], shared: [Int]) -> [Int]? {
        let known = shared.count
        let common = Self.commonPrefixLength(source, shared)
        // The next prompt extends this one. A prediction that leaves it more
        // than a cell before its end is not a follow-up of this turn.
        guard gridTokens > 0, source.count - common <= gridTokens else { return nil }
        if residentBank {
            let boundaries = boundaryRule?.boundaries(in: shared) ?? []
            let cut = max(boundaries.last ?? 0, known / gridTokens * gridTokens)
            let have = max(boundaries.last { $0 <= common } ?? 0, common / gridTokens * gridTokens)
            guard cut > have, cut > 1 else { return nil }
            return Array(shared.prefix(cut))
        }
        guard known > 0 else { return nil }
        let cut = (known - 1) / gridTokens * gridTokens
        let have = min(max(0, source.count - 1) / gridTokens * gridTokens, common / gridTokens * gridTokens)
        guard cut > have else { return nil }
        return Array(shared.prefix(cut + 1))
    }
}

/// What one served request hands to its stream so the next turn can be
/// predicted when the reply ends. Built only for a request the continuation
/// may follow; it is dropped with the stream.
struct TurnContinuationSource: Sendable {
    /// The prompt this request ran.
    let promptTokens: [Int]
    let stream: Bool
    /// The format the service splits this request's reasoning with.
    let reasoningParser: ReasoningParserFormat
    /// The prompt of this request's conversation extended by the assistant
    /// `reply` and a user message `probe`, rendered the way a request is.
    let render: @Sendable (_ reply: String, _ probe: String) throws -> [Int]
    let submit: @Sendable (_ source: [Int], _ shared: [Int]) async -> Void
    /// How the prediction leaves the request path. A test replaces it to keep
    /// the task it started.
    var launch: @Sendable (_ work: @escaping @Sendable () async -> Void) -> Void = { work in
        Task.detached(priority: .utility) { await work() }
    }

    /// The tokens every follow-up of this conversation starts with, whatever
    /// the user writes next: what two renders with different user text share,
    /// less the last token, which can merge with the first of the user's text.
    func sharedPrefix(reply: String) throws -> [Int] {
        let first = try render(reply, "A")
        let second = try render(reply, "B")
        let common = TurnContinuationCells.commonPrefixLength(first, second)
        return Array(first.prefix(max(0, common - 1)))
    }

    /// Off the request path: the stream that calls this has already sent its
    /// terminal frame and released its model pin.
    func start(reply: String) {
        launch {
            guard let shared = try? sharedPrefix(reply: reply), !shared.isEmpty else { return }
            await submit(promptTokens, shared)
        }
    }
}

/// Rebuilds the assistant `content` a client receives, and would send back,
/// from the events of one stream. It reads the same events the service frames
/// and splits reasoning the same way. A reply it gets wrong costs the reuse of
/// that turn and nothing else.
struct TurnReplyCapture: Sendable {
    private var streaming: StreamingReasoningParser?
    private let format: ReasoningParserFormat
    private var content = ""
    private var nativeChannels = false
    private var sawToolCall = false

    init(stream: Bool, reasoningParser: ReasoningParserFormat) {
        format = reasoningParser
        streaming = stream ? StreamingReasoningParser(format: reasoningParser) : nil
    }

    mutating func observe(_ event: MLXServerGenerationEvent) {
        switch event {
        case .content(let text):
            if streaming != nil {
                for parsed in streaming?.parse(text) ?? [] { content += parsed.content }
            } else {
                content += text
            }
        case .parsed(let parsed):
            nativeChannels = true
            content += parsed.content
        case .toolCall, .toolCallDelta:
            sawToolCall = true
        case .logprobs, .info:
            break
        }
    }

    /// The reply, or nil when there is none to continue from: a tool call
    /// (its next message is the tool's result, not the user's) or no content.
    mutating func finish() -> String? {
        guard !sawToolCall else { return nil }
        if streaming != nil {
            for parsed in streaming?.finish() ?? [] { content += parsed.content }
        } else if !nativeChannels {
            content = ReasoningParser(format: format).parse(content).content
        }
        return content.isEmpty ? nil : content
    }
}
