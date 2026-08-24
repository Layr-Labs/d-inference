# 051 — Fixed-weight mixed/lower-precision Qwen 3.6 prefill plan

Status: **design complete; standalone relaxed-float MPP roof implemented; no
serving change and no speedup claim**

## Decision

The strict BF16-input/FP32-accumulate line is closed for the 2.5× M3 target,
but the fixed-weight problem is not. The next program should optimize a named
**prefill-only execution profile**, not preserve the incumbent checksum:

1. keep the checkpoint's W4/g64 codes, scales, biases, router-8 bytes, and
   model architecture fixed;
2. spend FP32 only where an error is discontinuous, recurrent, or directly
   observable: router decisions, GDN recurrence/state, precise normalization
   and softmax, attention K/V commitment, and the final frontier;
3. use a faster approximate contraction for the bulk linears, selected per
   operation and layer;
4. accept or reject the resulting model by a frozen, paired quality gate;
5. require the real B=4×8K CBv2 median to reach 2.5×. A microkernel result is
   only a continuation gate.

“Exact checksums are no longer required” applies to activations, logits, and
generated tokens. It does **not** authorize changing the model weight bytes,
silently changing the served profile, corrupting request-owned state, or
relaxing crash/memory/accounting requirements.

## What E5/E11/E14–E16 actually establish

| Evidence | Observation | Consequence under the quality policy |
|---|---|---|
| E5 (`033`) | Whole-K half accumulation failed 30 deterministic QMM cases; Qwen gate/up error reached 1,152 and down reached 96. The random fixture passed. | Unscaled half accumulation across K=512/2,048 is unsafe, but E5 is not a real-model quality result. Reopen only as blockwise half partials with FP32 outer accumulation or power-of-two scaling. |
| E11 (`041`) | Native `bfloat × uint4b_format → float` executes on M3. Affine factoring moved the per-weight BF16 rounding boundary and differed by 1.65234375 on a two-term adversary. | Native uint4 is available. The uncorrected factorization is approximate, not malformed; it now needs inclusive throughput plus real-model quality. Exact or selective residual correction is also possible. |
| E14 (`044`) | Strict static-K16 MPP covers 99.9966% of the M=2,048 linear ledger at 12.6478 weighted TFLOP/s, only 1.1456× Steel. | Supported MPP load/store is usable, but strict BF16→FP32 cannot fund 2.5×. |
| E15 (`045`) | At B=4 threshold geometry, strict MPP is 12.0193 TFLOP/s; dynamic K8 is 3.1579 and fails a long-K mixed-exponent fixture. | Dynamic slicing plus explicit FP32 adds is both too slow and numerically unattractive. |
| E16 (`046`) | Thirty-five executable strict candidates across 60 tile/scope/input combinations are bit-identical; the bounded maximum is 13.4182 TFLOP/s. | More strict tile tuning is low value. The missing lane requires changed precision or changed work, not another nearby strict descriptor. |

Two inferences are specifically invalid:

- E5 does not prove that every bounded half-partial scheme has bad model
  quality.
- E11 does not prove that affine factoring has bad perplexity or task quality.
  It proves only that it is not the incumbent finite-precision operation.

## Start at the committed state, then work backward

A fast prompt is useless if decode starts from incoherent attention or
recurrent state. The candidate's primary correctness object is therefore the
post-prefill state, not an interior GEMM.

### Required state contract

After any B=1/2/4 prefill, cancellation, or MTP rollback:

- the ten full-attention layers have one K and V entry for every accepted
  prompt token, with unchanged offsets, row ownership, shape, and BF16 storage;
- every one of the thirty GDN layers has a BF16 convolution tail and an FP32
  SSM tensor of shape `[1,32,128,128]` per request;
- the committed state is generated from the same declared candidate
  activations used for that request—never stale baseline state or another
  row's state;
- the frontier logits are evaluated from that committed candidate state;
- strict decode can consume the state without conversion, replay, NaN/Inf, or
  a one-token discontinuity;
- prefix replay and MTP partial acceptance rebuild the same *candidate*
  boundary as ordinary candidate prefill.

“Valid” means internally coherent for the named mixed-precision model. It does
not mean byte-equal to the strict baseline. Quality decides whether that
coherent model is acceptable.

### State-first precision policy

| Subgraph | Initial policy | Reason |
|---|---|---|
| Router projection, softmax, top-8 IDs/order, selected-score normalization | Current strict path / FP32 reduction | A small logit perturbation can switch an expert discontinuously. Routers are only 0.0419 GFLOP/token, 0.86% of linear work. |
| GDN `a`, `b`, decay math, q/k normalization, recurrence, SSM commit | FP32 arithmetic and FP32 SSM; BF16 conv tail | Errors recur across all later prompt tokens and decode. The recurrence is only about 2% of modeled work. |
| Full-attention K/V projection and cache write | Start strict; BF16 cache | K/V is persistent state. K/V projection work is small enough to protect first. |
| Attention score reduction and softmax | Precise FP32 reduction | Probability normalization is sensitive and only ten layers use it. |
| RMSNorm statistics and residual/frontier reductions | FP32 reduction, existing BF16 storage | Prevent scale drift from amplifying lower-precision linears. |
| Routed/shared gate-up and down | Fast candidate | This is the main arithmetic target. |
| GDN large q/k/v/z and attention Q/O projections | Fast candidate, then restore by sensitivity | They are too large to protect unconditionally; state and frontier tests decide which layers return to strict. |
| Non-frontier hidden activations | BF16 first | Existing dynamic range, no conversion, and direct cache interfaces. |
| Final prompt row and final two decoder layers | Strict initial seed | Cheap protection of the immediately observed logits; calibration may restore more or remove one. |
| Decode (`M=1`) | Existing strict path | This program targets prefill and must not repeat the v0.8.8 decode regression. |

Protecting routers, attention K/V, and GDN `a/b` costs about 1.9% of linear
work. Protecting two complete decoder layers adds roughly another 5%. This is
small enough to test. Protecting all GDN projections is not: GDN projection
work is 2.0211 of 4.8734 GFLOP/token.

### Frontier correction

At each layer, the last prompt row can be treated more carefully than the
interior:

1. evaluate the non-frontier rectangle with the selected fast path;
2. commit strict K/V for full-attention layers;
3. retain the FP32 GDN state immediately before the final row;
4. evaluate the final row's normalization, router, selected experts, GDN
   update or attention query, residual, and projection with the strict path;
5. replace the frontier row and commit the corrected final state before the
   next layer.

This is not baseline recovery—the prefix activations are still approximate.
It is a coherent hybrid model whose observable frontier and state transition
are protected.

### What recomputation can and cannot fix

A final-state patch cannot reconstruct information discarded earlier. Any
state correction must replay the state-generating inputs from a known anchor:

- **GDN recurrence correction:** retain q/k/v/a/b for a chunk, replay the
  recurrence in FP32, then recompute the frontier from the corrected pre-final
  state. The current compact MTP replay machinery demonstrates this shape of
  solution.
- **Projection correction:** to remove low-precision q/k/v projection error,
  the strict projection itself must be rerun from the layer input. Replaying
  only the FP32 recurrence cannot remove projection error.
- **KV correction:** strict K/V must be computed before cache commit. Correcting
  K/V after deeper layers have consumed it requires replaying those deeper
  layers and is not a viable fast path.
- **Residual error feedback:** a strict sampled frontier or channel subset can
  estimate drift, but an estimated scalar correction is a new approximate
  model and must pass the same quality gate.

The initial profile therefore keeps GDN recurrence FP32 and attention K/V
strict. Recomputation is an ablation for frontier/state correction, not a
license to commit an inconsistent low-precision state.

## Candidate arithmetic

### A. Float MPP with `relaxed_precision=true` — first roof

Metal's descriptor says `relaxed_precision` applies to **float** operands and
permits mantissa truncation before multiplication. Setting it on BF16 operands
is not a meaningful “lower BF16” experiment. E6/E8 also cannot answer this:
they exercised BF16 plus an invalid MLX direct-register mapping.

The standalone probe in `probes/mpp-relaxed-float/` therefore compares:

```text
strict:  float × float → float, relaxed_precision=false
relaxed: float × float → float, relaxed_precision=true
```

Both buffers contain only values exactly representable in BF16, promoted to
float. Thus the candidate does not invent activation precision; it asks
whether M3 can execute the incumbent operand values through a faster relaxed
float contraction. It uses the fastest E16 wide-shape schedule,
M32×N32×K32 with four independent SIMD groups per threadgroup, and all nine
complete E15 projection shapes:

- dense M=8,192 and routed M=65,536;
- the real K/N dimensions and model dispatch counts;
- 99.9966% of the B=4×2,048 linear ledger;
- 16 GPU-complete samples after three warmups in balanced order;
- strict and relaxed output diagnostics, but no checksum veto;
- a hard NaN/Inf/no-op gate before timing.

Run on the M3:

```bash
cd research/qwen36-prefill/probes/mpp-relaxed-float
./run.sh /tmp/mpp-relaxed-float
```

This is deliberately an optimistic arithmetic roof. Its float input buffers
do not include inline W4 dequantization, expert gather, or BF16→float
cooperative loading. Continue only at **≥24 weighted useful GPU TFLOP/s**.
Then build the serving-shaped packed-W4 loader and require the inclusive rate
to remain above the exact end-to-end budget.

### B. Bounded half partials with FP32 outer accumulation

Do not rerun E5's whole-K accumulator. Test:

```text
for K block in {16,32,64,128}:
    p = half/BF16-output dot(A_block, W_block)
    C_fp32 += float(p)
```

Measure both native half and BF16 operands, and record whether MPP/Steel
actually rounds each partial or silently retains FP32 internally. Add a
power-of-two per-row or per-block scale only if the unscaled path overflows;
include scale reduction and rescaling in timing.

Ratchet:

- any NaN/Inf on activation-range traces: reject that block size;
- <24 weighted TFLOP/s: reject regardless of quality;
- ≥24: run layer-output KL/NLL calibration;
- whole-model quality failure: restore sensitive layers or reject, never raise
  the quality margin after seeing the result.

### C. Native uint4 affine factoring, with optional residual

For one affine group, E11 computes:

```text
sum x * BF16(s*q + b)
    ≈ s * dot(x,q) + b * sum(x)
```

The exact rounding residual is:

```text
r(q;s,b) = BF16(s*q+b) - (s*q+b)
exact = factored + sum x_i * r(q_i;s,b)
```

Because q has only 16 values, `r` is a 16-entry table per group/output
channel derived from the fixed checkpoint. Three variants should be timed:

1. uncorrected factorization;
2. factorization plus exact residual lookup/FMA;
3. selective residual correction on sensitivity-ranked layers/channels.

Derived packed/transposed views and residual tables may be cached, but original
weight bytes remain authoritative and their memory enters
`UnifiedMemoryCap`. The inclusive benchmark must count repacking/load time,
row-sum work, scale/bias work, residual work, and expert gather.

### D. Activation storage

| Format | M3 plan |
|---|---|
| BF16 | Default bulk storage. It has FP32-like exponent range and already matches model/cache interfaces. |
| FP16 | Test only inside a candidate contraction. E4 shows no 2× Steel lane (1.00–1.06×), so a whole-model FP16 conversion is unjustified without a distinct relaxed/half-MPP win. Audit saturation because FP16 tops out near 65,504. |
| FP8 | Not a current macOS 26.4 serving candidate. Native MPP FP8 is Metal 4.1/macOS 27, while this checkout's public MLX `DType` has no FP8 array type. Software E4M3 staging would add scales/conversion and has no demonstrated M3 arithmetic lane. Revisit only after a toolchain/OS gate and an inclusive >24 TFLOP/s primitive result. |

FP8 activations, if later tested, require dynamic block scales, saturation
counts, scale storage, and FP32 state writers. They must not be confused with
the checkpoint's product name: these model weights are affine W4/g64.

## Mixed per-layer selection

Do not hand-pick “first/last layers are sensitive” and stop. Build a precision
policy table keyed by `(layer, projection class)` and derive it on a calibration
split:

1. instrument baseline layer inputs/outputs, router margins, activation
   range, K/V, and GDN state;
2. switch one layer/projection class at a time to the candidate;
3. record wall-time saved, frontier logit KL, teacher-forced NLL delta,
   router top-8 changes, state drift, and saturation/non-finite counts;
4. rank by quality cost per millisecond saved;
5. start from all-fast and restore the worst entries until calibration gates
   pass;
6. freeze the table and evaluate once on the untouched holdout/task corpus.

Router margin is a useful diagnostic: low-margin rows predict expert flips.
It is not permission to use a different router. The first shippable profile
keeps every router strict.

## Arithmetic budget

For strict work fraction `f`, strict rate `R_s≈12` TFLOP/s (E15), and fast
rate `R_f`, the linear mixture is:

```text
R_mix = 1 / (f/R_s + (1-f)/R_f)
```

To sustain 24 effective TFLOP/s:

| Strict linear fraction | Required fast rate |
|---:|---:|
| 3% | 24.8 TFLOP/s |
| 5% | 25.3 |
| 10% | 27.0 |
| 15% | 29.1 |
| 20% | 32.0 |

This is why “FP32 only for sensitive work” is binding. A relaxed primitive at
24 TFLOP/s is not enough once 10% of linears remain strict; it is only the
minimum roof that earns an inclusive loader test. A profile protecting about
7% of linear work needs roughly 26 TFLOP/s fast contractions before nonlinear
tail costs.

## Frozen quality gate

Performance tuning uses a calibration split. Final acceptance uses an
untouched, versioned manifest with tokenizer revision, exact examples, prompt
format, seeds, and baseline/candidate outputs. Thresholds are fixed before
running a candidate.

### Q0 — Safety and state validity

Automatic reject on any:

- NaN/Inf, Metal fault, allocation overflow, timeout, request cross-talk, or
  state shape/dtype/offset mismatch;
- missing K/V entry, non-FP32 GDN SSM, failed MTP rollback/replay, or
  cancellation leak;
- candidate-prefill → strict-decode one-token handoff failure;
- weight-byte or architecture change;
- hidden precision profile or unreported fallback.

Run chunkings 512/1,024/2,048 at B=1/2/4 and compare candidate quality across
chunk boundaries. Exact state equality is diagnostic; finite, coherent state
and the continuation gates below are binding.

### Q1 — Paired logit and state handoff

Use 128 held-out documents at 512, 2,048, and 8,192 tokens. Sample logits every
128 positions plus the frontier, always computing baseline and candidate
softmax/KL in FP32.

Pass all:

- mean `KL(p_baseline || p_candidate) ≤ 0.010` nat;
- p99 KL `≤ 0.100` nat;
- no length bucket mean above `0.015` nat;
- after mixed prefill, run 256 teacher-forced strict-decode tokens and require
  mean continuation NLL delta `≤0.005` nat/token with paired-bootstrap 95%
  upper confidence bound also `≤0.005`.

Top-1 agreement, top-8 overlap, router flips, K/V relative error, and GDN-state
cosine/L2 drift are reported diagnostics, not checksum substitutes.

### Q2 — Perplexity/non-inferiority

Use fixed WikiText-103 test and a fixed 2M-token C4 validation slice. Compute
teacher-forced NLL with identical tokenization and chunk geometry.

For **each** corpus:

- candidate minus baseline mean NLL `≤0.005` nat/token (about 0.5% relative
  perplexity);
- paired document-bootstrap 95% upper bound `≤0.005`;
- no 2K/8K length bucket above `0.0075`.

No tuning or layer restoration is allowed after opening this holdout.

### Q3 — Task quality

Freeze exact revisions and prompts for MMLU-Pro, GPQA Diamond, GSM8K, IFEval,
HumanEval, and a retrieval/reasoning subset of LongBench. Use deterministic
decoding and paired bootstrap/McNemar analysis.

Non-inferiority margins:

- MMLU-Pro, GPQA, GSM8K, and IFEval: no more than **1.0 percentage point**
  absolute loss each;
- HumanEval pass@1: no more than **2.5 points**;
- LongBench normalized score: no more than **1.0 point**;
- macro-average across the six: paired 95% lower confidence bound no worse
  than **−0.5 point**.

For every task, both the observed candidate-minus-baseline difference and its
one-sided paired 95% lower confidence bound must clear that task's margin.
Every per-task margin is binding; a gain on one task cannot buy a large loss
on another.

### Q4 — Long-state and open generation

- 256 synthetic key/value retrieval prompts at 2K, 8K, and 32K under two
  chunkings; exact-match loss versus baseline `≤1.0 point` per length.
- 500 fixed instruction/reasoning/code prompts, baseline and candidate labels
  randomized, blind judged by a frozen judge/version and rubric. Define score
  as win + 0.5×tie; its 95% lower confidence bound must be `≥0.45`.
- Report length, refusal, malformed-tool, repetition, and truncation rates;
  candidate may not increase any severe-failure rate by more than 1 point.
- Manually inspect every candidate-only severe failure before acceptance.

The judge gate supplements NLL/tasks; it never replaces them.

## Performance experiment sequence

### P0 — Relaxed float MPP roof

Run the committed standalone probe. Continue only if:

- all nine complete shapes execute with no non-finite values;
- the strict control and relaxed arm each have 16 GPU-complete samples;
- weighted relaxed rate is ≥24 TFLOP/s;
- AC/High Power and no-provider process gates hold.

If it misses, do not build a W4 integration for this mechanism.

### P1 — Half-partial and native-uint4 roofs

Run each mechanism independently over the E15 ledger. Include conversion,
group scales/biases, row sums, correction, and gathered routed shapes. Keep
only variants ≥24 TFLOP/s, preferring ≥27 when the likely strict fraction is
near 10%.

### P2 — Layer sensitivity and state-first prototype

Add a prefill-only internal precision policy with:

- strict routers;
- FP32 GDN recurrence/state;
- strict attention K/V writers;
- strict final frontier;
- fast bulk projections;
- strict M=1 decode fallback.

Run Q0/Q1 calibration before task evaluation. Record actual route-hit counts,
fallback counts, peak memory, candidate/strict work fraction, and per-class GPU
time.

### P3 — Correction/recomputation ablations

Independently test:

1. strict final two versus four layers;
2. strict K/V versus relaxed K/V;
3. GDN full-FP32 recurrence replay and frontier correction;
4. native-uint4 residual correction off/exact/selective;
5. BF16 versus FP16 bulk activation storage;
6. sensitivity-selected strict GDN qkv layers.

Keep only quality needed by the frozen calibration margins. Do not compose
several unmeasured approximations and then try to identify the cause.

### P4 — End-to-end ratchet

For every surviving fixed profile, run adjacent baseline/candidate:

- B=1 at 512/2,048/8,192;
- B=2 and B=4 equal-length bursts at 512/2,048/8,192;
- at least three post-warmup repetitions, all raw rows retained;
- primary metric `sum(prompt tokens) / burst makespan`;
- decode B=1/2/4 after 512 and 8K contexts;
- cancellation, MTP partial acceptance, and repeated 8K uptime soak.

Claim success only when B=4×8K is ≥2.50×, B=2 and B=1 are disclosed, every
non-primary prefill/decode cell is at least 0.98× unless an explicit product
tradeoff is approved, and Q0–Q4 all pass.

## Shipping shape

The profile must be named (for example `qwen36-mixed-v1`), fail closed by
shape/toolchain/device, and be visible in diagnostics/telemetry. If exposed on
the wire, update Swift/Go protocol mirrors and privacy allowlists together.
Fallback is the current strict kernel, never a partially initialized state.

No current serving source changes in this note or probe. The next fact needed
is the M3 result from P0; everything after it remains conditional.

## Sources

- `notes/033-e5-half-accum-prereg.md`
- `notes/041-e9-native-uint4-verdict.md`
- `notes/044-e14-mpp-supported-throughput.md`
- `notes/045-e15-mpp-dynamic-k8-throughput.md`
- `notes/046-mpp-tile-scope-sweep.md`
- `notes/026-independent-roof-and-levers.md`
- `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift`
- `libs/mlx-swift/Source/MLX/DType.swift`
- Apple, [Metal Shading Language Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf),
  tables 7.3–7.4
- Apple, [Metal Performance Primitives Programming Guide](https://developer.apple.com/download/files/Metal-Performance-Primitives-Programming-Guide.pdf)
