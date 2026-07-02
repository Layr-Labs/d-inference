// Copyright © 2026 Eigen Labs.
//
// Logprobs passthrough for the ContinuousBatchingV2 path.
//
// The v2 engine populates `CBv2Event.delta.logprobs` when the translated
// sampling params request them (`request.logprobs == true` →
// `CBv2SamplingParams.topLogprobs > 0`). The legacy engine NEVER emitted
// logprobs — no SSE shape exists to match — so the v2 path emits the
// OpenAI-standard streaming shape instead:
//
//     choices[0].logprobs = { "content": [ { token, logprob, bytes,
//                                            top_logprobs: [...] } ] }
//
// The upstream SSE encoder (`MLXOpenAIService.streamChatCompletionFrames` /
// `OpenAIChatCompletionChunk`) has no logprobs field, and the provider's
// `GenerationEvent` deliberately stays `.chunk/.info/.error` (extending it
// would break the "flag off ⇒ byte-identical" legacy invariant). So the
// entries travel OUT-OF-BAND: the bridge pump converts each delta's
// logprobs (`EngineV2Translation.sseTokenLogprobs`) and appends them to a
// per-request `EngineV2LogprobsChannel`; the coordinator inference handler
// drains the channel per SSE frame and splices the entries into the first
// content-bearing chunk (`ProviderLoop.injectLogprobs(into:entries:)`)
// before encryption. Ordering is safe because the pump appends BEFORE
// yielding the text chunk that produced the entries.
//
// Scope: the coordinator serving path only. The standalone `--local` HTTP
// path serves frames inside the upstream Hummingbird router (no provider
// seam after SSE encoding), so it does not emit logprobs — same visible
// behavior as the legacy engine there.
//
// KNOWN DEVIATIONS from OpenAI semantics (acceptable for the flag-gated
// rollout): entries are emitted for EVERY sampled token, so when a
// reasoning parser or tool handler diverts a token's text away from
// `delta.content`, that token's entry still attaches to the next visible
// content chunk (OpenAI omits reasoning/tool tokens from
// `logprobs.content`). Conversely, trailing entries whose text never
// renders as content (stop-token holdback, end-of-stream) are dropped
// with the request.
//
// PRIVACY NOTE: entries carry token text — they are response content. They
// ride only inside the E2E-encrypted SSE stream back to the consumer,
// exactly like `delta.content`; nothing here flows into telemetry or logs.

import Foundation

/// One OpenAI streaming logprobs entry (`choices[].logprobs.content[]`).
public struct SSETokenLogprob: Codable, Sendable, Equatable {
    /// One `top_logprobs` alternative (same wire shape minus the nesting).
    public struct Top: Codable, Sendable, Equatable {
        public let token: String
        public let logprob: Float
        /// Raw UTF-8 bytes of `token` — the OpenAI escape hatch for BPE
        /// intermediate tokens whose text is not valid standalone UTF-8.
        public let bytes: [Int]?

        public init(token: String, logprob: Float, bytes: [Int]?) {
            self.token = token
            self.logprob = logprob
            self.bytes = bytes
        }
    }

    public let token: String
    public let logprob: Float
    public let bytes: [Int]?
    public let topLogprobs: [Top]

    enum CodingKeys: String, CodingKey {
        case token
        case logprob
        case bytes
        case topLogprobs = "top_logprobs"
    }

    public init(token: String, logprob: Float, bytes: [Int]?, topLogprobs: [Top]) {
        self.token = token
        self.logprob = logprob
        self.bytes = bytes
        self.topLogprobs = topLogprobs
    }

    /// JSONSerialization-compatible dictionary in the exact OpenAI wire
    /// shape. Used by the SSE frame injector, which edits frame JSON
    /// generically (the upstream chunk type has no logprobs field to
    /// re-encode through).
    var jsonObject: [String: Any] {
        [
            "token": token,
            "logprob": Double(logprob),
            "bytes": bytes ?? [],
            "top_logprobs": topLogprobs.map { top in
                [
                    "token": top.token,
                    "logprob": Double(top.logprob),
                    "bytes": top.bytes ?? [],
                ] as [String: Any]
            },
        ]
    }
}

/// Per-request logprobs plumbing handed to `MultiModelBatchSchedulerEngine`
/// by the coordinator inference handler. `topLogprobs` mirrors the sealed
/// request's OpenAI `top_logprobs` knob (the upstream
/// `OpenAIChatCompletionRequest` does not model `logprobs`/`top_logprobs`,
/// so — like `reasoning_effort` and the cache scope — the handler decodes
/// them from the raw body and threads them in here); `channel` receives the
/// engine-emitted entries. Present ⇒ the request asked for logprobs.
public struct EngineV2LogprobsPlumbing: Sendable {
    public let topLogprobs: Int?
    public let channel: EngineV2LogprobsChannel

    public init(topLogprobs: Int?, channel: EngineV2LogprobsChannel) {
        self.topLogprobs = topLogprobs
        self.channel = channel
    }
}

/// Thread-safe per-request FIFO carrying logprob entries from the v2
/// bridge's event pump to the coordinator path's SSE frame decorator.
///
/// One instance per inference request (created by the inference handler
/// only when the sealed request asked for logprobs AND the slot serves via
/// the v2 engine). Appended by the bridge pump task, drained by the frames
/// loop — a plain lock keeps it allocation-cheap on the hot path.
public final class EngineV2LogprobsChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [SSETokenLogprob] = []

    public init() {}

    /// Append entries in emission order (pump side).
    public func append(_ new: [SSETokenLogprob]) {
        guard !new.isEmpty else { return }
        lock.withLock { entries.append(contentsOf: new) }
    }

    /// Remove and return everything appended so far (frames-loop side).
    public func drain() -> [SSETokenLogprob] {
        lock.withLock {
            let out = entries
            entries = []
            return out
        }
    }
}
