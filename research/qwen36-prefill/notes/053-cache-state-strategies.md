# 053 — Cache/state compression is capacity, not the missing 2.5× prefill lane

Status: **source trace + arithmetic closure; no benchmark implemented**

Scope: Qwen 3.6 35B-A3B TEXT prefill on the locked M3 Max, fixed model
weights, ContinuousBatchingV2, contiguous KV, prefix cache off. Numerical drift
is allowed only through the frozen quality gates below.

## Verdict

Constructing or retaining final K/V and GDN state more compactly cannot be the
primary route from the locked B=4×8K baseline, 21.0375 s / 1,557.4 tok/s, to
8.4150 s / 3,893.5 tok/s.

For one 8K request, the committed artifacts are:

```text
10 layers of BF16 K/V       160.000 MiB
30 BF16 convolution tails     1.406 MiB
30 FP32 GDN SSM states        60.000 MiB
total committed state        221.406 MiB
```

B=4 therefore commits 885.625 MiB. Ideal one-byte FP8 K/V, BF16 SSM, and
one-byte convolution tails would reduce that by only 442.812 MiB across four
requests. A realizable affine INT8/g64 K/V representation with BF16 scale/bias
and BF16 SSM state would save 420 MiB when the convolution tail remains BF16.
These are useful capacity reductions, not seconds of prefill.

The measured roof points the same way:

- the incumbent delivers about 8.6–9.1 model TFLOP/s while moving an estimated
  61 GB/s, only about 15% of the M3 Max's 400 GB/s bandwidth;
- routed and dense projection arithmetic, not final-state storage, binds the
  pass;
- the complete B=4 final-state write is 15.2 ms even if pessimistically divided
  by 61 GB/s, versus 12.6225 s that must be removed;
- making all cache-specific K/V projections, all dense attention, every GDN
  recurrence, and every GDN convolution free gives only a 1.171×
  delivered-FLOP-share oracle;
- an even less defensible oracle that removes every full-attention block
  (Q/K/V/O plus attention) and every GDN scan/conv reaches only **1.307×**.

A 2.5× Amdahl result requires the accelerated bucket to own at least 60% of
wall time even if made free. Cache/state storage is nowhere close. Quantized
attention can affect part of the full-attention bucket, but deleting that
entire bucket still misses.

No cache/state benchmark was added. An isolated 2× copy or compression result
would be true but misleading: this source and byte ledger already fails the
continuation condition that could turn it into a 2× end-to-end mechanism. The
2.5× objective remains open through other work-deletion or arithmetic
mechanisms; this note closes only cache/state representation as the primary
multiplier.

## 1. Binding architecture and state products

The target has 40 decoder layers:

- full attention at model layers 3, 7, ..., 39: 10 layers;
- GDN at the other 30 layers;
- full attention uses 2 KV heads of dimension 256;
- GDN uses 16 key heads, 32 value heads, key/value dimension 128, and
  convolution width 4;
- model activations and convolution tails are BF16;
- GDN SSM state is FP32.

The top-down prefill product is exactly:

1. one K and V row for every prompt token at each of 10 full-attention layers;
2. one three-token convolution tail and one terminal SSM matrix at each of 30
   GDN layers;
3. frontier logits.

All earlier K/V and recurrent states are live. Later prompt chunks and strict
decode consume them. Compression may change their representation, but it
cannot omit them without changing the model or replaying work.

## 2. CBv2 attention-cache trace

### 2.1 Qwen owns only 10 compact attention rows

`Qwen35TextConfiguration.cbv2LayerKinds` drops every recurrent layer and returns
10 `.full` `CBv2LayerKind` entries carrying the original model-layer indices.
`Qwen35CBv2ConfigurationTests` pins the count and indices.

`Qwen35Attention.cbv2Forward` constructs:

```text
Q: [B, 16, L, 256]
K: [B,  2, L, 256] after K norm and RoPE
V: [B,  2, L, 256]
```

It passes those arrays to `CBv2AttendingLayerCache.updateAndAttend`. The cache
owns both commitment and attention; Qwen does not pass through the legacy
`QuantizedKVCacheProtocol` branch in `attentionWithCacheUpdate`.

### 2.2 Shipping target is contiguous BF16, not configurable INT8

The locked benchmark is contiguous. Qwen's CBv2 capability currently reports
`supportsPagedKV=false`; the provider backend factory degrades an ineligible
paged request to contiguous.

`CBv2ContiguousBackendConfig.kvDType` defaults to FP16, but it is an admission
estimate only. `CBv2FullSequenceKV` allocates from the first appended K/V
tensor's dtype. Qwen's K/V tensors are BF16, so changing only `kvDType` would
mis-account the row; it would not quantize it.

Each row owns two buffers shaped:

```text
[1, 2, capacity, 256]
```

The initial capacity is `min(maxLength, promptLength + 256)`. Allocation is
lazy until the first update. Full rows then append with slice assignment and
return prefix slices to attention.

The relevant MLX backend behavior is:

- ordinary `Slice` is a shared-buffer view;
- `SliceUpdate` first calls `copy_gpu(in, out, Vector)` for a contiguous full
  buffer, then writes the update;
- `copy_gpu` donates the input buffer when it has unique array/data ownership
  and the allocation fits the output, making the first phase a no-op;
- otherwise it copies the whole allocated cache before applying the slice.

Qwen full rows do not retain pre-write window views, and the engine evaluates
cache roots every step, so donation is the intended common path. This should be
confirmed in a Metal trace before any claim about exact copy traffic. It is not
valid to infer a full-cache copy from the presence of slice assignment alone.

The paged backend explicitly avoids this ambiguity with stable in-place slabs
and a write fence. It supports only FP16 pages (FP32 is a parity/test posture).
Its source says quantized pages would require:

- a packed cache template in the decode kernel;
- inline dequantization in `load_row`;
- scale/bias slabs;
- snapshot/interchange changes.

That work would still not make Qwen paged-capable without separately proving
recurrent request-state semantics.

### 2.3 The existing quantized cache is a legacy seam, not a CBv2 backend

`QuantizedKVCache` can store affine quantized K/V with default group size 64
and 8 bits. For D=256, group 64 is shape-compatible. It retains packed values,
scales, and biases and calls `quantizedScaledDotProductAttention`, which
implements QK and AV as quantized matrix multiplications around a composed
softmax.

That is useful implementation evidence, not a drop-in path:

- Qwen's CBv2 call reaches `CBv2LayerCache.updateAndAttend` directly;
- neither contiguous CBv2 row type is a `QuantizedKVCacheProtocol`;
- paged CBv2 is explicitly unquantized;
- product `kv_quant` was retired in v0.8.0 and is accepted only as an ignored
  legacy configuration key;
- current `QuantizedSDPATests` cover small D=64 numerical parity against a
  dequantized reference, not Qwen D=256 performance, long contexts, CBv2 row
  isolation, rollback, or model quality.

A real INT8 experiment therefore needs a new CBv2 storage/attention backend,
accounting, rollback, cancellation, decode, and state-handoff tests. Re-enabling
the old product knob would not test the proposed mechanism.

### 2.4 FP8 is not an MLX array dtype on this target

The public MLX `DType` includes `uint8`, `int8`, FP16, BF16, and FP32, but no
FP8 type. `mxfp8` is a `QuantizationMode`, not a dtype an ordinary cache slab
can adopt. On this macOS/M3 target, FP8 K/V therefore means a custom packed
`uint8` representation plus scale metadata and custom attention loads. It is
not `kvDType = .mxfp8`.

## 3. CBv2 recurrent-state trace

### 3.1 Exact shapes and accounting

`Qwen35TextConfiguration.cbv2RecurrentStateSpec` declares, per GDN layer:

```text
conv: [1, 3, 8192]       activation dtype = BF16
ssm:  [1, 32, 128, 128]  dtype            = FP32
```

Per request:

```text
conv = 3 * 8192 * 2 B                    =    48 KiB/layer
ssm  = 32 * 128 * 128 * 4 B              = 2.000 MiB/layer
30 layers                                = 61.40625 MiB/generation
```

`CBv2RecurrentStateSpec.fixedBytesPerRequest()` returns 64,389,120 bytes.
`peakBytesPerRequest()` charges three generations—committed plus two pending—
or 193,167,360 bytes (184.21875 MiB). `EngineV2` uses this peak in admission.

The distinction matters:

- one settled committed generation is 61.40625 MiB/request;
- a plain step can transiently retain committed input plus pending output;
- chained decode/MTP can reach the three-generation admission charge;
- the three-generation figure is residency protection, not bytes written on
  every prompt token.

### 3.2 FP32 state is a chunk-boundary load/store, not a per-token DRAM matrix

`Qwen35GatedDeltaNet.processChunk` gathers request states into a B-row tensor and
calls `gatedDeltaUpdate`. That function:

1. computes decay and beta in FP32;
2. initializes missing state as FP32;
3. converts any non-FP32 input state to FP32;
4. invokes `gatedDeltaKernel`.

The Metal kernel loads each state element once into a thread-local `float`,
loops serially over all T tokens, and writes one terminal state element after
the loop. The inner recurrence therefore stays FP32 even though q/k/v outputs
are BF16.

There are three materially different BF16 proposals:

1. **Terminal-only BF16.** Run the final prompt chunk in FP32, downcast the
   committed state once, and upcast for strict decode. This reduces idle
   residency but adds conversions and cannot accelerate prefill.
2. **Chunk-boundary BF16.** Store BF16 after every chunk and load it into local
   FP32 for the next chunk. This halves boundary state bytes but rounds 30
   recurrent states at every 512/1,024/2,048-token boundary. The inner T-loop
   and its arithmetic are unchanged.
3. **BF16 inner recurrence.** Change local arithmetic as well as storage. That
   is a different approximate recurrence, but even making the complete scan
   free removes only 0.1101 GFLOP/token, about 2% of modeled 8K work.

The incumbent's repeated q/k reads inside the kernel are a separate issue.
Changing terminal-state precision does not remove that traffic.

### 3.3 Convolution tails are already BF16

The convolution tail is only 1.40625 MiB across all 30 layers per request.
INT8 would ideally save 0.703125 MiB before scale metadata and would require a
dequantization step before concatenation with BF16 `qkv`. It cannot materially
move either memory pressure or time.

There is, however, a distinct hidden-residency issue.

`processChunk` forms:

```swift
let convInput = concatenated([convState, qkv], axis: 1)
let newConvState = convInput[0..., (convInput.dim(1) - 3)...]
```

MLX `Slice` is a shared-buffer view. Retaining this logical `[B,3,8192]` tail
therefore retains the full `[B,L+3,8192]` `convInput` backing allocation. The
ordinary CBv2 path further row-slices that view and stages it without
detaching. `nbytes` and recurrent admission count only the small logical
views; the underlying allocation is larger.

Across 30 layers, one generation's retained backing is approximately:

| Step shape | Full conv-input backing retained |
|---|---:|
| B=1, L=2,048 | 961.406 MiB |
| B=4, L=512 (current 2,048-token budget) | 965.625 MiB |
| B=4, L=2,048 | 3,845.625 MiB / 3.755 GiB |

Committed and pending generations can overlap, increasing the high-water mark.
The compact MTP full-accept path already detaches its tail with an explicit
small copy; ordinary `processChunk` does not.

Calling `contiguous()` on the final tail is the smallest candidate: MLX's
contiguous backend copies a view when its backing buffer exceeds the logical
output by more than 16 KiB, releasing the large chunk allocation after the
step. That could improve truthful residency and make wide-cohort experiments
safer. It does not delete the convolution, the concatenation, or the model
FLOPs, so it is not a 2× speed mechanism without independent evidence of
allocator or memory-pressure stalls.

## 4. Byte ledger

### 4.1 Final committed state at 8K

| Artifact | Current/request | Current B=4 | Candidate/request |
|---|---:|---:|---:|
| BF16 K/V | 160.000 MiB | 640.000 MiB | ideal FP8: 80.000 MiB |
| affine INT8/g64 K/V | — | — | 85.000 MiB |
| BF16 conv tails | 1.406 MiB | 5.625 MiB | ideal INT8: 0.703 MiB |
| FP32 SSM | 60.000 MiB | 240.000 MiB | BF16: 30.000 MiB |
| Current total | **221.406 MiB** | **885.625 MiB** | — |
| affine INT8 K/V + BF16 SSM/conv | — | — | **116.406 MiB** |
| ideal FP8 K/V + BF16 SSM + INT8 conv | — | — | **110.703 MiB** |

Affine INT8/g64 is 1.0625 bytes/element: one payload byte plus one BF16 scale
and one BF16 bias per 64 elements. It saves 105 MiB/request when SSM changes to
BF16 and the already-small convolution tail stays BF16.

The current combined B=4 admission envelope for final KV plus three recurrent
generations is about 1,376.875 MiB before contiguous allocation slack and other
engine state. That is meaningful for concurrency, but it is about 1.05% of
128 GiB and is not the current B=4 prefill denominator.

### 4.2 Traffic sanity checks

The following deliberately divides logical bytes by the low measured aggregate
traffic rate, 61 GB/s, rather than claiming the 400 GB/s device roof. It makes
the cache/state opportunity look larger:

| Traffic | Logical bytes | Time at 61 GB/s | Share of 21.0375 s |
|---|---:|---:|---:|
| B=4 final KV write | 640 MiB | 11.0 ms | 0.052% |
| B=4 all final cache/state writes | 885.625 MiB | 15.2 ms | 0.072% |
| B=4 SSM read+write over 16 current chunks | 7.5 GiB | 132.0 ms | 0.628% |

The 7.5 GiB line grants one read and one write of all 60 MiB/request SSM state
on every B=4×512 prompt step. Halving it saves at most 66 ms under this
deliberately pessimistic conversion, before counting BF16 conversion kernels.

Query blocking at 128 gives 64 blocks over an 8K row. If each block logically
reads every visible K/V element once, the triangular history factor is 32.5,
or 20.3125 GiB across B=4 and all 10 layers. Halving that idealized logical
input is about 179 ms at 61 GB/s. GPU-cache reuse, GQA implementation, score
traffic, and quantized dequantization all change the actual number, so this is
not a performance model. The stronger oracle below removes all attention and
still misses 2.5×.

## 5. Compute versus memory

At P=8,192, the existing model ledger is:

```text
all linear projections                    4.873421 GFLOP/token
GDN recurrence                            0.110100
GDN depthwise convolution                 0.001966
full-attention QK + AV                    0.671171
modeled total                             5.656658
```

K/V projections specifically are only 0.041943 GFLOP/token. Granting cache
strategies the impossible ability to erase:

- K/V projections;
- all full-attention QK/softmax/AV work;
- every GDN recurrence;
- every GDN convolution;

removes 0.825180 GFLOP/token, 14.59% of the ledger:

```text
oracle speedup = 1 / (1 - 0.14588) = 1.171×
```

Granting still more—every Q/K/V/O projection and every attention operation in
all 10 full-attention blocks, plus every GDN recurrence and convolution—removes
23.49%:

```text
oracle speedup = 1 / (1 - 0.23486) = 1.307×
```

These are delivered-FLOP-share oracles, not universal hardware proofs:
components can run at different efficiencies. The measured length curve agrees
with their direction. B=1 8K is 5.264 s versus 4 × 1.225 s for 2K stripes; the
entire extra long-history attention residual is about 0.364 s, 6.9% of the 8K
pass. Quantized K/V can improve only a subset of that residual.

The result is robust to allowing numerical drift. Lower precision can change
quality and halve storage, but there is no large cache/state arithmetic island
for M3 to accelerate. The failed MPP/half-precision probes matter only as
supporting context; this conclusion does not depend on treating their measured
13.4 TFLOP/s as a universal hardware roof.

## 6. Candidate-by-candidate disposition

### FP8 or INT8 K/V

**Potential benefit:** roughly 75–80 MiB/request for affine INT8 or ideal FP8,
plus lower K/V operand traffic in attention and more concurrent context
capacity.

**Costs and missing seams:** quantization per appended chunk, scales/biases,
custom CBv2 storage, custom D=256 attention, current-chunk handling, rollback,
decode, accounting, and quality drift. FP8 additionally lacks an array dtype on
this target.

**Disposition:** useful capacity/decode research; cannot independently unlock
2.5× prefill. Do not resurrect `kv_quant` as if it exercised this path.

### BF16 versus FP32 GDN state

**Potential benefit:** 30 MiB/request settled residency and half of
chunk-boundary state traffic.

**Costs:** every-chunk rounding or terminal conversion; the current entry point
immediately upcasts non-FP32 state; inner recurrence remains FP32 unless the
model itself changes.

**Disposition:** quality/capacity experiment only. Even free recurrence is
about a 1.02× modeled whole-pass upper.

### Quantized convolution tails

**Potential benefit:** less than 0.71 MiB/request before metadata.

**Cost:** scales and dequantization before a BF16 concatenation.

**Disposition:** reject for speed. Investigate detaching the existing BF16 view
instead, because backing-buffer retention is the real memory issue.

### Cache projection fusion

K/V must be normalized/rotated before commitment. A fused packed writer would
need either:

- both BF16 current-chunk K/V for immediate attention and packed history for
  persistence; or
- packed current K/V followed by immediate dequantization.

It also requires a custom affine-W4 projection because ordinary MLX matmul owns
its output allocation. K/V projection work is under 0.75% of modeled 8K work.

**Disposition:** no 2× mechanism. Fuse only as part of an independently
qualified attention backend.

### Direct packed K/V writes

The contiguous path already uses transpose/slice views and donation-capable
slice updates. A custom direct writer can remove a BF16 cache copy only if a
trace first proves donation is failing. Paged storage already uses direct
in-place writes but is FP16-only and Qwen-ineligible.

**Disposition:** trace-gated micro-optimization, not a primary experiment.

### Deferred or lazy cache/state materialization

Both systems are already lazy in allocation/graph construction, but every
prompt step evaluates their roots before transactional commit. Earlier K/V and
GDN state are inputs to the next chunk; deferring them until the end is not
valid for multi-chunk prefill.

For a one-shot chunk, terminal state can remain local until the end, which the
GDN kernel already does. K/V still has to serve same-layer attention and then
decode. Skipping final materialization is valid only for a request that never
generates, not this benchmark.

The actionable lazy-materialization issue is the opposite: the tiny conv-tail
view keeps a large backing allocation alive and should be detached if memory
measurement confirms the source-level analysis.

### Checkpoint and recompute

There is no training backward pass or activation tape to trade away.
Reconstructing dropped K/V requires retaining layer inputs or rerunning strict
K/V projection before deeper layers consume the cache. Reconstructing a
dropped terminal GDN state requires retained q/k/v/a/b inputs or replaying the
recurrence from an anchor. Recomputing the trunk adds the dominant projection
work and moves away from 2.5×.

Checkpoint/recompute becomes rational only if it is the sole way to fit a
wider cohort that already has an independently measured speed mechanism.
Compact state saves roughly 0.4 GiB at B=4; the conv-tail backing issue is a
larger and cheaper capacity target.

## 7. Experiments if this line is reopened

### C0 — Measure the real bucket before implementing formats

Add signposts/counters around:

1. K/V projection, norm, and RoPE;
2. contiguous `SliceUpdate` and any fallback full-buffer copies;
3. attention QK/softmax/AV;
4. GDN state gather, kernel, split, and commit;
5. conv-tail backing residency after finalize.

Run adjacent B=1/2/4 at 512/2K/8K, current chunk geometry, with GPU-complete
timing and peak/active memory. Record actual copy-kernel bytes, not `nbytes` of
views.

Continuation rule for a standalone 2.5× claim:

```text
measured inclusive cache/state bucket >= 60% of baseline wall
```

If it is smaller, substitute the measured bucket and candidate primitive speed
into Amdahl's equation before writing integration code.

### C1 — Representative quantized-KV primitive

Only after C0, compare BF16 contiguous with affine INT8/g64 and a custom packed
FP8 candidate over the real geometry:

```text
Hq=16, Hkv=2, D=256
B in {1,2,4}
chunk in {1,128,512,2048}
history in {0,2048,8192}
10 logical layers
```

Inclusive timing must contain:

- K/V quantization and scale generation;
- cache append/growth;
- query-blocked QK, precise softmax, and AV;
- one-token strict-decode handoff;
- GPU completion, not submission.

Report packed bytes, scale bytes, saturation, dequantized error, attention
error, and all fallback counts. A 2× cache-copy result does not pass if
inclusive attention is flat or the measured full-model bucket is too small.

### C2 — GDN boundary-state precision

Use real captured q/k/v/a/b tensors and compare:

1. FP32 state input/output control;
2. BF16 `StT` boundary load/store with local FP32 recurrence;
3. terminal-only FP32→BF16 conversion;
4. INT8 only if BF16 both passes quality and has a measured bandwidth win.

Shapes:

```text
B in {1,2,4}
T in {1,512,1024,2048}
state [B,32,128,128]
30 dispatches/pass
```

Include state conversion, not just the loop. Continue toward serving only if
the measured scan wall share and inclusive speed produce a full-model
projection above the required bar.

### C3 — Detach the convolution tail

Compare the current shared-buffer slice with:

```swift
convInput[0..., tailRange, 0...].contiguous()
```

Measure logical bytes, allocator active/peak bytes, buffer lifetime, and
B=1/B=4 full-model time at current and `[4,2048]` geometry. The expected result
is about 0.94 GiB less retained backing at the current 2,048-token step width
and 3.75 GiB less for `[4,2048]`, with no material speed change.

Treat a memory/accounting fix as worthwhile on its own merits, but do not call
it a prefill multiplier unless adjacent full-model timing proves one.

### C4 — Full integration

Integration is funded only if measured component times predict the binding
B=4×8K target without assigning negative time to the rest of the model.
Then run:

- B=1/2/4 × 512/2K/8K, three post-warmup repetitions;
- chunks 512/1,024/2,048 to expose recurrent-boundary sensitivity;
- strict decode after candidate prefill at 512/8K/32K;
- cancellation, MTP commit/rollback, and repeated 8K uptime;
- truthful admission and physical peak-memory checks.

## 8. Frozen quality and safety gates

Compression changes the model's effective state. It needs a named candidate
profile and cannot ship as an invisible storage optimization.

### Q0 — Structural and operational validity

Automatic reject on any:

- changed model weight byte/hash;
- missing K/V position, wrong offset, row cross-talk, or stale page/buffer;
- recurrent shape/lifecycle violation, failed commit/rollback, or cancellation
  leak;
- NaN/Inf, scale overflow, saturation outside the preregistered policy, Metal
  fault, allocator failure, or unreported fallback;
- admission bytes below physical live bytes, including shared-buffer backing;
- candidate-prefill to strict-decode handoff failure.

Run B=1/2/4 with chunks 512/1,024/2,048. Different chunk counts deliberately
change the number of BF16/INT8 recurrent roundings, so chunk sensitivity is a
binding quality dimension rather than a checksum nuisance.

### Q1 — Paired state, logits, and continuation

Use 128 held-out documents at 512/2K/8K. Sample logits every 128 positions and
at the frontier; compute comparison distributions in FP32.

Pass all:

- mean `KL(baseline || candidate) <= 0.010` nat;
- p99 KL `<= 0.100` nat;
- no length-bucket mean above `0.015` nat;
- 256 teacher-forced strict-decode tokens after mixed prefill with mean
  continuation NLL delta `<= 0.005` nat/token and paired-bootstrap 95% upper
  bound `<= 0.005`.

Report, by layer and length:

- K/V relative L2, max error, cosine, scale range, and saturation;
- attention-output relative L2/max error;
- conv-tail and SSM relative L2/max error and cosine at every chunk boundary;
- router top-8 flips, frontier top-1 agreement, and greedy-token differences.

Those diagnostics explain failures; they do not replace the distributional
gates.

### Q2 — Perplexity non-inferiority

On fixed WikiText-103 test and a fixed 2M-token C4 validation slice:

- candidate-minus-baseline mean NLL `<= 0.005` nat/token per corpus;
- paired document-bootstrap 95% upper bound `<= 0.005`;
- no 2K/8K bucket above `0.0075`.

Freeze the precision/scale policy before opening the holdout.

### Q3 — Tasks, long state, and open generation

Use the frozen MMLU-Pro, GPQA Diamond, GSM8K, IFEval, HumanEval, and LongBench
manifest from note 051:

- no more than 1.0 percentage-point loss on MMLU-Pro, GPQA, GSM8K, or IFEval;
- no more than 2.5 points on HumanEval pass@1;
- no more than 1.0 LongBench point;
- macro paired 95% lower bound no worse than -0.5 point.

Also run fixed key/value retrieval at 2K/8K/32K under at least two chunkings,
with exact-match loss no worse than 1.0 point per length. This is the specific
gate most likely to expose accumulated recurrent-state or KV quantization
drift.

On the frozen 500-prompt instruction/reasoning/code set, blind-judge baseline
and candidate with the fixed judge/version and rubric. Require the 95% lower
confidence bound of `win + 0.5 × tie` to be at least `0.45`; report length,
refusal, malformed-tool, repetition, and truncation rates, with no severe rate
increasing by more than 1.0 point. Manually inspect every candidate-only severe
failure.

### Q4 — Performance acceptance

- primary B=4×8K aggregate `>= 3,893.5 tok/s` / makespan `<= 8.4150 s`;
- every B=1/2/4 × 512/2K/8K disclosure cell at least 0.98× its locked baseline;
- no hidden decode-throughput or uptime regression;
- same machine, binary family, power posture, model, and harness;
- adjacent control reproduces baseline within 8%;
- all raw repetitions and semantic fallback counts retained.

## 9. Sources checked

- `research/qwen36-prefill/{GOAL.md,program.md}`
- `research/qwen36-prefill/notes/{001,009,011,026,030,037,038,051,055,056}-*.md`
- `libs/mlx-swift-lm/Libraries/MLXLLM/Models/{Qwen35,GatedDelta}.swift`
- `libs/mlx-swift-lm/Libraries/MLXLMCommon/KVCache.swift`
- `libs/mlx-swift-lm/Libraries/MLXLMCommon/AttentionUtils.swift`
- `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/`
  `{RecurrentStateV2,LayerCacheV2,AttentionV1}.swift`
- `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/SequenceKV/`
  `{ContiguousKVBackend,FullSequenceKV,WindowedSequenceKV}.swift`
- `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Paged/PagedKVPool.swift`
- `libs/mlx-swift-lm/Tests/MLXLMTests/`
  `{Qwen35CBv2ConfigurationTests,QuantizedSDPATests}.swift`
- `libs/mlx-swift/Source/MLX/{DType,Ops}.swift`
- `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/`
  `{common/slicing.cpp,common/copy.h,gpu/primitives.cpp,metal/indexing.cpp}`
- `libs/mlx-swift/Source/Cmlx/mlx/mlx/{array.cpp,array.h}`
- `provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+*.swift`
- `provider-swift/Sources/ProviderCore/Inference/`
  `{EngineV2KVSizing,EngineV2SlotFactory}.swift`

## Conclusion

State compression is useful for context capacity and may reduce decode traffic.
It does not remove the projection arithmetic that dominates Qwen prefill on
this M3. INT8/FP8 KV, BF16 SSM, quantized conv tails, direct packed writes,
lazy materialization, and recomputation all fail the 60%-of-wall continuation
condition before implementation.

The one concrete source-level follow-up is conv-tail detachment: a 48 KiB
logical tail currently retains a chunk-sized backing allocation at each GDN
layer. Measure and fix that as residency hygiene if confirmed end to end, then
continue the 2.5× search in work deletion or a genuinely faster dominant
arithmetic path.
