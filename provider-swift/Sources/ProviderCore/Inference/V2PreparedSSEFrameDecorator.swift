import Foundation

/// Applies the provider's existing post-formatter SSE decorations to a
/// prepared-v2 stream. `MLXOpenAIService` remains the sole frame formatter;
/// this state only mirrors the established reasoning-usage, prefix-cache, and
/// logprobs enrichments used by the v1 transport.
struct V2PreparedSSEFrameDecorator {
    struct Output {
        let frame: String
        let parsed: ProviderLoop.StreamChunkExtract?
    }

    private let prepared: PreparedInference
    private(set) var reasoningText = ""
    private var pendingLogprobs: [SSETokenLogprob] = []

    init(prepared: PreparedInference) {
        self.prepared = prepared
    }

    mutating func decorate(_ frame: String) -> Output {
        let parsed = ProviderLoop.parseStreamChunk(frame)
        if let reasoning = parsed?.reasoningDelta, !reasoning.isEmpty {
            reasoningText += reasoning
        }

        var emitted = frame
        if let usage = parsed?.usage {
            if let tokenizer = prepared.tokenizer, !reasoningText.isEmpty {
                let reasoningTokens = min(
                    max(0, usage.completionTokens),
                    tokenizer.inner.encode(
                        text: reasoningText,
                        addSpecialTokens: false
                    ).count
                )
                emitted = ProviderLoop.injectReasoningTokens(
                    into: emitted,
                    reasoningTokens: reasoningTokens
                )
            }
            if let cached = prepared.usageSignal?.prefixCacheHitTokens,
                cached > 0
            {
                emitted = ProviderLoop.injectCachedTokens(
                    into: emitted,
                    cachedTokens: cached
                )
            }
        }

        if let channel = prepared.logprobsChannel {
            pendingLogprobs += channel.drain()
            _ = EngineV2LogprobsChannel.capPending(&pendingLogprobs)
            if !pendingLogprobs.isEmpty,
                let injected = ProviderLoop.injectLogprobs(
                    into: emitted,
                    entries: pendingLogprobs
                )
            {
                emitted = injected
                pendingLogprobs.removeAll(keepingCapacity: true)
            }
        }
        return Output(frame: emitted, parsed: parsed)
    }
}
