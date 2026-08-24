# 052 — Adaptive Qwen MoE routing under fixed weights

Status: **viable as a default-off quality/performance experiment; not a
standalone path to 2.5x**

Scope: Qwen 3.6 35B-A3B TEXT prefill through the production CBv2 trunk. <!-- pragma: allowlist secret -->
Checkpoint bytes are immutable. Routing policy may change only when explicitly
enabled and must earn acceptance through measured quality. No decision-grade
M3 Max run was available for this note, so all speedups below are analytical
bounds or predictions, not measurements.

Implementation artifact:

- `research/qwen36-prefill/patches/052-prefill-moe-topk.patch`
- default behavior is unchanged;
- `DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K=4` or `2` reduces routed experts only
  on the dedicated CBv2 TEXT prompt-forward path;
- `DARKBLOOM_QWEN35_PREFILL_MOE_FULL_LAYERS=0,3-5,39` keeps named layers on
  checkpoint top-8;
- ordinary decode, multi-token MTP verification, and the MTP head always use
  top-8;
- malformed or non-reducing settings fail closed to top-8;
- selected scores retain the incumbent renormalization, so omitted router mass
  is redistributed over the retained experts;
- model parameters and checkpoint sanitization are untouched.

## Verdict

Reducing routed experts is real work deletion, but it cannot produce 2.5x by
itself. The inherited wall model assigns about **39%** of prefill to routed
expert projections and about **61%** to everything that remains: GDN and
attention projections, recurrent scan, full attention, router, shared expert,
normalization, residuals, and LM head.

Even with impossible perfect scaling:

```text
top-8 -> top-4:  1 / (0.61 + 0.39 * 4/8) = 1.242x
top-8 -> top-2:  1 / (0.61 + 0.39 * 2/8) = 1.413x
delete routed:   1 /  0.61                = 1.639x
```

The current BM=32 expert-tile path makes the likely gains smaller. At the
serving pass geometry `N=2,048`, top-4 is approximately 60% rather than 50% of
the top-8 tile count, and top-2 is approximately 40% rather than 25%. That puts
the first end-to-end predictions near **1.18x** and **1.31x**, before preserving
any sensitive layers.

This policy is worth measuring because a 20–30% wall reduction is material and
because the exact-QMM search has hit a measured arithmetic roof. It is not a
reason to stop looking for a second, independent lever. A 2.5x candidate still
needs a roughly 2x–3x reduction in the non-routed 61%, depending on whether
top-2 or top-4 survives quality.

## 1. Work backwards from required KV and GDN state

For decoder layer `l`, the production order is: <!-- pragma: allowlist secret -->

```text
x_l
  -> norm -> attention or GDN -> writes layer-l KV/GDN state
  -> residual h_l
  -> norm -> layer-l MoE
  -> x_(l+1)
```

This ordering gives one useful local fact and one limiting global fact:

1. Changing layer `l`'s MoE does **not** change layer `l`'s own KV or GDN state;
   that state was computed immediately before the MoE.
2. It changes `x_(l+1)`, so it can change every later full-attention K/V row,
   every later GDN convolution/SSM state, and the final logits.

For this 40-layer schedule:

- full-attention K/V is committed at layers 3, 7, ..., 39;
- fp32 GDN state is committed at the other 30 layers;
- MoE runs after attention/GDN in every layer;
- only layer 39's MoE has no later state consumer.

Therefore there is no layer mask that both deletes substantial routed work and
preserves all incumbent state by construction:

- Approximate any layer 0–38 and at least one downstream required state may
  differ.
- Approximate only layer 39 and no future state changes, but first-token logits
  still change. Its routed-work ceiling is `0.39 / 40 = 0.975%` of the whole
  pass.
- Run layer 39 at top-8 to protect the direct logit path and the other 39 layers
  can still leave a different layer-39 K/V cache and different earlier GDN
  states.
- Run prefill approximately and decode at top-8 and decode is internally
  consistent, but **not restored**. Decode starts from approximate prompt
  K/V/GDN state. “Top-8 decode” prevents additional policy drift; it does not
  undo prefill drift.

“Recurrent-sensitive layer” also needs a precise definition. The MoE in a GDN
layer is after that layer's state update. The MoE outputs that directly feed
the *next* GDN layer are the sensitive boundary:

```text
full top-8 on every MoE whose output feeds a GDN layer: 29 layers
full top-8 on final layer 39:                              1 layer
remaining low-k layers feeding full attention:           10 layers
```

That conservative schedule leaves only 10/40 MoEs reduced and has little
headroom (§2). Layer sensitivity must therefore be measured, not inferred from
the current layer's `isLinear` flag.

### Required continuation test

A quality harness must separate two effects:

1. changed prompt state;
2. divergence caused by feeding each model its own sampled tokens.

After candidate prefill, force the same fixed 64-token suffix through baseline
and candidate with `T=1`, top-8 decode. At every step record logit KL/top-1,
then report full-attention K/V and GDN conv/SSM relative error at the end. A
second free-running greedy continuation measures user-visible divergence.
Without the forced-token arm, “top-8 decode” cannot show whether state quality
was preserved.

## 2. Amdahl and tile-fill bounds

Let:

```text
S = 0.39                         routed-expert wall share
D = 0.61                         non-routed wall share
n = number of 40 layers using reduced k
r = ((40 - n) + n * k/8) / 40   ideal routed-work factor
T/T0 = D + S*r
```

The ideal schedule bounds are:

| Reduced layers | Protected layers | k | Ideal total speedup | Non-routed speedup still needed for 2.5x |
|---:|---|---:|---:|---:|
| 40 | none | 4 | 1.242x | 2.98x |
| 40 | none | 2 | 1.413x | 2.02x |
| 39 | final layer 39 | 4 | 1.235x | 3.05x |
| 39 | final layer 39 | 2 | 1.399x | 2.07x |
| 30 | all 10 full-attention-labelled blocks | 4 | 1.171x | 3.90x |
| 30 | all 10 full-attention-labelled blocks | 2 | 1.281x | 2.66x |
| 10 | 29 next-GDN feeders + final layer | 4 | 1.051x | 10.38x |
| 10 | 29 next-GDN feeders + final layer | 2 | 1.079x | 7.34x |

The last column solves:

```text
0.39*r + 0.61*dense_factor <= 0.40
```

It is already optimistic because it assumes routed time is exactly linear in
assignment count.

### BM=32 means k/8 is not the current-kernel cost ratio

For a pass with `N` tokens, the mean assignments per expert are:

```text
mean rows/expert = N*k/256
```

The expert-tile route issues BM=32 descriptors. Using the inherited
`mean_tiles ~= mean_rows/32 + 0.5` approximation when there is more than one
tile, the current-kernel ratios are:

| N | k | Mean rows/expert | Expected active experts | Approx. tiles | Relative to top-8 |
|---:|---:|---:|---:|---:|---:|
| 512 | 8 | 16 | 256.0 | 256 | 1.000 |
| 512 | 4 | 8 | 255.9 | 256 | ~1.000 |
| 512 | 2 | 4 | 251.3 | 251 | ~0.982 |
| 2,048 | 8 | 64 | 256.0 | 640 | 1.000 |
| 2,048 | 4 | 32 | 256.0 | 384 | 0.600 |
| 2,048 | 2 | 16 | 256.0 | 256 | 0.400 |
| 8,192 | 8 | 256 | 256.0 | 2,176 | 1.000 |
| 8,192 | 4 | 128 | 256.0 | 1,152 | 0.529 |
| 8,192 | 2 | 64 | 256.0 | 640 | 0.294 |

At `N=512`, lower k still touches almost every expert and still launches about
one padded tile per expert. It may barely accelerate routed QMM. The current
CBv2 target commonly presents `N=2,048` to the MoE (`[1,2048]` or packed
`[4,512]`), so the realistic first-pass whole-model estimates are:

```text
top-4: 1 / (0.61 + 0.39 * 0.60) = 1.185x
top-2: 1 / (0.61 + 0.39 * 0.40) = 1.305x
```

Lower k does not materially reduce checkpoint bytes streamed at these lengths:
nearly all 256 experts remain active. It reduces assignment tiles and
assignment-shaped activation traffic.

## 3. Candidate policy assessment

### 3.1 Fixed top-4/top-2 by layer — implement first

This is the smallest causal experiment:

- reuse the trained router;
- keep the highest 4 or 2 expert IDs;
- renormalize retained probabilities exactly as the existing block does;
- leave the shared expert unchanged;
- select protected layers statically;
- use top-8 for every non-prefill call, including MTP verification.

It drives the current `SwitchGLU` with fewer assignment rows, so it tests real
end-to-end work deletion without a new kernel or weight format. It is the
implemented patch.

First layer schedules:

1. `k4`, full layer `39`;
2. `k2`, full layer `39`;
3. best of those with additional full layers selected from measured
   layer-ablation sensitivity;
4. conservative next-GDN-feeder schedule only as a quality reference, because
   its speed ceiling is about 1.05–1.08x.

### 3.2 Top-k by token / full frontier tokens

Keeping the last token of each prompt chunk at top-8 can protect its direct
residual, but it does not repair its attention/GDN context. Earlier low-k
tokens already changed recurrent state and full-attention K/V.

The current `SwitchGLU` takes a rectangular `[..., k]` index tensor. A
top-8 frontier plus top-2/4 prefix therefore needs two routed calls and a
concatenation, or a ragged dispatch primitive. The separate one-token call
falls onto small-row expert dispatch and adds launches. Do not add this split
until the all-token fixed-k arm establishes a quality problem that frontier
top-8 plausibly fixes.

### 3.3 Thresholded experts and router-mass adaptive k

These are the strongest quality-per-unit-work policies in principle:

```text
k_i = smallest k in 1...8 with cumulative_top8_mass(i, k) >= tau
```

or keep experts satisfying:

```text
p_i,e >= absolute_threshold
p_i,e / p_i,top1 >= relative_threshold
```

with a minimum `k`. They preserve more experts on uncertain tokens and spend
less on concentrated routers.

They do **not** accelerate if represented as eight slots with zero weights.
`SwitchGLU` still computes every slot. A viable implementation needs a
GPU-resident ragged plan:

1. compute `k_i` and exclusive-scan assignment counts;
2. compact `(token, expert, score)` into `sum(k_i)` rows;
3. expert-sort those rows;
4. run gathered QMM;
5. reduce through token IDs rather than fixed top-k slots.

Calling `nonzero` and reading its size on the CPU would insert an evaluation
barrier into every one of 40 layers. A dedicated compact-plan primitive is the
right second implementation only if router histograms show a useful average k
and fixed-k quality says adaptation is needed.

Required histogram before coding:

- sorted top-8 normalized mass per layer/token;
- cumulative mass at k=1/2/3/4/6/8;
- chosen-k distribution for `tau = 0.80, 0.90, 0.95, 0.98`;
- chosen-k split by layer, prompt position, and corpus category;
- resulting BM=32 descriptors, not just average k.

### 3.4 Shared-expert compensation

The incumbent output is:

```text
sum(top8_score[e] * expert_e(x)) + sigmoid(shared_gate(x)) * shared_expert(x)
```

Two no-weight-change compensators are possible:

1. **retained renormalization** — the implemented baseline; retained expert
   weights sum to one;
2. **preserve top-8 mass + shared scale** — retain original top-8-normalized
   scores, compute omitted mass `m`, then multiply the shared branch by
   `1 + alpha*m`.

The second form needs an `alpha` sweep on a calibration split and a locked
evaluation split. There is no algebraic reason that the shared expert equals
the omitted routed mixture, so calling this “compensation” is a hypothesis,
not a guarantee. Do not tune `alpha` on the reported quality set. Start with
renormalization; add shared compensation only if it improves held-out logit KL
and task scores at unchanged k.

### 3.5 Approximate prefill, top-8 decode

This is the appropriate product boundary for the first experiment:

- prompt prefill can delete work;
- decode and MTP verification retain trained routing and unchanged decode
  throughput behavior;
- candidate identity is still approximate because prompt state differs.

The mode must eventually be model/capability-visible if shipped. An
operator-only environment variable is acceptable for a laboratory arm, not
for coordinator-invisible production semantics. <!-- pragma: allowlist secret -->

### 3.6 Expert output caching/reuse

An expert output is `down(silu(gate(x)) * up(x))`. The cache key is not
`(token_id, expert_id)`; contextual hidden state `x` changes by position,
request, and layer. Exact reuse requires bit-identical `x`, which ordinary
prefill does not provide. Approximate reuse requires activation quantization,
nearest-neighbor lookup, and an error policy, while cache lookup/traffic
competes with the QMM being removed.

The only robust exact reuse is whole-prefix state caching, which is outside the
uncached prefill metric. Do not implement expert-output caching without first
measuring repeated/near-repeated layer activations and a lookup-cost roof.

### 3.7 Token clustering

Current routing already clusters assignments exactly by expert before QMM.
Clustering tokens further means replacing several distinct activations with a
centroid or representative inside each expert, then broadcasting the expert
output. That changes a nonlinear function and needs roughly 2x compression to
matter. It also adds clustering work in all 40 layers.

A bounded probe could use deterministic activation hashes or product
quantization and report within-cluster output error, but this is less minimal
and less interpretable than router-mass adaptive k. Rank it behind ragged
adaptive routing.

## 4. Runtime experiment surface

The patch deliberately changes only Qwen's model layer:

```text
Qwen35TextModelInner
  -> parse default-off policy once at model construction
  -> pass policy + layer index into each Qwen35SparseMoeBlock
  -> CBv2RecurrentLanguageModelPrefillForwardable passes an explicit TEXT-prefill bit
  -> block chooses checkpoint k or reduced k from (layer, engine phase)
  -> existing softmax / argPartition / SwitchGLU / weighted sum
```

No new tensor format, kernel, checkpoint field, protocol message, or weight
rewrite is introduced.

Examples:

```bash
# Full top-8 baseline (identical default path)
env -u DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K \
    -u DARKBLOOM_QWEN35_PREFILL_MOE_FULL_LAYERS \
    darkbloom benchmark ...

# Top-4 prefill, protect direct final-logit layer
DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K=4 \
DARKBLOOM_QWEN35_PREFILL_MOE_FULL_LAYERS=39 \
    darkbloom benchmark ...

# Top-2 prefill, protect the final layer and any measured-sensitive ranges
DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K=2 \
DARKBLOOM_QWEN35_PREFILL_MOE_FULL_LAYERS=0-3,15,31-39 \
    darkbloom benchmark ...
```

Limitations of the experiment patch:

- only `cbv2RecurrentPrefill` with tokenizer-owned embeddings enables the
  policy. Legacy forwards, decode, MTP verification/capture, and multimodal
  embedding prefills remain top-8;
- policy metadata is not yet in benchmark JSON or provider telemetry;
  the wrapper must record both environment keys and binary hash;
- it implements fixed k only, not ragged token-adaptive k;
- it does not assert quality. The gate below decides whether the arm can live.

## 5. Pre-registered quality and performance harness

### 5.1 Process and provenance

Baseline and candidate must run in separate fresh processes because policy is
latched when the model is built. Record:

- parent and submodule SHAs plus binary SHA-256;
- model config/index/shard SHA-256 (must be identical);
- both routing environment values, including explicit “unset”;
- M3 Max identity, AC/High Power, thermals, OS/Swift/Xcode;
- resolved contiguous KV backend, prefix cache off, MTP off for TEXT target;
- peak active memory and any MLX error.

The baseline control must reproduce the locked matrix within 8% before a
candidate number is accepted.

### 5.2 Performance matrix

For each of baseline, k4-final39, and k2-final39:

- `B = 1, 2, 4`;
- prompt lengths `512, 2,048, 8,192`;
- three measured repetitions;
- existing `--scheduler-prefill` and `--arrival-invariance` paths;
- aggregate prefill tokens/s and makespan;
- B=1 TTFT;
- 64-token decode TPS at B=1/2/4;
- first-token and complete-output checksums as diagnostics;
- routed assignments, active experts, BM=32 descriptor count, and effective k
  per layer if instrumentation is enabled.

Continue a fixed-k arm only if:

- B=4×8K aggregate improves at least 15% for k4 or 25% for k2;
- no B=1/B=2/B=4 cell regresses by more than 5%;
- decode TPS stays within 3% (decode routing should be unchanged);
- no cancellation, timeout, memory, or uptime failure occurs.

These continuation bars are below the analytical ideals but above ordinary
run noise.

### 5.3 Logit/state gate

Use at least 10,000 fixed prompt frontiers stratified across 128–8,192 tokens.
Through the production CBv2 path, capture baseline and candidate frontier <!-- pragma: allowlist secret -->
logits in fp32 and report:

- top-1 agreement;
- top-5 set overlap;
- mean/p50/p95/p99 KL divergence;
- baseline logit margin on changed-top1 cases;
- results by prompt length and protected-layer schedule.

On a smaller state-instrumented subset, at every chunk boundary report:

- per-layer K/V relative L2 and max-absolute error;
- per-layer GDN conv-state and fp32 SSM-state relative L2/max error;
- forced 64-token continuation logit KL/top-1;
- free-running 64-token greedy exact-match length.

This gate is diagnostic, not a substitute for task quality.

### 5.4 Locked task-quality gate

Freeze dataset revisions, prompt templates, few-shot exemplars, answer
extractors, and baseline outputs before looking at candidate scores. Minimum
coverage:

- MMLU-Pro or MMLU: broad knowledge/reasoning;
- ARC-Challenge + HellaSwag: multiple-choice reasoning;
- GSM8K: arithmetic/reasoning;
- HumanEval or MBPP deterministic pass@1: code;
- IFEval: instruction following;
- LongBench retrieval/QA cells at 2K and 8K: prompt-state sensitivity;
- Darkbloom tool-schema and JSON-output fixtures: serving contract.

Use enough examples that one item is not a large acceptance swing. A candidate
passes only if:

- aggregate normalized score is inside a predeclared paired-bootstrap
  non-inferiority margin of **0.5 percentage points**;
- no category loses more than **1.0 point**;
- long-context retrieval and tool/JSON contract have zero additional hard
  failures;
- all candidate errors and changed outputs remain in the artifact.

If the corpus is too small to resolve those margins, enlarge it; do not call an
underpowered tie “quality preserved.” The calibration subset used for layer
masks, thresholds, or shared-expert `alpha` is disjoint from this locked gate.

### 5.5 Layer-mask search without overfitting

Use the calibration split only:

1. start with all 39 pre-final layers reduced;
2. restore one layer or four-layer band to top-8;
3. rank restoration by frontier-logit KL reduction per routed tile restored;
4. build a monotone Pareto curve of quality versus descriptor count;
5. select one schedule before running the locked task set.

This treats a full-top8 layer as a budgeted quality intervention. Searching
the task test set directly would turn a fixed-weight runtime policy into
test-set fitting.

## 6. Combination required for 2.5x

With ideal all-layer top-2, routed work contributes `0.39 * 0.25 = 0.0975`
of baseline time. The remaining 61% must run at:

```text
dense_factor <= (0.40 - 0.0975) / 0.61 = 0.496
```

or about **2.02x faster**. Protecting layer 39 raises that requirement to
about **2.07x**. With top-4, the non-routed side must improve about **3.0x**.
Current BM=32 tile fill makes those requirements stricter.

Therefore a plausible 2.5x stack needs:

1. top-2 or router-mass adaptive average k near 2 that passes quality;
2. a separate ~2x algorithmic reduction in dense/GDN/attention work, not a
   low-single-digit QMM retile;
3. small traffic deletions only after those two structural levers.

Examples of a second lever large enough in principle are an approximate
prefill policy for dense projections/activations, a materially different
sequence algorithm, or another form of token-work reduction. The already
measured 1.03–1.15x QMM/kernel changes cannot close the gap:

```text
1.31x realistic fixed top-2 * 1.15x kernel = 1.51x
```

Even optimistic ideal top-2 plus a 1.15x independent gain is only 1.63x.

## Recommendation

Apply the named patch on the M3 Max and run one controlled k4/k2
`full_layers=39` matrix. It is the minimum experiment that can falsify both
the performance and quality premise with the real fixed checkpoint.

Do not implement token-adaptive routing, shared compensation, expert caching,
or clustering until:

1. fixed-k demonstrates measured end-to-end gain;
2. router-mass histograms show adaptive k can lower BM=32 descriptor count;
3. fixed-k misses quality by an amount that adaptation can plausibly recover.

If top-2 passes quality, keep it as one component of a larger approximate
prefill program, with top-8 decode and a visible model capability. If it fails,
use the layer-ablation and router-mass data to decide between top-4 and ragged
adaptive k. In neither case should routing alone be described as the 2.5x
solution.
