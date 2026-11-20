import MLXLMServer

/// The logprob entries a Super response carries, chosen where its output is
/// produced, so the speed of the frames that splice them cannot change them.
/// The bindings append every generated token's entry to `produced`, before the
/// chunk it precedes. The entries gathered so far reach the caller's channel
/// only when a chunk shows reasoning or content, and before that chunk's
/// events leave, so a frame that shows text always finds them
/// (`ProviderLoop.injectLogprobs`, `LocalChatUploadResponder.splicingLogprobs`).
/// A token that shows nothing, such as `</think>`, tool-call markup or the stop
/// token, rides the next chunk that shows text, and is dropped when none follows.
///
/// A stream's own events decide. A complete response holds its text until it
/// ends, so it follows a streaming split of the same request instead, and
/// carries exactly the entries its stream would.
///
/// Why the stream needs this too: when the caller's channel took every entry
/// at once, a frames loop that read it after the bindings had already appended
/// the next token's entry spliced that entry too, and a token that never shows
/// (the first tool-call tag after the answer) rode the answer's last frame or
/// not, by timing.
struct NemotronSuperCarriedLogprobs {
    /// Receives the request's entries from the bindings.
    let produced = EngineV2LogprobsChannel()
    private let carried: EngineV2LogprobsChannel
    private let streaming: Bool
    /// A complete response's streaming split. Nil on a stream, and once the
    /// split refuses the output; the complete response then fails the same
    /// validation.
    private var split: NemotronSuperLocalOutput?
    private var pending: [SSETokenLogprob] = []

    /// `carried` is the caller's channel, which the frames (a stream) or the
    /// complete response read.
    init(plan: NemotronSuperRequestPlan, streaming: Bool, carried: EngineV2LogprobsChannel) throws {
        self.carried = carried
        self.streaming = streaming
        split = streaming ? nil : try NemotronSuperLocalOutput(plan: plan, streaming: true)
    }

    /// Before `events`, the response's own output for `chunk`, are yielded.
    mutating func accept(_ chunk: String, events: [MLXServerGenerationEvent]) {
        gather()
        carry(after: streaming ? events : try? split?.append(chunk))
    }

    /// Before the response's end `events` are yielded. They can show text
    /// (held or promoted content), as the response's own finish does
    /// (`cutAtLimit`: a cut answer).
    mutating func finish(cutAtLimit: Bool = false, events: [MLXServerGenerationEvent]) {
        gather()
        carry(after: streaming ? events : try? split?.finish(cutAtLimit: cutAtLimit).events)
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
