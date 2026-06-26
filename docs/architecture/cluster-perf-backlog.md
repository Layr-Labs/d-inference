# Cluster Inference — Performance Backlog (what to explore)

Running list of performance levers for the Apple-Silicon cluster, with status and
the measured/known rationale for each. Ordered roughly by expected payoff for a
multi-user private-inference service. See `cluster-benchmark.md` for the numbers
this builds on.

| Lever | Status | Expected win | Notes |
|-------|--------|--------------|-------|
| Continuous batching | ✅ **done, validated** | ~2.5× aggregate throughput (cross-Mac) | The throughput lever for multi-user serving. |
| JACCL / RDMA-over-Thunderbolt | ❌ **blocked on this HW pair** | kills the ~83 ms/token TP comms floor | RDMA enabled on both, but the base **M4 is TB4** and exposes 0 RDMA devices — Apple TB-RDMA needs **TB5 on both ends**. M4 Pro shows 3 devices. Needs two TB5 machines. See `jaccl-rdma-readiness.md`. |
| Tensor / expert parallelism | 📐 designed, not built | only worth it *after* JACCL or *with* batching | `cluster-tensor-expert-parallel.md`. Comms-bound (~12 tok/s) on the current CPU-stream ring. |
| Speculative decoding | ✅ built, measured | 2–3× single-stream — **but only with target ≫ draft** | `spec-bench`. llama-1b/llama-8b (5× ratio) is too close → *slower*. Pays off for 1B drafting **70B** (~70× ratio). |
| 70B-Q4 capacity demo | ⬜ not started | the "impossible on one Mac" showcase | ~37 GB across 56 GB combined; fits neither node alone. Also the regime where speculative decoding finally wins. |
| Bandwidth-weighted layer split | ⬜ **to explore** | reduce the pipeline critical path on heterogeneous chips | Today's split is *memory*-weighted, loading more layers onto the 32 GB base M4 — which is the **bandwidth-poorer** chip (~120 GB/s vs the M4 Pro's ~273). Decode is bandwidth-bound, so the slow chip dominates the critical path (trace: head 28 ms vs tail 11 ms). A split weighted by **bandwidth** (not just RAM) would shift layers toward the faster node, cutting per-token latency — subject to each node still fitting its shard + KV cache. Capacity-vs-speed tradeoff; only matters on mismatched hardware. See `cluster-benchmark.md` bandwidth note. |
| **Flash-Decoding (KV-split + online-softmax merge)** | ⬜ **to explore** | long-context decode + fills the pipeline bubble | See below. |

---

## Flash-Decoding (KV-split + online-softmax merge)

**Source of the idea:** the standard Flash-Decoding technique (also used as the
"tail KV split" in the moonmath.ai MI300X attention kernel writeup,
https://moonmath.ai/cdna3attention/). It is the one *hardware-agnostic,
algorithmic* idea in that otherwise CDNA3/HIP-kernel-specific article.

**The mechanism.** Split the attention computation's **K/V range** across multiple
parallel workers. Each worker computes a partial attention output over its slice
of the keys/values **plus the slice's log-sum-exp**. A small `merge` step then
recombines the partials into the exact full-attention output via online-softmax
rescaling — mathematically identical to computing attention over the whole KV at
once. The split is along the *sequence/context* axis, not the layer or head axis.

**Why it could matter for this cluster (two distinct angles):**

1. **Long-context decode (the natural fit).** As the KV cache grows, each decode
   step's attention becomes bound on *reading the KV cache* — a cost separate from
   weight streaming, and the report flagged it as "a dominant bottleneck across a
   network boundary" (KV-cache disaggregation, arXiv:2605.13734). Flash-Decoding
   splits that KV read across parallel workers. Relevant only once we serve long
   contexts; not the current bottleneck.

2. **Filling the pipeline bubble (speculative, larger effort).** Our pipeline
   cluster leaves one GPU idle while the other computes. Flash-Decoding's pattern —
   "split work across idle compute units, merge via log-sum-exp" — is conceptually
   the lever for using that idle GPU. BUT: our idle resource is a *whole node
   across the network*, and a layer's KV lives on the node that owns that layer.
   Applying it cross-node means **context/sequence parallelism** (shard the KV
   cache by token-range across nodes) — a new parallelism axis distinct from the
   pipeline/tensor/expert axes we've built/designed. Substantial design, not a tweak.

**Caveats / open questions before investing:**
- **Does MLX-swift already do this single-node?** Upstream MLX added Flash-Decoding
  to its attention path. If MLX's decode attention already splits KV internally, we
  get the single-node benefit for free and there is nothing to build at the kernel
  level — the only open work would be the *cross-node* context-parallel version.
  **Verify first** (cheap: read the MLX `scaled_dot_product_attention` / decode path).
- It only helps when **attention over a long KV** is a meaningful fraction of step
  time. At short contexts (our benchmarks so far) it's negligible — weight streaming
  dominates. So this is a *long-context* lever, gated behind a real long-context
  use case.
- The cross-node version interacts with our encrypted ring + the
  composition-control protocol; the merge step would be another collective.

**Verdict:** keep in the backlog. Not a current-bottleneck win (throughput was, and
continuous batching addressed it). Promote it when (a) we target long-context
serving, or (b) we pursue context-parallelism to fill the pipeline bubble. First
concrete step is the cheap MLX-already-does-it check.

---

## Note on kernel-level work (why we operate above the kernel — and when not to)

Darkbloom's leverage has been at the **distributed-systems layer** (ring transport,
batching, scheduling), not the **attention-kernel layer**, because:

1. Our measured bottlenecks are weight-streaming bandwidth, the pipeline bubble, and
   the network hop — none of which a faster attention kernel touches.
2. MLX/Metal owns the kernels; we'd be competing with Apple's tuned
   `scaled_dot_product_attention` rather than the unsolved distributed problem.

**When kernel work would be worth it:** if profiling ever shows *attention compute*
(not weight streaming) as a top-3 cost — e.g. long-context decode, or a
MoE/attention shape MLX hasn't tuned for Apple GPUs — then a custom Metal attention
kernel (the Apple-Silicon analogue of the moonmath MI300X work) becomes a real
lever. Until a profile says so, it's premature. The article's transferable
meta-principle ("optimization is a memory-placement argument; plan the pipeline by
hand for known shapes") applies to a Metal kernel just as it does to CDNA3.
