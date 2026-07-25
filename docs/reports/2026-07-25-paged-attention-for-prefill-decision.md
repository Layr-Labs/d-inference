# Should we move to Paged Attention instead of optimizing AttentionV1?

**Decision: No — not for the prefill problem.** Paged attention is a
decode-side KV-memory optimization. Its prefill path is the *same* composed
fallback we already run, plus an extra materialized mask, and adopting it would
disable two features we shipped in v0.7.15.

Companion to `2026-07-25-prefill-and-fleet-performance-findings.md`, which has
the full roofline and fleet analysis.

---

## The question

We are planning ~60 lines of query sub-blocking in `AttentionV1.swift` (the
contiguous backend's attention dispatch) to cut wasted sliding-window attention
work and cap the score tensor. A paged backend already exists in the tree.
Why not just switch to it instead of investing in "V1"?

A naming clarification first: **`AttentionV1` is not a legacy version we are
propping up.** It is the production attention dispatch for the contiguous KV
backend. Paged is the experimental alternative (`AGENTS.md`: paged is explicit/
experimental, `.auto` resolves to contiguous, VLM and kv-quant slots are vetoed
from it). "V1" refers to the first *backend implementation*, not an old API.

---

## Evidence 1 — the paged Metal kernel is decode-only

`Paged/pagedattention.metal:3`:

```
// CBv2 paged-attention decode kernels (ContinuousBatchingV2, WS-C).
```

It is a two-pass split-K **decode** kernel: pass A computes partials per
(sequence, query-head), pass B merges them. It is built around one query per
sequence, and it is genuinely good at that — KV bytes are read once per head
group rather than once per query head.

**There is no paged prefill kernel.**

## Evidence 2 — paged prefill runs the identical composed fallback

`Paged/PagedLayerCache.swift:341-343`:

```swift
return MLXFast.scaledDotProductAttention(
    queries: queries, keys: k, values: v, scale: scale,
    mask: .array(mask), sinks: sinks?.asType(queries.dtype))
```

That is the **same `MLXFast` entry point the contiguous path calls**. The
composed fallback is selected by *head dimension*, not by cache backend
(`libs/mlx/mlx/backend/metal/scaled_dot_product_attention.cpp:625-626`):

```cpp
sdpa_full_supported_head_dim = query_head_dim == value_head_dim &&
    (query_head_dim == 64 || query_head_dim == 80 || query_head_dim == 128);
```

Gemma 4 uses head_dim **256** (sliding) and **512** (full). Neither backend can
reach the fused kernel. Switching storage layout changes nothing about this.

## Evidence 3 — paged prefill is strictly *worse* here

`Paged/PagedLayerCache.swift:322-329` materializes an explicit `[qL, kL]`
boolean mask on every prefill chunk:

```swift
let qpos = MLXArray(Int32(qStart) ..< Int32(end)).expandedDimensions(axis: 1)
let kpos = MLXArray(Int32(kStart) ..< Int32(end)).expandedDimensions(axis: 0)
var mask = kpos .<= qpos
if case .slidingWindow(let window) = kind.attention {
    mask = mask & (kpos .> (qpos - Int32(window)))
}
```

The contiguous path uses the *symbolic* `.causal` mask mode wherever it can
(`AttentionV1.maskMode`) and only materializes an array mask when the window
actually binds. So paged adds a full-size tensor allocation the current path
avoids — on top of the same score tensor.

---

## Paged solves a problem we do not have

Paged attention's real value is KV memory management: pages instead of
contiguous per-sequence buffers, eliminating fragmentation and enabling high
concurrency.

Our KV is small. At 124k context the **entire KV cache is 2.76 GB**, because:

- `attention_k_eq_v` means the 5 full layers skip `v_proj` entirely,
- those layers carry only 2 KV heads (`num_global_key_value_heads`), and
- the 1024-token sliding window caps the other 25 layers at **0.21 GB total,
  regardless of context length**.

For comparison, the *transient attention score tensor* at that context is
**2.04 GB at C=512** and would be 8.18 GB at C=2048. The thing that actually
pressures memory is an activation, not the cache — and paged does not touch
activations.

---

## What paged would cost us

| Capability | Gate | Effect |
|---|---|---|
| Rectangular packed prefill | `LayerCacheBankV2.swift:121-123` — `supportsPackedPrefill` requires every cache to be `CBv2LayerCache` | **Disabled.** This is the feature we shipped and measured in v0.7.15. |
| Vision / multimodal | `LayerCacheBankV2.swift:112-114` — `supportsMultimodalSpans` requires `CBv2SpanMaskBinding`; `PagedLayerCache` does **not** conform | **Cannot serve vision requests at all.** |
| Prefix cache | paged slabs are recyclable, so `requiresMaterializedSnapshots` applies | Extra constraint on donation/adoption. |

So the trade is: lose packed prefill and multimodal, gain nothing on the prefill
path, and keep an attention kernel that only helps decode.

---

## Attention is not where prefill time goes anyway

From the calibrated cost model (P=512):

| Component | Share of prefill time |
|---|---:|
| MoE experts | 41.8% |
| Attention projections | 21.5% |
| Fixed per-request overhead | 14.3% |
| Dense MLP | 10.4% |
| Elementwise / gather | 6.1% |
| **Attention matmuls** | **4.1%** |
| Score-tensor traffic | 1.1% |

Attention *matmuls* are 4.1% at P=512 and 9.9% at P=2048. Even a perfect
attention kernel is a modest prefill win. The two big terms — MoE tile padding
and the projections — are untouched by any attention work, paged or otherwise.

Sub-blocking is worth doing not because attention dominates, but because it is
cheap (~60 lines in the path we already run) and because it makes the score
tensor **O(1) in chunk size**, which is the precondition for chunk growth
(1.16x combined). See the findings doc, section 9.

---

## Where paged *would* earn its place

This is not "paged is bad". It is well-built and its decode kernel is the right
design. The case for adopting it would be:

- **Much higher concurrency.** If we wanted `maxConcurrentRequests` well above
  4, contiguous per-sequence KV would fragment and strand memory. Paged fixes
  exactly that.
- **Very long contexts at scale**, where KV genuinely becomes the dominant
  resident cost — not our situation while the sliding window holds 25/30 layers
  flat.

Today neither applies. Decode is **bandwidth-bound** at ~259 GB/s (47% of the
546 GB/s pin rate), and the B=4 ceiling is 2.11x — set by 66% batch-invariant
bytes and 91%-distinct expert draws, not by KV capacity or fragmentation. Adding
concurrency would not convert into throughput, so the problem paged solves is
not currently binding.

**Revisit if:** we raise concurrency substantially, KV becomes the resident
bottleneck, or someone writes a *paged prefill* kernel that is window-aware and
avoids score materialization. The third would be a real advance — but that is
flash attention with paged storage, which is a much larger project than
sub-blocking and would still need head_dim 256/512 support that MLX lacks.

---

## Verdict

| | Sub-blocking in AttentionV1 | Migrate to paged |
|---|---|---|
| Fixes wasted sliding-window FLOPs (1.499x -> 1.062x) | Yes | No |
| Caps score tensor (2.04 GB -> 0.51 GB) | Yes | No |
| Unlocks chunk growth (1.16x combined) | Yes | No |
| Helps decode | No | Yes (but decode is bandwidth-bound) |
| Keeps packed prefill | Yes | **No** |
| Keeps vision support | Yes | **No** |
| Effort | ~60 lines Swift + parity tests | backend migration |

Proceed with sub-blocking. Keep paged as the experimental backend it is.
