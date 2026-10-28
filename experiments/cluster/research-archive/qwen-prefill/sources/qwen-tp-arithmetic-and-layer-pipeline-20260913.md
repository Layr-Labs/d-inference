# Qwen TP arithmetic seams and a whole-layer prefill pipeline

Source-only design review, 2026-09-13. No native build, MLX/GPU execution, hardware qualification, or performance measurement. Repository: `/Users/developer/DarkbloomDev/d-inference`.

## Evidence and immediate interpretation

Root's verified real 9B full-TP comparison fails the strict numeric gate with native output projections (relative RMS about .0163) and with both attention/FFN output projections widened (about .01375). Both ranks agree and source/selected byte identities pass. In the widened case the first selected token changes: baseline IDs 4087 and 10926 tie at 19.875; TP lowers 4087 to 19.75 while 10926 remains 19.875. This is consistent with one BF16 step breaking a tie. It does not establish the first arithmetic cause, nor prove a topology/state bug. This model is dense: MoE router instability is not an explanation here.

The next diagnostic should target input projections before adding another broad precision policy. Existing widening changes the input dtype of `down_proj`, `o_proj`, and `out_proj`, retains FP32 through the rank sum, then casts once. It does not change earlier gate/up or Q/K/V/GDN input projections and nonlinearities.

## Concrete unaddressed seams

Pinned `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/quantized.cpp` dispatches using M/K/N at lines 90 and 2008. `qmm_splitk` (1125–1222) chooses split count from output tile count, aligns K partitions to quantization groups, writes partial results in **input dtype** (1173), then sums. Consequently, even an output-row partition with the same input K and exact sliced weights need not preserve the full projection's BF16 rounding.

For an actual 9B chunk of M=32, K=4096, affine W4/G64, the source predicates give:

| Projection | Full N → rank N | Full split-K → rank split-K |
| --- | ---: | ---: |
| Dense gate/up | 12288 → 6144 | 1 → 2 |
| Fused GDN inputs | 12352 → 6176 | 1 → 2 |
| Attention paired query/gate | 8192 → 4096 | 2 → 4 |
| Attention K or V | 1024 → 512 | 16 → 32 |

These are source-derived dispatch predictions, not captured kernel traces. All four use the matrix path at M=32 under the pinned K/N threshold cases. A split count of one delegates to ordinary qmm. M=1 decode and different chunk sizes require their own dispatch analysis. For 27B M=32, gate/up and fused GDN stay at split count one, but query/gate changes 1→2 and K/V changes 16→20. Do not transfer the 9B ranking of causes unchanged to 27B.

`Qwen35.swift:398–519` builds the frozen fused GDN projection from `[qkv,z,b,a]`, then slices its output. Whole-head TP preserves semantic Q/K/V and value-head groups, but halves the fused output width and moves the segments. Merely wrapping the original four input `Linear`s would **disable fusion**: eligibility requires exact `QuantizedLinear` concrete types (377–385). Such instrumentation would change the operator being diagnosed.

`Qwen35.swift:537–580` then performs depthwise convolution, SiLU, per-head Q/K RMS normalization, and recurrence. `GatedDelta.swift:138–184,297–328` keeps SSM state FP32 but returns recurrent output in input dtype. The Metal kernel (29–99) reduces within Dk, with one independent value head per grid group; preserving Dk and Hv/Hk preserves the mathematical per-head recurrence. Head-count-dependent templates/strides, convolution channel count, and earlier BF16 rounding remain checkable seams; source review does not establish them as the first mismatch.

Full attention (`Qwen35.swift:1193–1238`) changes Q/K/V projection widths and attention head/grid geometry while retaining head dimension, RoPE, GQA ratio, and paired query/gate ownership. Per-head RMSNorm and sigmoid gating are still rounded before the output projection. Even widened down/output projections change K partitioning and floating reduction order; they cannot retroactively repair their inputs.

Smallest causal check: feed the **same evaluated first-layer normalized BF16 input** into the actual fused GDN projection rebuilt from its stored packed triplets, full versus two selected counterparts; compare selected Q/K/V/z/b/a values before convolution. Repeat dense gate/up and attention input projections with common captured inputs. Reproduce fusion and its full output shape; do not attach input subclasses. Only if those agree proceed to conv/SSM/per-head attention captures. Record exact operator shapes/dtypes, max/RMS differences, BF16-step counts, and first divergence. Keep solo and candidate policy/chunk histories identical.

## Pipeline feasible without a pinned-source fork, with explicit stage construction

The public CBv2 adapter does **not** offer a layer range. `Qwen35TextModelInner.layers` is fileprivate (`Qwen35.swift:1576`); `Qwen35DecoderLayer` and its forward are internal (1461,1525). A `Module` tree exposes weights/children, not a callable public decoder interface. Avoid unsafe casts or replacing decoders with approximations.

A bounded two-stage dense prototype can instead construct two smaller public `Qwen35TextModel`s from JSON. Keep every active layer's original hidden/intermediate/head/quantization geometry; change only local layer count and corresponding layer-type list. Split at a multiple of `full_attention_interval=4`, so reindexing preserves the 3-GDN/1-attention pattern: 9B 16+16, 27B 32+32 are initial candidates, not performance-optimal balances. Reject other phases and nonuniform policies until their remapping is explicitly supported.

* Stage 0: public `cbv2ForwardWithHidden(_:caches:recurrentState:positionIds:)` (`Qwen35.swift:2002`) returns the complete `[B,M,H]` **pre-final-norm hidden** from its last local decoder. Retain this hidden and state roots; discard its logits. Despite the MTP protocol name, the noncaptured method runs normal CBv2 arithmetic and does not require an attached MTP head. Never use `cbv2ForwardWithHiddenCaptured`.
* Stage 1 prefill: public `cbv2RecurrentPrefill(... inputEmbedding: hidden, requirement:)` (1974), directly or through `CBv2SteppableLanguageModelAdapter.recurrentPrefill` (`SteppableAdapterV2.swift:137`). This bypasses its token embedding and runs its local layers. Intermediate chunks use `.evaluationOnly`; the final chunk uses `.lastPositionLogits`, matching the existing solo CBv2 end norm/head shape.
* Stage 1 decode: public recurrent `embeddingForward(... inputEmbedding: hidden, ...)` (1929). Send the real token IDs as shape/sequence metadata as well; retain original token positions. The receiving stage is not receiving token embeddings: it receives the prior stage's raw residual stream.

### Weight ownership is a required separate implementation

Discarding lazy stage-0 logits does **not** solve unused parameter allocation. Compact models still declare stage-0 final norm/head and stage-1 embedding. The current direct loader requires full-key coverage and calls `eval(model)`; using it unchanged would load/materialize unwanted tensors or defaults.

A stage-aware verified loader must map source global layers `[start,end)` to local `[0,count)`, preserving per-path quantization policy and original source identity. Stage 0 owns the actual embedding plus its layers; stage 1 owns its layers plus actual final norm/head. Exclude vision/MTP. Retain exact manifest/file verification, record source-name→local-name mapping, stage configuration/layout hashes, active/inert parameter inventories and selected byte counts, and prove each active parameter is loaded exactly once across stages.

Before any global evaluation, replace unused declared children with explicit tiny inert modules (using public `Module.update`, `Embedding(weight:)`, and `Linear(weight:bias:)`) or implement a wrapper that evaluates only owned active roots. A safe first loader should do both explicit inactive replacement and active-only evaluation, and reject invocation of the wrong embedding/head path. Stage-0 discarded head can return a tiny unused shape; it is not an executed original operator. Stage-1 inert embedding must carry the true incoming activation dtype: `Qwen35+CompleteCheckpoint.swift:10–29` derives KV/conv dtype from embedding metadata. The actual output head remains unchanged. Reject tied embeddings initially or define their explicit duplication/ownership; do not silently repurpose a tied output head. The verified current 9B/27B text constructors use an independent head.

## State, concurrency, and smallest prototype

Each stage owns its own compact attention bank and `CBv2RecurrentRequestState`, derived from its local config. All cache and recurrent layer IDs are local; the stage commitment records the global offset. Sequence positions are **not** local-layer indices: both stages advance exactly the same token frontier.

Within a stage, process a request's chunks in order. Bind one recurrent evaluation; stage every local GDN layer; evaluate outgoing hidden/result **plus all recurrent and KV/device-offset roots**; check errors; commit; then accept the next chunk. `RecurrentStateV2.swift:362,410,667` rejects overlapping open bindings and out-of-order commits. Start with one evaluated/committed chunk per stage, no pending-generation chaining.

After stage 0 has finished chunk j, it can process j+1 while stage 1 processes j: lower-layer state depends only on its own earlier chunks, and stage 1's chunk j needs no future lower-layer states. Use a bounded queue/credits (one pending boundary buffer initially). Preserve exact BF16 bytes, shape/stride normalization, request/epoch/chunk sequence, token offset and length, config/manifest/stage identity. No dtype conversion or hidden quantization on the wire. Complete a send before releasing/reusing its buffer. On timeout/cancel/malformed sequence, retire both stages' entire request; do not reuse an advanced stage's state after peer failure.

Proposed sequence: (1) tiny seeded dense hybrid, eight layers split4+4, original F32/BF16 widths; one-process sequential stages versus same-chunk solo, teacher continuation; compare all logits and remapped per-layer KV/conv/SSM states. (2) Explicit compact-byte copy between stages, then two local processes with bounded framed point-to-point transport; exact identity, malformed/reordered-frame and missing-peer failures. (3) Verified 9B 16+16, bounded prompt96/chunk32/output4, controlled teacher history, same solo CBv2 baseline. (4) Only after correctness, add one-chunk overlap and measure on actual two machines. No existing loopback synthetic/real opt-in guard should be weakened implicitly.

Cmlx already declares `mlx_distributed_send/recv` (`include/mlx/c/distributed.h:51–70`) and both JACCL and ring implement them. The current harness `Collective` only exposes all-sum: an explicit independently validated point-to-point wrapper is still needed, including evaluation/lifetime and deadlock-order rules. API presence is not working RDMA evidence.

## Communication and performance implications

At batch1/M32/BF16 the boundary payload is 262,144 bytes for 9B or 327,680 bytes for 27B. A two-stage pipeline needs one forward hidden transfer per prompt chunk, plus small control frames; full TP has two all-sum boundaries per layer per forward (64 for9B,128 for27B), each logically spanning `[B,M,H]`, with backend-dependent wire amplification. FFN-only TP has one per layer. These are operation/payload counts, not achieved network bandwidth or TPS.

Pipeline overlap can improve long-prompt throughput after filling both stages, but fill/drain, imbalance, transfer latency and smaller-M kernel efficiency matter. Matched solo tests must use the same microchunk schedule: preserving full widths/heads does not preserve a former large-M operator if prompt chunking changes. One request's autoregressive decode still runs stage0→transfer→stage1→selected-token return in series, so this design is primarily a prefill candidate, not a promised decode accelerator. Layer balancing should later include embedding/head placement and measured stage time rather than equal layer count alone.

Pinned source SHA256: Qwen35.swift `11a8a5acff21ee96190c4eefaca4e90dfd8e29e2ae10f30307394cf937bf1321`; GatedDelta.swift `4d46bb3298a108cef95cd2841b10611fea4440a3202e605760817e5dca7110a9`; Metal quantized.cpp `4169fb17a4d53b7df1578ccec5f92646439d70769b547dcffc48f9514a1fbc2d`.
