# 015 — Explorer: papers and algorithms for hybrid MoE prefill

Status: six measurement candidates; no implementation proposed

Scope: Qwen 3.6 35B-A3B text prefill on one M3 Max, through the real CBv2
path. The target is aggregate B=1/B=2/B=4 prefill throughput, not isolated
decode or a paper's multi-GPU result.

## Transfer verdicts

- **Orca selective batching transfers.** Tokenwise projections and MoE can
  flatten tokens across requests while full attention, KV offsets, masks, and
  GDN state remain request-local.
- **Sarathi / SplitFuse transfers conditionally.** Coalescing prefill and
  decode into one weight-loading forward is useful in live mixed traffic.
  Splitting a pure prefill into more forwards is not intrinsically useful here:
  at 512+ tokens top-8 routing already touches almost all 256 experts, so each
  extra chunk can re-stream nearly the full model. It also cannot by itself
  improve the required prefill-only burst metric.
- **Expert parallelism does not transfer.** There is one GPU and no remote
  expert placement or all-to-all to optimize. The transferable part of MoE
  systems work is dropless local token packing, expert-major grouped GEMM, and
  cheap dispatch/combine.
- **Unified memory removes copies, not contention.** CPU and GPU can address
  the same arrays, but model weights, activations, score tiles, and concurrent
  streams still contend for one memory system. M5 Metal 4 TensorOps results
  must not be projected onto this M3 Max.

## Card 1 — Make packed prefill layer-major, not merely scheduler-visible

**Mechanism**

Form one rectangular cohort for equal-length prefill chunks and execute one
layer-major forward. Flatten `[B, L, H]` to `[B*L, H]` for norms, projections,
router, shared expert, and routed MoE. Keep a segment descriptor for each row;
full attention uses that row's causal mask/KV offset, and each of the 30 GDN
layers uses a separate recurrent state row. Sort all `B*L*8` assignments
together, not once per request.

This is Orca's selective-batching boundary specialized to a hybrid recurrent
model. The existing capability and `packedPrefillActivity()` prove that a
rectangular call occurred, but not that every expensive submodule retained the
shared token axis.

**Why it could move aggregate tok/s**

At 512 tokens one request already presents about 4,096 expert assignments and
is likely to touch all 256 experts. Adding B=2/B=4 rows therefore increases
tokens per already-loaded expert rather than increasing the expert set. A real
`[4, 512]` layer pass can amortize router, dense/shared weights, routed-expert
weights, graph dispatch, and expert tiles across four requests. This directly
targets the observed signature where four prefills have approximately solo
aggregate throughput.

**Why it might not**

The current Qwen path may already flatten exactly this way; if so this card is
a diagnosis, not a new optimization. Full attention and GDN still perform work
per token, and four rows may make those stages compute-bound. Unequal arrivals
also fragment rectangular cohorts.

**Darkbloom merge risk**

Medium-high. Row mixing would corrupt KV, GDN state, position IDs, cancellation,
or final-state commit while still producing plausible text. Keep text-only as
the first scope; vision spans and MTP need their own gates. Existing solo versus
packed token-exactness and recurrent-state tests must remain hard gates.

**First measurement**

On one layer and then end-to-end, compare four sequential `[1,512]` forwards
with one `[4,512]` forward at identical tokens. Record packed activity, actual
shapes entering Qwen MoE/GDN/attention, quantized-GEMM dispatch count, expert
histogram/tile occupancy, bytes read if available, wall time, and output plus
final KV/GDN-state parity. Then repeat the full 512/2K/8K B=1/B=2/B=4
matrix.

## Card 2 — Reuse one dropless expert route plan across quantized projections

**Mechanism**

After top-8 routing, build one stable expert-major plan: assignment permutation,
inverse mapping, per-expert segment starts, and BM=32 tile descriptors for the
whole packed cohort. Feed that plan to the existing separate packed-4-bit
`gate_up` and `down` quantized GEMMs, keeping intermediate rows in expert order
until `down` finishes. Combine top-8 outputs only after the last expert
projection.

This borrows MegaBlocks/Tutel's dropless packing principle without importing
capacity padding, token dropping, all-to-all, or expert parallelism. It is
deliberately **not** the dead MoE mega-kernel and does not retry the rolled-back
direct weighted unsort reduction. The projections remain independently tiled;
only route metadata and expert-major residency are shared.

**Why it could move aggregate tok/s**

With all experts active, skipping inactive experts has almost no value. The
useful lever is making each expert's variable-M token slab as large and
contiguous as possible, then avoiding repeated `argSort`/inverse-sort and
descriptor construction. Cross-request packing can turn short expert rows into
full tiles and let each projection consume packed 4-bit weights directly.

**Why it might not**

`gatherQuantizedMM(sortedIndices: true)` and the E=256 expert-tile route may
already do nearly all of this. Metadata work can be tiny relative to reading
and multiplying expert weights. `down` depends on the activated `gate_up`
result, so the two weight matrices cannot share one arithmetic pass.

**Darkbloom merge risk**

Medium. A stable plan must preserve duplicate top-k assignments, exact routing
weights, quantization mode/group size, and original token-slot order. Any
specialization must fail closed to the generic path outside the exact
E=256/top-8/4-bit-g64 contract. Changes likely live in the pinned MLX kernel
surface, increasing upstream maintenance risk.

**First measurement**

Profile one real-model MoE layer at 512/2K packed tokens. Split time and traffic
among router/top-k, both sorts, descriptor build, gate-up QMM, activation, down
QMM, unsort, and weighted combine. Count descriptor builds per layer and report
the expert row-length distribution plus partial BM=32 tiles. Continue only if
route/descriptor work or partial-tile waste is material, or if a projection
reads an expert's weights more than once for the same cohort.

## Card 3 — GDN prefill via chunkwise WY, decode via the existing recurrence

**Mechanism**

Use the Gated DeltaNet paper's chunkwise parallel form for prompt tokens. Within
a modest chunk (start with C=64 or 128), represent products of gated
Householder-like state transitions with compact WY factors. Compute local
outputs and the chunk state transform with matrix multiplications, then compose
chunk boundary states in order. Preserve one FP32 state per batch row. Keep the
current serial Metal recurrence for T=1 decode and as the reference fallback.

**Why it could move aggregate tok/s**

Thirty of forty layers are GDN. The current kernel loops over T serially inside
each `(batch, value-head, value-dimension)` work item. WY moves much of that
sequence dependence into larger GEMMs, which should expose more parallel work
and improve occupancy for prefill. Packing B rows multiplies independent
chunks without changing the recurrence.

**Why it might not**

The current fused serial kernel keeps a state slice in registers and may be
efficient on M3 despite low algorithmic parallelism. WY adds triangular/local
products, temporary traffic, and more arithmetic; C=64/128 with Dk=Dv=128 may
be too small for a net win. The prior estimate is only 5–7%, so this is unlikely
to deliver 2.5x alone.

**Darkbloom merge risk**

High numerical risk, medium serving risk. WY changes floating-point operation
order over thousands of recurrent updates. It must match Darkbloom's FP32-state
contract closely enough to preserve greedy output and state continuation at
every CBv2 chunk boundary. Masks, cancelled rows, packed rows, prefix reuse,
and staged recurrent-state commit all require coverage. The decode kernel must
remain untouched unless separately qualified.

**First measurement**

First isolate the 30 GDN layers' share of 512/2K/8K prefill with GPU timing and
occupancy. Then compare a reference implementation of one layer's serial
recurrence against WY at C=32/64/128: output error, final-state error, peak
allocation, and wall time for B=1/2/4. Reject before end-to-end work if GDN is
not a large wall-time fraction or the temporary-memory roof is unsafe.

## Card 4 — Exact streaming full attention at target lengths; sparse only as a named quality mode

**Mechanism**

For the ten full-attention layers, use a D=256-specific streaming/online-softmax
kernel: tile QK, apply causal plus per-row offset mask in the tile epilogue,
update online max/sum, and immediately accumulate PV. Never materialize the
full score matrix. Requalify the existing numerically-correct Steel D=256 path
with a stable-power A/B rather than assuming it is faster.

Block-sparse attention is a separate, explicitly approximate extension for
very long contexts (for example >=32K), not an optimization to silently turn
on for the 512/2K/8K goal. It changes which token pairs exist and therefore can
change logits and quality. It needs a separately named model/capability or an
explicit user-visible quality setting plus retrieval/perplexity evaluation.

**Why it could move aggregate tok/s**

At 8K, ten dense-attention layers can generate large score traffic and
allocation pressure. Online softmax removes score writes/reads and mask
materialization while preserving exact dense attention. It also reduces the
chance of a `maxBufferLength` or unified-memory spike at B=4.

**Why it might not**

Only one quarter of layers use full attention, while MoE weights are paid in
all forty. At 512 and 2K, launch overhead or projections may dominate.
FlashAttention's published CUDA/HBM gains do not predict a Metal D=256 win, and
the existing Steel candidate has no stable speed result. Sparse attention
cannot help the required <=8K matrix without accepting a quality change.

**Darkbloom merge risk**

High. The exact path must cover partial rotary, GQA H=16/KV=2, D=256, arbitrary
CBv2 offsets, packed row isolation, and all supported masks. Every Metal
evaluation site must remain under the catchable MLX error path; no
`fatalError`. An approximate sparse path also needs product/protocol clarity so
the coordinator never routes a dense-quality request to it.

**First measurement**

Measure attention-only wall time, allocated bytes, GPU read/write counters, and
end-to-end share at L=512/2K/8K for B=1/2/4. Run current versus Steel with AC,
High Power, identical thermal posture, and exact logits/KV checks. Do not build
sparsity for this goal; first establish the dense attention ceiling. If a later
32K product experiment is approved, measure quality before throughput.

## Card 5 — A weight-stream-aware cohort budget, not a universal small chunk

**Mechanism**

Use two scheduling regimes:

1. For a pure-prefill burst, choose the largest memory-safe rectangular cohort
   `[B, C]` that lets all rows share each layer's weights once.
2. For mixed live traffic, use Sarathi/SplitFuse's decode-first token budget,
   then fill the remainder with prefill chunks that join the same layer-major
   forward.

The cohort cost model must include both total tokens `B*C` and attention
history/score working set. It should prefer `[4,2048]` over four `[1,2048]`
for weight reuse when memory permits, but shrink before an unsafe attention
shape. This is a new reason to sweep cohort geometry; it is not a retry of the
already-wash solo-2048 stripe.

**Why it could move aggregate tok/s**

Sarathi assumes a moderate chunk already saturates a conventional dense GPU
and accepts repeated KV reads for latency. Here every 512-token chunk also
touches nearly all experts. Reducing the number of *model* passes, while
coalescing B rows into each remaining pass, attacks the dominant 21-GiB
weight-stream count. It is the most direct scheduler-side route to a B=2/B=4
aggregate multiplier.

**Why it might not**

Larger C raises full-attention work and peak intermediates; B=4 can cross from
weight-bound to compute- or allocation-bound. The 164-GiB allocation incident
makes blind one-shot 8K invalid. Solo stripe 2048 was already a wash alone, so
a win requires demonstrated cross-row sharing, not merely larger chunks.
Decode-first mixed scheduling improves live serving capacity but does not
raise a prefill-only benchmark when no decode row exists.

**Darkbloom merge risk**

High. Scheduler, KV capacity, recurrent-state staging, cancellation latency,
decode TBT, and provider/coordinator token-budget admission can diverge. A
machine-specific policy cannot silently become a fleet-wide constant. Memory
prediction must fail safe and retain the current 512/2048 paths.

**First measurement**

Without changing kernels, sweep C=512/1024/2048 and only memory-safe larger
values for B=1/2/4. Record actual packed group shapes, number of full model
passes, aggregate tok/s, TTFT, peak allocation, full-attention time, and memory
bandwidth. The decisive plot is aggregate throughput versus model-pass count
at equal total prompt tokens. Separately measure mixed decode+prefill only as a
serving result, never as the required prefill speedup.

## Card 6 — Wavefront only the ragged work that cannot be packed

**Mechanism**

Use separate MLX/Metal streams for independent request graphs or cohort tails,
with events only at true dependencies. While one request/cohort runs a
low-occupancy recurrent or narrow expert kernel, another can occupy otherwise
idle execution resources. Keep equal-shape main chunks on Card 1's packed path;
wavefront is for ragged arrivals, final short chunks, or evidence that a single
packed graph still leaves large GPU holes. Overlap CPU graph construction with
GPU execution as the lowest-risk first step.

**Why it could move aggregate tok/s**

Prior profiling says busy-union equals summed kernel time with no overlap and
only about 24% of peak compute. Independent B=2/B=4 prefills provide real
parallelism across requests even though each individual layer is sequential.
If the limiting kernels are occupancy- or launch-bound rather than
bandwidth-bound, concurrent encoding can fill bubbles and approach a
structural multiplier.

**Why it might not**

Streams do not create memory bandwidth. Concurrent MoE kernels may fight over
the same 21-GiB weights, destroy cache locality, and lose the weight sharing
that packed cohorts provide. MLX may already serialize primitives onto one
queue, or memory pressure may force task throttling. Full attention and large
QMMs may already occupy the GPU enough that overlap is illusory.

**Darkbloom merge risk**

Very high. CBv2 currently relies on a serial engine queue, one `asyncEval`
boundary, staged KV/GDN commits, deterministic cancellation, and bounded lazy
graphs. Multiple streams introduce ordering, lifetime, error-propagation, and
peak-memory hazards. It should be shape-gated, retain serial fallback, and
never permit two writers to one request's cache/state.

**First measurement**

Use a GPU capture on two independent real 512-token prefills: serial versus two
streams, with identical outputs and states. Report busy-union, kernel overlap,
memory-read utilization, peak allocation, and makespan. Repeat at 2K and with
one packed `[2,C]` control. Continue only if concurrent streams beat the packed
control or recover ragged-tail time without increasing failures or memory
materially.

## Sources

- Yu et al., [Orca: A Distributed Serving System for Transformer-Based
  Generative Models](https://www.usenix.org/system/files/osdi22-yu.pdf), OSDI
  2022 — iteration-level scheduling and selective batching.
- Agrawal et al., [Taming Throughput-Latency Tradeoff in LLM Inference with
  Sarathi-Serve](https://arxiv.org/abs/2403.02310), OSDI 2024 — chunked
  prefill, decode-maximal batches, and repeated prior-KV reads.
- Holmes et al., [DeepSpeed-FastGen](https://arxiv.org/abs/2401.08671), 2024 —
  Dynamic SplitFuse and fixed token-composition budgets.
- Gale et al., [MegaBlocks: Efficient Sparse Training with
  Mixture-of-Experts](https://arxiv.org/abs/2211.15841), MLSys 2023 —
  dropless variable-size expert blocks.
- Hwang et al., [Tutel: Adaptive Mixture-of-Experts at
  Scale](https://arxiv.org/abs/2206.03382), MLSys 2023 — sparse dispatch and
  combine; its distributed all-to-all results do not transfer to one GPU.
- Li et al., [MoE-Gen: High-Throughput MoE Inference on a Single GPU with
  Module-Based Batching](https://arxiv.org/abs/2503.09716), 2025 — batching at
  module rather than whole-model boundaries.
- Yang et al., [Parallelizing Linear Transformers with the Delta Rule over
  Sequence Length](https://arxiv.org/abs/2406.06484), NeurIPS 2024 — compact
  WY and chunkwise DeltaNet.
- Yang et al., [Gated Delta Networks: Improving Mamba2 with Delta
  Rule](https://arxiv.org/abs/2412.06464), 2024 — gated chunkwise WY form.
- Dao et al., [FlashAttention](https://arxiv.org/abs/2205.14135), NeurIPS
  2022 — exact online-softmax IO tiling; block sparsity is approximate.
- MLX, [Lazy Evaluation](https://ml-explore.github.io/mlx/build/html/usage/lazy_evaluation.html)
  and [project overview](https://github.com/ml-explore/mlx) — dynamic graphs,
  evaluation boundaries, and unified memory.
- Apple, [Metal Performance Primitives Programming
  Guide](https://developer.apple.com/download/files/Metal-Performance-Primitives-Programming-Guide.pdf)
  — occupancy/tile tuning and Apple GPU memory hierarchy. Its Metal 4
  TensorOps examples target newer hardware, not the M3 Max.

