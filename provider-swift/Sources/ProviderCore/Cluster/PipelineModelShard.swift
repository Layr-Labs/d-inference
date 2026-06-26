/// PipelineModelShard -- the per-rank slice of a model, as the distributed
/// engine sees it. This is the seam between Darkbloom's pipeline orchestration
/// (fully implemented + verified in ProviderCore) and the MLX model internals
/// (which live in the `mlx-swift-lm` submodule).
///
/// A rank owns a contiguous layer interval `[start, end)`:
///   - the HEAD rank (start == 0) also embeds tokens,
///   - the TAIL rank (end == totalLayers) also applies the final norm + lm_head
///     and exposes the vocabulary logits for sampling.
///
/// Why a protocol: `LlamaModelInner.layers` is `internal` to MLXLLM and its
/// `callAsFunction` runs the FULL layer stack, so a *partial* forward (only this
/// rank's layers) cannot be expressed from ProviderCore today. Implementing
/// `PipelineModelShard` for a concrete architecture requires a small addition in
/// the mlx-swift-lm fork (expose a sliced-layer forward). Until then, the engine,
/// decode loop, transport, handshake, and crypto are all complete and tested
/// against this seam with a stand-in shard. See
/// docs/developer/clustering-implementation-status.md.

import Foundation
import MLX

public protocol PipelineModelShard: Sendable {
    /// Total transformer layers in the full model (same on every rank).
    var totalLayers: Int { get }
    /// The contiguous layer interval this rank owns.
    var ownedInterval: LayerInterval { get }

    /// HEAD only: embed a token id sequence into the initial hidden state.
    /// Non-head ranks receive the hidden state over the wire instead.
    func embed(tokens: [Int]) -> MLXArray

    /// Run this rank's owned layers on an inbound hidden state, returning the
    /// transformed hidden state.
    func runOwnedLayers(_ hidden: MLXArray) -> MLXArray

    /// TAIL only: project the post-layer hidden state to vocabulary logits
    /// (final norm + lm_head). Non-tail ranks never call this.
    func projectToLogits(_ hidden: MLXArray) -> MLXArray

    // MARK: - Batched (continuous-batching) path

    /// HEAD only: embed a BATCH of token rows into `[B, maxLen, hidden]`. Each
    /// row is left-padded to `maxLen` per `leftPadding[b]` so ragged-length
    /// prompts share one forward; the matching `BatchKVCache` masks the padding.
    /// (Phase 1 uses equal-length rows ⇒ all leftPadding == 0.)
    func embedBatch(rows: [[Int]], leftPadding: [Int]) -> MLXArray

    /// Run this rank's owned layers on a batched `[B, width, hidden]` hidden
    /// state, using the batched KV caches established by `beginBatch`.
    func runOwnedLayersBatched(_ hidden: MLXArray) -> MLXArray

    /// TAIL only: project a batched `[B, width, hidden]` state to `[B, *, vocab]`
    /// logits (last position only).
    func projectToLogitsBatched(_ hidden: MLXArray) -> MLXArray

    /// (Re)allocate this rank's per-owned-layer BATCHED KV caches for a batch of
    /// `leftPadding.count` rows. Must be called before a batched generation; the
    /// batched run/project calls use these caches. Resets any prior batch state.
    func beginBatch(leftPadding: [Int])

    // MARK: - Continuous-batching cache lifecycle (Phase 3)

    /// Evict rows: keep only `keepIndices` (into the current batch order) in every
    /// owned-layer batched cache. All ranks call this with the same indices so
    /// caches stay row-aligned.
    func filterBatch(keepIndices: [Int])

    /// Run a PREFILL of newly-admitted rows on a SEPARATE temporary batched cache
    /// and merge it into the live batched caches (append rows). `hidden` is the
    /// admitted rows' post-embed (head) or received (peer) `[nAdmit, width, hidden]`
    /// state; returns the post-owned-layers state so the tail can sample the
    /// admitted rows' first tokens. `leftPadding` sizes the admitted cache.
    func admitPrefill(_ hidden: MLXArray, leftPadding: [Int]) -> MLXArray
}

public extension PipelineModelShard {
    var isHead: Bool { ownedInterval.start == 0 }
    var isTail: Bool { ownedInterval.end == totalLayers }
}
