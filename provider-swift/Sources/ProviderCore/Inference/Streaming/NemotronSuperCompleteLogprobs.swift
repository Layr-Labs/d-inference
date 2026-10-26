import MLXLMServer

/// The logprob entries a complete Super response carries: exactly those its
/// stream carries. The bindings append every generated token's entry to
/// `produced`; each chunk also passes a streaming split of the same request,
/// and the entries gathered so far reach the caller's channel only when that
/// chunk shows reasoning or content, as the stream's frames carry them
/// (`LocalChatUploadResponder.splicingLogprobs`). A token that shows nothing,
/// such as `</think>`, tool-call markup or the stop token, rides the next chunk
/// that shows text, and is dropped when none follows.
struct NemotronSuperCompleteLogprobs {
    /// Receives the request's entries from the bindings.
    let produced = EngineV2LogprobsChannel()
    private let carried: EngineV2LogprobsChannel
    /// Nil once the split refuses the output; the complete response then fails
    /// the same validation.
    private var split: NemotronSuperLocalOutput?
    private var pending: [SSETokenLogprob] = []

    /// `carried` is the caller's channel, which the complete response reads.
    init(plan: NemotronSuperRequestPlan, carried: EngineV2LogprobsChannel) throws {
        self.carried = carried
        split = try NemotronSuperLocalOutput(plan: plan, streaming: true)
    }

    mutating func accept(_ chunk: String) {
        gather()
        carry(after: try? split?.append(chunk))
    }

    /// The stream's end events can show text (held or promoted content).
    mutating func finish() {
        gather()
        carry(after: try? split?.finish().events)
        split = nil
    }

    private mutating func gather() {
        pending += produced.drain()
        _ = EngineV2LogprobsChannel.capPending(&pending)
    }

    private mutating func carry(after events: [MLXServerGenerationEvent]?) {
        guard let events else { split = nil; return }
        guard events.contains(where: Self.showsText) else { return }
        carried.append(pending)
        pending = []
    }

    private static func showsText(_ event: MLXServerGenerationEvent) -> Bool {
        guard case .parsed(let parsed) = event else { return false }
        return !parsed.content.isEmpty || parsed.reasoningContent?.isEmpty == false
    }
}
