# 054 — Speculative / approximate prefill with immutable Qwen weights

Status: **analysis and preregistered A/Bs; no implementation and no new M3
measurements**

Scope: Qwen 3.6 35B-A3B text prefill on the locked M3 Max, through the real
ContinuousBatchingV2 path. The target checkpoint bytes and hashes remain
unchanged. Approximate execution is allowed only as an explicit, quality-gated
policy. All speed projections below are screening bounds, not measured wins.

## Verdict

There are two algorithmic families with a mathematical route to the 2.5x
**cold, equal-length B=2/B=4 8K** bar:

1. **Process at most about one third of the prompt with the full target** after
   a genuinely cheap selector. Draft-assisted sparse prefill, structured prompt
   compression, and landmark-plus-tail prefill are variants of this idea. With
   selector cost equal to 8% of baseline, the target may retain at most 34.7%
   of 8K tokens in an optimistic FLOP model. The resulting target KV and GDN
   state is decode-ready, but it represents the selected sequence, not the
   original full sequence.
2. **Run the first 4–8 Qwen layers normally, synthesize every skipped layer's
   attention KV and GDN boundary state from the last exact hidden rows, then
   run the frontier token through all remaining layers.** A concrete
   fixed-weight "hybrid state river" has an optimistic cost of 0.286x baseline
   after 4 exact layers and 0.365x after 8. It produces a complete,
   dimensionally valid cache/state with no deferred repair. Whether that state
   preserves quality is entirely unproven.

Everything else misses or changes the experiment:

- A lower-precision pass over the whole target must itself be at least 2.5x
  faster before any correction. Existing M3 measurements show only 1.03–1.06x
  on the dominant gathered QMM shapes, and half accumulation failed
  correctness.
- Static layer-wise token pruning can cross the arithmetic bar only with very
  aggressive retention (at most 27.4% after layer 8 in the optimistic 8K
  model). Dynamic revival does not transfer from Transformer-only LazyLLM:
  reviving one old token cannot locally repair Qwen's 30 chronological GDN
  states.
- Exact reconstruction of pruned/merged tokens restores essentially all of the
  skipped work. Approximate reconstruction is another quality mode.
- Exact prefix memoization is a strong **warm-hit** product optimization but
  gives no cold-miss speedup. Arbitrary block memoization is not context-free,
  especially for GDN. It cannot count toward this cold goal.

No paper result is evidence that Qwen reaches the bar on this M3. SpecPrefill's
7.66x result used an 8B Llama speculator and a 405B Llama target on 8 H100/H200
GPUs; LazyLLM reports up to 2.34x; FastKV 1.82x; River-LLM 1.71–2.16x.
River-LLM is training-free but copies and post-training-quantizes W4A16 exit
layers, so it is outside strict fixed-parameter mode. These papers establish
mechanisms and risks, not transfer numbers.

## 1. Binding contract

### 1.1 Baselines and bars

The schema-6 matrix in note 038 and the primary runs in note 037 are binding:

| Cell | Native aggregate | Native makespan | 2.5x bar |
|---|---:|---:|---:|
| B=2, 8,192/row | 1,500.7 tok/s | 10.9165 s | **4.3666 s / 3,751.8 tok/s** |
| B=4, 8,192/row | 1,557.4 tok/s | 21.0375 s | **8.4150 s / 3,893.5 tok/s** |

Inputs remain the same locked, distinct 8K rows and arrive as one burst. "Cold"
means no prompt/prefix/block state hit. Model weights may already be resident,
as in the native control. Any selector, compressor, draft forward, cache
transfer, reconstruction, state materialization, and frontier computation is
inside the makespan.

The 512/2K B=1/B=2/B=4 matrix remains a disclosure and non-regression gate.
Approximate methods generally have less redundancy at short lengths, so an 8K
win must not be silently generalized to those cells.

### 1.2 What "usable state" means for this hybrid

Returning plausible first-token logits is insufficient. Before the first token
is released, every request must own:

- all ten full-attention layers' intended K/V entries, their original or
  explicitly remapped positions, and a logical next position;
- all thirty GDN layers' BF16 convolution tail
  `[1, 3, 8192]` and FP32 SSM state `[1, 32, 128, 128]`;
- a full-depth frontier token and logits conditioned on exactly those stored
  states;
- materialized evaluation roots. MLX laziness may not move cache construction
  behind the first-token timestamp;
- normal transactional commit, rollback, cancellation, and memory accounting.

Approximate or sparse state may be "usable" if the next decode token can run all
40 layers immediately without missing-state reconstruction. It is not
**equivalent** state unless a full-prompt reference proves that.

The size makes hand-waving expensive:

```text
full-attention KV/token
  = 10 layers × 2(K,V) × 2 KV heads × 256 × 2-byte BF16
  = 20,480 bytes = 20 KiB/token

8K full-attention KV/row                         = 160.0 MiB
one GDN conv + FP32 SSM state                    = 2,146,304 bytes
thirty GDN boundary states/row                   = 61.406 MiB
8K decode-ready native state/row, before overhead = 221.406 MiB
```

The Qwen implementation reflects this split:

- `Qwen35TextConfiguration.cbv2LayerKinds` exposes only the ten attention
  storage rows;
- `cbv2RecurrentStateSpec` separately declares the thirty GDN states;
- `Qwen35GatedDeltaNet.cbv2Forward` consumes and stages them in chronological
  order;
- `GatedDelta.swift` keeps the recurrent state FP32;
- Qwen starts from `initialRecurrentTarget` and enables packed prefill and MTP,
  but **does not enable prefix reuse**.

The existing MTP prefix replay is useful evidence about the dependency. It can
reconstruct a shorter **contiguous** accepted prefix only because it retains the
exact pre-state and transformed `q/k/v/a/b` inputs. It is not a mechanism for
inserting an old token into an already-advanced GDN state.

### 1.3 Immutable weights

No target tensor may be retrained, requantized in the checkpoint, replaced, or
patched. In particular, SwiftKV's distilled Q/K/V projections and trained
Landmark Attention are outside this contract.

An independent, already-trained draft model does not mutate Qwen's weights, but
it adds learned parameters and a second deployment artifact. Results must say
which interpretation they use:

- **strict fixed-parameter mode:** only the target's existing weights, norms,
  and inline heads may execute;
- **fixed-target mode:** an independently hashed draft model may be resident,
  but its load time, memory, compatibility, and execution cost are reported.

The first four Qwen layers are the default selector if added learned parameters
are disallowed.

## 2. Honest 2.5x cost screen

At 8K, note 026's model ledger gives:

```text
linear projections          4.8734 GFLOP/token
GDN recurrence              0.1101 GFLOP/token
ten full-attention layers   0.6711 GFLOP/token
total                       5.6547 GFLOP/token
```

If a full-depth target pass retains a uniform fraction `r` of prompt tokens,
the optimistic target-work fraction is:

```text
q_8K(r) = 0.8813 r + 0.1187 r²
```

The token-linear terms scale with `r`; attention among retained tokens scales
with `r²`. Real wall time will be worse when shorter rows underfill kernels or
when selection, compaction, cache writes, and graph boundaries are included.

Let `a` be selector/compressor/draft wall time normalized by the adjacent
native makespan, and `c` all correction and state-finalization cost not already
inside `q`. A candidate has a route to 2.5x only if:

```text
a + q_8K(r) + c <= 0.400
```

With `c=0`, the maximum retained fraction is:

| Selector fraction `a` | Maximum target retention `r` |
|---:|---:|
| 0% | 42.9% |
| 5% | 37.8% |
| 8% | **34.7%** |
| 10% | 32.6% |
| 20% | **22.0%** |
| 30% | 11.2% |

At 512 and 2K, attention is only 0.85% and 3.26% of modeled work. Even a free
selector requires retention below 40.2% and 40.8%, respectively. Approximation
must therefore remove most token-layer work at every required length; sparse
attention alone cannot do it.

This equation is a necessary screen, not a performance prediction. Every
candidate still has to beat the absolute B=2 and B=4 bars on the Mac.

## 3. Candidate A — draft-assisted sparse target prefill

### Mechanism

Use either a small independent draft or the first `d` target layers to score
whole prompt blocks. Always retain:

- the complete system/developer/tool-template spans;
- role and message delimiters;
- the user query and the final prompt token;
- a configurable exact suffix;
- the top-scoring context blocks, kept in original order.

Run all 40 target layers only on the retained sequence. Preserve original
positions for full attention in one arm and compact positions in another.
SpecPrefill uses original, discontinuous positions; Qwen's GDN has no RoPE-like
gap input, so that choice is not automatically right for this hybrid.

### Decode state and frontier

This path is state-complete without reconstruction:

- each attention layer stores K/V only for selected target tokens;
- every GDN layer chronologically folds those same selected tokens into a final
  conv/SSM state;
- the mandatory final token passes all layers and produces frontier logits;
- decode starts at the original logical prompt position or the compacted
  position, according to the named policy.

The state is the target model's exact state for the **selected-token policy**.
It is approximate relative to the original prompt. CBv2 currently equates
physical cache length with advancing position, so a sparse-position cache must
separate stored K/V count from logical position and carry per-entry positions.

There is no cheap "selective correction to full-prompt exactness." Re-inserting
a removed token changes later hidden rows and every later GDN transition.

### Can it reach 2.5x?

Conditionally, yes:

- an independent draft measured at `a=0.08` leaves room for at most 34.7%
  target retention;
- first 4 Qwen layers cost approximately `a=0.10` and leave room for at most
  32.6% retention;
- first 8 layers cost approximately `a=0.20` and require at most 22.0%
  retention.

The first target full-attention layer is layer 3, so a four-layer same-model
selector can produce an attention score. It then reruns retained rows from
layer 0; reusing its first-pass states changes this into Candidate B.

SpecPrefill reports preserved quality at 10% keep on several LongBench
categories, but also task-dependent degradation, especially summarization.
That makes the arithmetic plausible, not the Qwen quality.

### A/B A1 — external draft

1. **A:** native full prompt.
2. **B0:** draft scoring only, no target run. Measure `a` at B=1/2/4 and
   512/2K/8K, including score aggregation and index transfer.
3. Continue only if 8K `a <= 0.10` at both B=2 and B=4.
4. **B1–B4:** fixed keep rates 20/25/30/35%, 16-token blocks, mandatory spans,
   exact suffix 256; original-position versus compact-position arms.
5. Run the full timing, state, forced-continuation, and quality gates in
   section 9. No prompt-specific keep-rate oracle.

### A/B A2 — same-target filter

Compare filter boundaries after layers 3 and 7. The layer-3 arm must retain at
most 30% and the layer-7 arm at most 20% before it earns an end-to-end run.
Record the selector's actual target QMM work; do not call the first pass free
because its hidden rows are later discarded.

Verdict: **plausible 2.5x path, high quality and integration risk**.

## 4. Candidate B — layer-wise pruning or token merging

### Static token-selective propagation

Run the first `d` layers on all tokens. At a full-attention boundary, select a
static subset and propagate only those rows through the remaining layers.
Layers below the boundary retain full attention KV / exact GDN state. Layers
above it retain sparse KV / GDN state computed from the selected chronological
sequence. Always propagate the frontier.

For multiples of four, the optimistic 8K work model is:

```text
c_d(r)
  = 0.8813 [d/40 + (1-d/40)r]
  + 0.1187 [d/40 + (1-d/40)r²]
```

The maximum `r` at `c_d(r)=0.4`, before pruning overhead, is:

| Full layers before pruning | Optimistic max retention |
|---:|---:|
| 4 | 36.1% |
| 8 | **27.4%** |
| 12 | 15.9% |
| 16 | 0%; the budget is already spent |

Token-linear kernel behavior gives stricter limits of 33.3%, 25.0%, and 14.3%.
The empirical prior is below the goal: LazyLLM reports up to 2.34x and FastKV
up to 1.82x on long-context Transformer models.

### Why LazyLLM-style revival does not transfer

LazyLLM stores a pruned token's hidden row in an auxiliary cache. If that token
becomes important later, a Transformer can resume it at the next layer and add
its missing K/V.

For Qwen GDN layer `j`, the current state is the ordered fold:

```text
S_N = F_N(F_{N-1}(...F_1(S_0)))
```

Reviving token `t` after `S_N` exists requires the state immediately before
`t`, then replaying `t...N` in order. Computing only `F_t(S_N)` inserts it in
the wrong position. Qwen stores one committed boundary, not all 8K boundaries.
An auxiliary hidden cache therefore cannot make dynamic revival cheap. Keeping
periodic GDN checkpoints bounds replay but moves work into decode and must be
charged to the request; it is not first-token-only repair.

The valid first experiment is static selection for the whole continuation.

### Token merging and cache reconstruction

Merging adjacent hidden rows into one representative preserves neither causal
order nor RoPE exactly. A reconstructed K/V obtained by interpolation or a
fixed projection is approximate. GDN is harder: a block's state transition
could be summarized only after its exact `k/v/a/b` inputs are known, and those
inputs require the expensive target projections and context-dependent hidden
rows the merge intended to avoid.

If all dropped rows are reconstructed exactly before decode, normalized work
returns to approximately:

```text
d/40 + (1-d/40)r + (1-d/40)(1-r) = 1
```

before merge/reconstruction overhead. Exact cache reconstruction is rejected
as a 2.5x route. Approximate merging remains an arm of static pruning, not an
exactness claim.

### A/B B1

1. Add a slow, explicit-position reference for a static sparse layer stack.
2. Prune after layers 3, 7, and 11 at 10/20/30% retention, selecting 16-token
   blocks from the boundary attention scores.
3. Keep no dynamic revival. Store per-layer position lists and all GDN final
   states; force materialization before first token.
4. Compare drop, mean-pool merge, and attention-weighted merge only at the same
   retained row count.
5. Stop a boundary if its measured candidate makespan exceeds 0.36x native
   before correction; the remaining 0.04x is needed for serving overhead and
   quality-preserving adjustments.

Verdict: **arithmetic route only under aggressive pruning; static state is
usable, dynamic revival and exact reconstruction are rejected**.

## 5. Candidate C — prompt compression

### Mechanism and state

A lexical, retrieval, or small-LM compressor rewrites or deletes designated
context spans before target tokenization/prefill. The target then runs normally
on the shorter prompt, producing ordinary complete KV/GDN state and frontier
logits. This has the cleanest decode contract.

Compression may not touch system/developer instructions, role delimiters, tool
schemas, or the user query. Arbitrary post-tokenization deletion can corrupt
the chat template. The first product arm should accept explicitly marked
compressible context spans.

LongLLMLingua reports 1.4–2.6x end-to-end latency improvement for roughly 10K
prompts compressed 2–6x, including compression time. Its compressor was a 7B
Llama and some methods in its comparison were slower than the original
request. The compressor cannot be assumed free on this one-GPU Mac.

### Can it reach 2.5x?

For 8K compressed to 2K (`r=0.25`), the optimistic target work fraction is
0.2277. More usefully, this repository already has measured 2K burst controls:

| Cell | 8K 2.5x deadline | Measured same-B 2K target | Max compressor + assembly |
|---|---:|---:|---:|
| B=2 | 4.3666 s | 2.5250 s | **1.8416 s** |
| B=4 | 8.4150 s | 4.8325 s | **3.5825 s** |

Thus a 4x compressor has a real latency route. At 3x compression, modeled
target work is 0.307x and leaves only 0.093x baseline for compression and
assembly. Quality, not arithmetic, is likely binding.

### The denominator rule

An 8K user request compressed to 2K is not an 8K target prefill. Report all
three:

1. same-original-request latency speedup, which is legitimate if quality passes;
2. submitted-input-equivalent tok/s, labeled with compression ratio;
3. actual target tokens and target tok/s.

Calling `(B × 8192) / time` unqualified "prefill tok/s" hides that 75% of the
sequence never entered Qwen. It cannot replace the native equal-work metric.

### A/B C1

Use 512/2K/8K original inputs and fixed 2x/3x/4x budgets. Compare:

- BM25/embedding whole-block retrieval with the question as query;
- a small local LM compressor, timed in-process;
- random blocks at identical budgets as a quality control;
- target-only execution of precomputed selections as an upper timing bound,
  explicitly not an end-to-end result.

Run compressor B=2/B=4 concurrently only if the serving stack can do so. Charge its
peak memory and GPU contention. Tune on a disjoint calibration split.

Verdict: **can beat 2.5x request latency at 4x compression; cannot honestly be
called same-token prefill throughput**.

## 6. Candidate D — landmark prefix plus full-depth frontier

"Landmark" here means selected native token blocks. The published Landmark
Attention method adds special tokens and fine-tunes the model; that is outside
the immutable-weight contract.

### D1 — selected landmarks plus exact suffix

Select `K` old-context tokens in blocks, retain an exact suffix of `W` tokens,
and run all 40 target layers on `K+W`. The final suffix is exact only with
respect to the selected context. Full-attention KV contains landmark/suffix
positions, and GDN state folds landmarks then suffix. Decode is immediately
usable.

At 8K:

```text
K=512, W=2048 -> r=31.25%, q(r)=0.2870
```

This can cross 2.5x only if scoring/assembly costs at most 0.113x native. An 8%
draft predicts an optimistic total of 0.367x (2.72x); a four-layer Qwen filter
predicts 0.387x (2.58x) with almost no implementation margin. An eight-layer
filter cannot meet the bar for this geometry.

`K=512, W=1024` has more speed margin but a much harsher information bottleneck.
Whole blocks are preferred over isolated tokens to preserve syntax and local
causal structure.

### D2 — approximate old boundary, exact suffix

Another proposal is to prefill the old prefix at low precision, then run an
exact target suffix from that boundary. This yields exact arithmetic on the
suffix, but not exact full-prompt hidden rows:

- suffix attention still reads approximate old K/V;
- each suffix GDN transition starts from an approximate old state;
- changed hidden rows generate changed later-layer K/V and GDN inputs.

The resulting state is self-consistent enough to execute decode, but no finite
suffix makes full attention forget arbitrary old errors. GDN state error may
contract for some prompts, but that must be measured rather than assumed.

If the approximate prefix costs fraction `a_lp` per token and the exact suffix
fraction is `w`, the token-linear screen is:

```text
a_lp(1-w) + w <= 0.4
```

At `a_lp=0.25`, at most 20% of the prompt may be exact suffix. The measured M3
FP16 route is nowhere near `a_lp=0.25`, so this arm has no current path.

### A/B D1

For 8K, cross:

- `K={256,512,1024}` landmark tokens in 16-token blocks;
- `W={512,1024,2048}` exact suffix;
- lexical, four-layer attention, and independent-draft selectors;
- original versus compact target positions.

Keep only cells whose measured selector plus target upper bound is below 0.36x
native. Evaluate adversarial needles placed in every block rank decile, not
only average QA.

Verdict: **D1 is a plausible structured sparse-prefill policy; D2 is blocked by
the lower-precision pass cost**.

## 7. Candidate E — early exit with complete state extrapolation

This is the most Qwen-specific fixed-parameter experiment.

### 7.1 Hybrid state river

Choose an exact boundary `E` after layer 3 or 7:

1. Run all prompt rows through layers `0..<E` normally. Their attention KV and
   GDN states are exact. Retain hidden rows `h_E`.
2. Exclude the frontier row temporarily. For every skipped full-attention layer
   `j`, apply layer `j`'s own input norm and K/V projections to `h_E`; apply
   RoPE at original positions and store the complete approximate prefix K/V.
3. For every skipped GDN layer `j`, apply layer `j`'s own input norm and
   `qkv/a/b` projections to `h_E`, then run its convolution and chronological
   GDN recurrence. Store the resulting conv tail and FP32 SSM state. The fused
   QKV projection computes Q even though state update needs K/V; a later
   state-only sliced projection is an optional exact work deletion.
4. Starting from `h_E[frontier]`, run the frontier through every skipped layer
   normally, reading and advancing the synthesized state at that layer.
5. Materialize and commit all cache/state roots, then sample. Decode thereafter
   runs the ordinary full 40 layers with no repair.

This uses every skipped layer's existing cache/state projection weights. It
skips old-token Q/O or Z/output projections, MoE, shared expert, router, and
residual evolution. It resembles SwiftKV's SingleInputKV or River-LLM's exit
river, extended to the 30 GDN states. Unlike those implementations, this
candidate neither distills projections nor creates post-training-quantized exit
weights.

The frontier is full-depth and exact **conditioned on the synthesized
histories**. It is not the native full-prompt frontier.

### 7.2 Optimistic cost ledger

For a skipped GDN layer, state construction needs:

```text
qkv + a + b projection     = 0.033817 GFLOP/token
FP32 recurrence            = 0.003670 GFLOP/token
total                      = 0.037487 GFLOP/token
```

For a skipped full-attention layer, K+V projection needs 0.004194
GFLOP/token. Norms, conv, RoPE, writes, frontier, and launch costs are omitted,
so this is optimistic.

Because the layer schedule repeats every four layers, the exact-prefix part at
boundaries 4/8/12 costs 10/20/30% of modeled native work. Adding all missing
state projections gives:

| Prompt length | E=4 ratio / ideal speedup | E=8 | E=12 |
|---|---:|---:|---:|
| 512 | 0.309 / 3.24x | 0.386 / 2.59x | 0.462 / 2.16x |
| 2,048 | 0.304 / 3.29x | 0.381 / 2.62x | 0.459 / 2.18x |
| 8,192 | **0.286 / 3.50x** | **0.365 / 2.74x** | 0.444 / 2.25x |

At 8K the ideal absolute budgets are:

| Cell | E=4 ideal | Margin to 2.5x bar | E=8 ideal | Margin |
|---|---:|---:|---:|---:|
| B=2 | 3.1185 s | 1.2481 s | 3.9849 s | **0.3817 s** |
| B=4 | 6.0097 s | 2.4053 s | 7.6795 s | **0.7355 s** |

E=8 has little wall-time margin; E=4 is the serious implementation candidate.
E=12 is arithmetically dead.

If "correction" means replacing the corresponding artifact-only computation
with a fraction of the skipped full token-layer work, the maximum fraction
before crossing 0.4 is:

| Length | E=4 correction budget | E=8 correction budget |
|---|---:|---:|
| 512 | 13.2% | 2.3% |
| 2K | 13.8% | 3.0% |
| 8K | **16.0%** | **5.5%** |

This fraction may be spent on selected token blocks or occasional full anchor
layers. It is not enough for broad exact repair at E=8.

### 7.3 Selective correction variants

Two fixed-weight corrections are legal:

- **landmark rows:** propagate a small selected subset through skipped full
  blocks, while other rows contribute only synthesized cache/state inputs;
- **anchor layers:** execute occasional skipped layers fully for all rows and
  use their output as the source hidden for the next state-river segment.

Both remain approximate because the selected rows/layers see synthesized
histories. They must fit the measured correction budget, not a multiplied list
of independent paper speedups.

### A/B E1

1. Build a slow array-ops reference for E=4 and E=8. Assert every one of 10 KV
   layers and 30 GDN layers is present and decode can consume 128 forced tokens.
2. Run quality only before custom kernels. Compare E=4/E=8/E=12 to native;
   E=12 is a quality control, not a speed candidate.
3. If E=4 has a viable quality signal, benchmark state projection classes and
   the end-to-end B=1/2/4 matrix. Stop if state-ready time exceeds 0.36x native.
4. Add one correction at a time: 5/10/15% landmark rows, then one anchor layer
   per segment. Recompute the additive ledger after each.
5. Preserve the ordinary full target as per-request fallback. Selection or
   confidence fallback occurs **before** approximate state is committed.

Verdict: **best fixed-target arithmetic candidate; complete state is feasible,
quality is the unknown**.

## 8. Candidate F — lower-precision full pass plus selective correction

A lower-precision pass of the same Qwen has compatible tensor shapes and can
produce all ten K/V caches, thirty GDN states, and frontier logits. Correcting
some attention K/V entries is local in storage but not local in model
semantics. Correcting a GDN transition changes every later transition, and
correcting one layer's hidden rows changes later layers' inputs.

The necessary wall-time condition is immediate:

```text
low_precision_full_pass_fraction + correction_fraction <= 0.4
```

The low-precision full pass must therefore exceed 2.5x even with zero
correction. Current evidence goes the other direction:

- FP16 W4 gathered gate/down kernels improved only 1.03–1.06x;
- half accumulation failed 30 correctness checks with very large errors;
- the checkpoint is already W4 for storage, so merely relabeling weight
  precision does not remove target token-layer work.

KV-only quantization methods such as QuantSpec and SnapKV optimize decode cache
traffic after a full prefill; they do not supply this missing prefill speedup.

### A/B F1 kill gate

Do not integrate serving first. A candidate low-precision primitive must:

1. cover the weighted real projection mix, GDN recurrence, and attention;
2. produce complete compatible state;
3. measure `<=0.30x` native weighted time, reserving at least 0.10x for
   correction;
4. pass a forced 128-token continuation quality probe.

Anything above 0.4x is dead without an end-to-end run. The current FP16 path is
already rejected by this gate.

Verdict: **no current 2.5x route**.

## 9. Candidate G — prefix and block state memoization

### Exact prefix

An exact Qwen prefix entry must contain:

- all full-attention K/V through the boundary;
- all 30 conv/SSM boundary states;
- model/tokenizer/template/execution-policy identity and tenant scope;
- the exact logical position.

Adoption then runs only the suffix and is token/logit/state exact. The existing
prefix cache intentionally caps a hit below the last token so frontier logits
are recomputed, but Qwen currently advertises `supportsPrefixReuse=false`
because recurrent state is not represented in the cache contract.

For hit probability `h`, reusable token fraction `f`, and normalized
lookup/transfer overhead `o`, a rough linear screen is:

```text
candidate fraction ~= 1 - h f + o
2.5x requires h f >= 0.6 + o
```

At a cold miss, `h=0`; the candidate is at least baseline plus lookup/donation.
It cannot reach the requested cold bar. A synthetic B=4 burst with four
identical 80%-shared prefixes is a different workload, not evidence for the
locked distinct rows.

### Arbitrary blocks

A Transformer block's K/V depends on all preceding text. CacheBlend and
Cache-Craft reuse warm non-prefix chunks and selectively recompute roughly
10–15% of high-deviation tokens; CacheBlend reports 2.2–3.3x TTFT in reused RAG
workloads. That is approximate warm reuse, not cold execution.

For Qwen, a block's GDN output boundary additionally depends on its incoming
SSM state. Keying only by block tokens is invalid. Keying by the entire
preceding-state identity reduces the scheme to prefix caching. A reusable exact
block transfer operator would still require context-dependent hidden rows at
every layer, so it does not avoid the target work.

### A/B G1 — separate product experiment

After, not as part of, the cold goal:

1. extend the prefix entry format with all GDN boundary states;
2. cold-run and donate one 8K prompt;
3. run the identical prompt and 25/50/75% shared-prefix variants;
4. require token/logit/KV/GDN equality and report lookup, SSD transfer, state
   materialization, and suffix times;
5. run a cold-miss control and ensure it is not called a speedup.

Verdict: **exact and useful on warm true-prefix hits; categorically not a cold
2.5x candidate**.

## 10. Quality and state evaluation

Every approximate arm needs two distinct references:

1. **Policy-correctness reference:** a slow implementation of the same selected,
   sparse, or extrapolated policy. The optimized implementation must match it.
2. **Semantic reference:** native full-prompt Qwen. Differences here are the
   intentional quality cost and may not be hidden behind kernel tolerances.

### 10.1 State diagnostics

For 512/2K/8K and B=1/2/4, record:

- frontier logit KL/JS divergence, top-1 agreement, native-top-1 rank, top-5
  overlap, and margin-conditioned disagreement;
- per-layer K/V normalized RMSE and cosine on comparable positions; retained
  native attention mass for sparse caches;
- per-layer/head GDN SSM normalized Frobenius error, cosine, norm ratio, and
  conv-tail error;
- the first divergence during a **forced identical 128-token continuation**,
  with per-step logit and GDN-state drift;
- greedy 128-token generation, decode TPS, p50/p95 TBT, and any repair stall.

A matching first token does not pass a bad cache. The forced continuation is
the direct test of whether state is useful.

Batch invariance is mandatory: a row's policy, selected indices, frontier
logits, and generated text must not change merely because it ran at B=1, B=2,
or B=4, beyond the already-declared numerical tolerance.

### 10.2 Task corpus

Use a frozen calibration split and a disjoint acceptance split:

- RULER at the target lengths: single/multi-needle, variable tracking,
  aggregation, and common-word extraction;
- LongBench single-document QA, multi-document QA, summarization, few-shot,
  synthetic, and code-completion categories;
- held-out text and code next-token NLL/perplexity;
- adversarial block placement: required facts in every score/rank decile and
  near the beginning/middle/end;
- exact system/developer instruction following, tool-schema preservation,
  JSON validity, role-boundary integrity, and refusal/safety fixtures.

Recommended preregistered shipping gate, pending owner approval:

- zero system/tool/template corruption;
- no category loses more than 2.0 absolute points and macro average loses no
  more than 1.0 point, with confidence intervals reported;
- held-out NLL increases no more than 1%;
- no NaN/Inf, state-norm explosion, crash, cancellation leak, or memory-policy
  violation.

Frontier top-1 agreement is diagnostic, not a substitute for task evaluation.
Conversely, a few matching greedy samples do not excuse large state drift.

### 10.3 Timing and accounting record

Each row records:

- adjacent native control, power posture, binary SHA, model hash, and policy ID;
- submitted tokens, physically target-evaluated tokens, token-layer-equivalent
  work, selected-index hash, and keep/compression rate;
- selector/draft/compressor, target, correction, materialization, frontier, and
  first-128-decode times;
- prefill makespan from earliest original request submission until every row's
  state is materialized and first token is available;
- peak active/cache/draft memory and every failed or fallen-back row.

Run three post-warmup repetitions after an adjacent control reproduces within
the program's 8% validity bound. A candidate passes performance only if **both**
B=2 and B=4 8K meet their absolute bars and all rows finish.

## 11. Denominator and phase-shift traps

Reject all of the following:

- counting 8K submitted tokens as 8K target-computed tokens after retaining 2K,
  without labeling the result input-equivalent and reporting actual work;
- timing a precomputed selector output while excluding selector/compressor time;
- using the native target's own full pass as an off-clock token-importance
  oracle;
- returning frontier logits while cache correction, GDN replay, or MLX
  materialization happens during the first decode steps;
- measuring only TTFT when first-32/128 decode stalls or changes state;
- using a warm prefix/block hit in a benchmark labeled cold;
- constructing identical/shared-prefix B=4 rows when the locked rows are
  distinct;
- dividing by average row TTFT instead of burst makespan;
- dropping failed rows, fallback rows, or compressor failures from the
  numerator;
- comparing an 8K hybrid-MoE result with a paper's 128K/1M
  attention-dominated speedup;
- multiplying independent upper bounds as if selector, pruning, lower
  precision, and correction did not consume the same 0.4x budget;
- presenting auxiliary-model memory/load/compile work as free;
- calling full-depth frontier arithmetic "exact original logits" when its
  cache/state is approximate.

Same-original-request latency is a legitimate product metric if the input,
policy, quality, and all work are held fixed and disclosed. It is not the same
thing as executing the native model on every input token.

## 12. Experiment order

1. **E1 hybrid state river, array reference:** E=4/E=8 state completeness and
   forced-continuation quality. It needs no second model and has the clearest
   fixed-target arithmetic margin.
2. **A2/D1 four-layer selector:** 20/25/30% selected blocks, then
   landmark-512 + suffix-2048. Stop if selector plus target upper bound exceeds
   0.36x.
3. **A1 independent draft roof:** only fund integration if measured scoring is
   at most 0.10x at both B=2 and B=4 and memory remains admissible.
4. **B1 static layer pruning:** layer 3/7 boundaries; no dynamic revival.
5. **C1 prompt compression:** treat as an explicit product-quality mode and
   report input-equivalent and actual-target metrics separately.
6. **F1 lower precision:** remain stopped until a weighted primitive/full-state
   roof is below 0.30x.
7. **G1 recurrent prefix cache:** useful separate warm-workload project, never
   evidence for the cold goal.

The first implementation should optimize nothing. It should answer the
state/quality question with ordinary MLX operations. Custom Metal work is
funded only after one policy survives that gate.

## Sources

Repository:

- `research/qwen36-prefill/{GOAL.md,program.md,results.tsv}`
- `research/qwen36-prefill/notes/{001,009,019,022,026,037,038,049}-*.md`
- `libs/mlx-swift-lm/Libraries/MLXLLM/Models/{Qwen35,GatedDelta}.swift`
- `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/{RecurrentStateV2,PrefixCacheV2,PrefixReusePlan}.swift`

External:

- Liu et al., [Speculative Prefill](https://proceedings.mlr.press/v267/liu25g.html),
  ICML 2025.
- Fu et al., [LazyLLM](https://arxiv.org/abs/2407.14057), 2024.
- Jo et al., [FastKV](https://arxiv.org/abs/2502.01068), Findings of ACL 2026.
- Shi et al., [GemFilter](https://aclanthology.org/2026.findings-acl.677/),
  Findings of ACL 2026.
- Qiao et al., [SwiftKV](https://aclanthology.org/2025.emnlp-main.1306/),
  EMNLP 2025.
- Shen and Zou, [River-LLM](https://aclanthology.org/2026.acl-long.1746/),
  ACL 2026.
- Jiang et al.,
  [LongLLMLingua](https://aclanthology.org/2024.acl-long.91/), ACL 2024.
- Yao et al., [CacheBlend](https://arxiv.org/abs/2405.16444), EuroSys 2025.
- Agarwal et al., [Cache-Craft](https://arxiv.org/abs/2502.15734), SIGMOD 2025.
- Gim et al., [Prompt Cache](https://arxiv.org/abs/2311.04934), MLSys 2024.
- Mohtashami and Jaggi,
  [Landmark Attention](https://arxiv.org/abs/2305.16300), NeurIPS 2023.
- Jiang et al., [MInference](https://arxiv.org/abs/2407.02490), NeurIPS 2024.
- Tiwari et al., [QuantSpec](https://proceedings.mlr.press/v267/tiwari25b.html),
  ICML 2025.
- Li et al., [SnapKV](https://arxiv.org/abs/2404.14469), NeurIPS 2024.
