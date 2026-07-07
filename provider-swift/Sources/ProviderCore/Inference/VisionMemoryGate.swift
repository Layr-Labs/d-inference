// Copyright © 2026 Eigen Labs.
//
// Vision-request memory gate — scheduler-free home (v0.7.5).
//
// Re-homed unchanged from `BatchScheduler+ModelLifecycle`'s
// `reserveVisionRequest` / `releaseVisionRequest`: reserves a media
// request's transient decode RAM (CIImage rasters + pixel `Data` buffers —
// invisible to the cap's live MLX counters) plus its generation KV cache
// (fp16 rate × the full token span) against the SAME process-wide
// `GlobalKVCacheBudget` every other path gates through, keyed by request
// id. The legacy VLM media path (`container.generate`) bypasses the batched
// submit reservation entirely, so without this gate N concurrent media
// requests could over-commit unified memory the cap would only catch on the
// NEXT admission.
//
// One gate per model slot (it carries the slot's fp16 rate + context
// window); `nil` budget ⇒ gating disabled ("always proceed" — unit tests /
// standalone paths without a shared ledger).

import Foundation

public struct VisionMemoryGate: Sendable {
    /// Process-wide KV reservation ledger; nil ⇒ no gating/accounting.
    let kvBudget: GlobalKVCacheBudget?
    /// fp16 per-token KV cost of the slot's model. This path's
    /// `container.generate` allocates an UN-quantized KV cache, so the
    /// reservation is priced at the fp16 rate.
    let fp16KVBytesPerToken: Int
    /// The model's configured context window (`max_position_embeddings`),
    /// or 0 if unknown. The KV cache can never hold more than this many
    /// prompt+vision tokens, so callers clamp their prompt+vision estimate
    /// to it (output tokens are added on top).
    public let contextLength: Int

    public init(kvBudget: GlobalKVCacheBudget?, fp16KVBytesPerToken: Int, contextLength: Int) {
        self.kvBudget = kvBudget
        self.fp16KVBytesPerToken = fp16KVBytesPerToken
        self.contextLength = contextLength
    }

    /// Reserve unified memory for a VLM (vision-path) request against the
    /// shared 90% cap. Both the media-decode RAM and the generation KV are
    /// charged to ONE reservation id and released together when the stream
    /// ends. Returns true if it fits (and was reserved) or budgeting is
    /// disabled; false if it would exceed the cap, in which case the caller
    /// surfaces a retryable 503. Pair with `release`. Saturating math;
    /// never traps.
    public func reserve(
        requestId: String, mediaDecodeBytes: UInt64, kvTokens: Int
    ) async -> Bool {
        guard let kvBudget else { return true }
        // KV bytes = fp16 per-token cost × the FULL token span the cache
        // will hold: prompt text + image/video soft tokens + generated
        // output (the caller computes that conservative total). Reserving
        // only the output tokens would badly under-count — a single image
        // expands to hundreds of vision tokens, all of which occupy KV.
        var genKVBytes: UInt64 = 0
        if fp16KVBytesPerToken > 0, kvTokens > 0 {
            let (b, overflow) = UInt64(fp16KVBytesPerToken)
                .multipliedReportingOverflow(by: UInt64(kvTokens))
            genKVBytes = overflow ? .max : b
        }
        let (total, overflow) = mediaDecodeBytes.addingReportingOverflow(genKVBytes)
        let bytes = overflow ? UInt64.max : total
        return await kvBudget.reserveBytes(requestID: requestId, bytes: bytes)
    }

    /// Release a prior `reserve` reservation. Safe/no-op if unknown or
    /// budgeting is disabled.
    public func release(requestId: String) async {
        await kvBudget?.release(requestID: requestId)
    }
}
