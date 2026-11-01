// Copyright © 2026 Eigen Labs.
//
// Logprobs passthrough for the ContinuousBatchingV2 path.
//
// The v2 engine populates `CBv2Event.delta.logprobs` when the translated
// sampling params request them (`request.logprobs == true` →
// `CBv2SamplingParams.topLogprobs > 0`), and the v2 path emits the
// OpenAI-standard streaming shape:
//
//     choices[0].logprobs = { "content": [ { token, logprob, bytes,
//                                            top_logprobs: [...] } ] }
//
// The bridge pump converts each delta's entries
// (`EngineV2Translation.sseTokenLogprobs`) and yields them as a
// `GenerationEvent.logprobs` just before the delta's text, so captured
// metadata travels in generation order with the text it belongs to. The
// scheduler limits them to the requested alternatives, drops the entries of
// withheld reasoning (`WithheldReasoningLogprobsFilter`) and forwards them;
// the SDK's chat encoder attaches them to the next content chunk, on the
// coordinator relay and on the local APIs alike.
//
// Relay channel: a model whose entries also ride the reasoning chunks that
// carry their tokens, as vLLM-style servers attach them (GLM5-Next and
// Nemotron Super, `ProviderLoop.logprobsCoverReasoning`), keeps an
// `EngineV2LogprobsChannel` on the coordinator relay. The scheduler (GLM) or
// the Super owner appends the entries there before the text they precede,
// and the frames loop splices them into the next content or reasoning frame
// (`ProviderLoop.injectLogprobs`), so a response that ends while reasoning
// still returns them. A raw-body owner (Super) on the local API returns them
// the same way through `LocalChatUploadResponder`.
//
// KNOWN DEVIATIONS from OpenAI semantics: entries are emitted for EVERY
// sampled token, so when a reasoning parser or tool handler diverts a
// token's text away from `delta.content`, that token's entry still attaches
// to the next visible content chunk (OpenAI omits reasoning/tool tokens from
// `logprobs.content`). Conversely, trailing entries whose text never renders
// (stop-token holdback, end-of-stream) are dropped with the request.
//
// PRIVACY NOTE: entries carry token text — they are response content. They
// ride only inside the E2E-encrypted SSE stream back to the consumer,
// exactly like `delta.content`; nothing here flows into telemetry or logs.

import Foundation
import MLXLMServer
#if canImport(os)
import os
#endif

/// Captured metadata uses the canonical SDK schema and ordered event stream.
public typealias SSETokenLogprob = OpenAITokenLogprob

extension OpenAITokenLogprob {
    /// JSONSerialization-compatible dictionary in the exact OpenAI wire
    /// shape, retained for callers of the generic frame injector.
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

/// Present only when the raw request asks for logprobs. The scheduler applies
/// the requested alternative limit before forwarding metadata in stream order.
/// `relay` is the coordinator relay's channel for a model whose entries also
/// ride its reasoning frames (`ProviderLoop.logprobsCoverReasoning`): the
/// scheduler appends there instead of forwarding, before the text each entry
/// precedes, and the frames loop splices them.
public struct EngineV2LogprobsPlumbing: Sendable {
    public let topLogprobs: Int?
    public let relay: EngineV2LogprobsChannel?

    public init(topLogprobs: Int?, relay: EngineV2LogprobsChannel? = nil) {
        self.topLogprobs = topLogprobs
        self.relay = relay
    }

    func requested(_ entries: [SSETokenLogprob]) -> [SSETokenLogprob] {
        let limit = max(0, topLogprobs ?? 0)
        return entries.map {
            .init(token: $0.token, logprob: $0.logprob, bytes: $0.bytes,
                  topLogprobs: Array($0.topLogprobs.prefix(limit)))
        }
    }
}

/// Thread-safe per-request FIFO carrying relay logprob entries from their
/// producer (the scheduler's event pump for GLM5-Next, the Nemotron Super
/// owner) to the SSE frame splicer (the coordinator frames loop, or
/// `LocalChatUploadResponder` for a raw-body owner).
///
/// One instance per inference request, created only when the request asked
/// for logprobs AND its model's entries cover reasoning. Appended by the
/// producer, drained by the frames loop — a plain lock keeps it
/// allocation-cheap on the hot path.
///
/// WHY A LOCK, NOT AN ACTOR (hardening review): the critical section is a
/// bounded array append/swap — no I/O, no allocation beyond the append —
/// contended by exactly TWO parties (one producer, one frames loop), and only
/// on requests that opted into logprobs. An uncontended `NSLock`
/// lock/unlock is tens of nanoseconds; converting to an actor would force
/// the producer to `await` per delta (executor hop + suspension bookkeeping),
/// which costs more than the lock it replaces and adds reordering risk
/// before the chunk yield that the current synchronous append precludes.
///
/// BOUNDED (hardening): the producer appends BEFORE yielding each text chunk
/// and the frames loop drains per SSE frame, so in the steady state the buffer
/// holds ~1 frame's worth of entries. But if the frames loop stalls or never
/// drains (a slow/stuck consumer, a torn-down SSE stream), an unbounded
/// buffer would grow with every decoded token for the life of the request.
/// The buffer is therefore capped at `maxEntries` with drop-OLDEST eviction:
/// under overflow the freshest entries — the ones a resuming consumer would
/// splice into upcoming frames — are kept, and a dropped count is recorded
/// (logged once). Dropping logprobs never affects `delta.content`, billing,
/// or the response hash (they ride out-of-band), so a cap is safe.
public final class EngineV2LogprobsChannel: @unchecked Sendable {
    /// Max buffered entries before drop-oldest kicks in. ~4096 tokens of
    /// undrained logprobs is already far past any real frame cadence.
    public static let maxEntries = 4096

    private let lock = NSLock()
    private var entries: [SSETokenLogprob] = []
    private var _droppedCount = 0
    private var loggedDrop = false

    #if canImport(os)
    private static let logger = Logger(
        subsystem: BuildEnvironment.current.logSubsystem, category: "engine_v2_logprobs")
    #endif

    public init() {}

    /// Append entries in emission order (producer side). Enforces the
    /// `maxEntries` cap by dropping the OLDEST entries; the first time any are
    /// dropped it logs a one-line warning (count only — never token text).
    public func append(_ new: [SSETokenLogprob]) {
        guard !new.isEmpty else { return }
        let shouldLog: Int? = lock.withLock {
            entries.append(contentsOf: new)
            guard entries.count > Self.maxEntries else { return nil }
            let overflow = entries.count - Self.maxEntries
            entries.removeFirst(overflow)
            _droppedCount += overflow
            if !loggedDrop {
                loggedDrop = true
                return _droppedCount
            }
            return nil
        }
        #if canImport(os)
        if let total = shouldLog {
            Self.logger.warning(
                "engine_v2 logprobs buffer hit \(Self.maxEntries) cap; dropping oldest (\(total) so far) — consumer not draining")
        }
        #else
        _ = shouldLog
        #endif
    }

    /// Remove and return everything appended so far (frames-loop side).
    public func drain() -> [SSETokenLogprob] {
        lock.withLock {
            let out = entries
            entries = []
            return out
        }
    }

    /// Total entries evicted by the cap (drop-oldest). 0 in the steady state.
    public var droppedCount: Int {
        lock.withLock { _droppedCount }
    }

    /// Enforce the channel's `maxEntries` cap on a CALLER-held pending buffer
    /// (round-3 PR#499 P2). The frames loop drains this channel into a local
    /// `pendingLogprobs` array and only clears it when a text-bearing frame
    /// arrives — so a stream that emits many tool-only chunks before any
    /// visible text would re-accumulate everything the channel cap just
    /// bounded. Same policy as `append`: drop-OLDEST, keep the freshest window
    /// (the entries closest to the text that will eventually render), report
    /// how many were dropped so the caller can log it (count only — never
    /// token text). Pure and synchronous so it is unit-testable.
    public static func capPending(
        _ pending: inout [SSETokenLogprob],
        maxEntries: Int = EngineV2LogprobsChannel.maxEntries
    ) -> Int {
        guard pending.count > maxEntries else { return 0 }
        let overflow = pending.count - maxEntries
        pending.removeFirst(overflow)
        return overflow
    }
}
