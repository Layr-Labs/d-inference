# 050 — Reverse Qwen 3.6 prefill from the state that must survive

Status: **dependency trace complete; ceilings quantified; five experiments
pre-registered; default-off artifact-eight implementation preserved in patches
052–055; Mac performance and quality gates pending**

Scope: Qwen 3.6 35B-A3B **TEXT** prefill through ContinuousBatchingV2 on the
M3 Max. Checkpoint weight bytes are fixed. Execution precision, routing,
association, cache/state representation, scheduling, and approximate algorithms
may change only as named profiles that pass the frozen quality and safety gate.

## Verdict

Working backward from the actual product rules out a large class of apparent
shortcuts:

- Layers 0–38 must produce every token row. Those rows are consumed by the
  next layer and eventually determine later K/V, GDN state, and the frontier.
- Layer 39 is the sole exact hidden-output deletion boundary. After its complete
  K/V rectangle is committed, intermediate chunks need no layer-39 hidden
  output and the frontier chunk needs one row. The whole-model ceiling is only
  **1.023–1.032x**.
- A terminal-state-only GDN scan does not help the incumbent model: the last
  layer is full attention, and every GDN layer's per-token output feeds another
  layer. Making the complete recurrent scan free is only **1.022x**.
- Quantizing K/V or recurrent state primarily changes residency. Even making
  all full-attention arithmetic free is only **1.135x at 8K**.
- Q/K/V or cache-write fusion removes launches and temporary traffic, not the
  matrix products. Its impossible free-work ceiling is below **1.08x**.

The cold-prefill 2.5x target therefore requires one of three structural events:

1. **semantic token/layer work deletion** while still constructing coherent
   approximate K/V and GDN state;
2. an all-large-linear path roughly **2.73x faster at 2K and 3.29x faster at
   8K**, or about 2.68x at 8K if attention also becomes 2x faster;
3. reuse of more than **60% of a warm exact prefix** (or more than 80% shared
   work across a four-request cold cohort); 60%/80% are zero-overhead lower
   bounds, so a real implementation needs additional overlap.

The first has a direct arithmetic route but severe quality risk. The second
has a quality route but no demonstrated M3 execution lane: E17–E19 were
flat/slower. The third is exact and likely to exceed 2.5x on repeated-prefix
traffic, but it does **not** improve the fixed cold, prefix-cache-off primary
benchmark.

## 1. The concrete post-prefill product

The model schedule is:

```text
G G G A | G G G A | ... | G G G A
0 1 2 3                         36 37 38 39
```

There are 30 Gated DeltaNet layers and full attention at
`3,7,11,15,19,23,27,31,35,39`.

### 1.1 Ten full-attention K/V caches

For each accepted token and each full-attention layer:

```text
K: [2 KV heads, 256] BF16
V: [2 KV heads, 256] BF16
bytes = 2 tensors * 2 heads * 256 * 2 = 2,048 bytes/layer/token
```

Across ten layers that is exactly **20,480 bytes/token**:

| Prompt length | One request | B=4 |
|---:|---:|---:|
| 512 | 10 MiB | 40 MiB |
| 2,048 | 40 MiB | 160 MiB |
| 8,192 | 160 MiB | 640 MiB |

The stored keys are normalized and RoPE-transformed; values are projected and
stored in attention layout. Every token is needed by future prompt chunks and
decode. Cache representation may change, but missing semantic entries cannot.

### 1.2 Thirty GDN terminal states and convolution tails

For one recurrent layer and request:

```text
conv tail: [1, 3, 8192] BF16
           = 49,152 bytes
SSM state: [1, 32, 128, 128] FP32
           = 2,097,152 bytes
total      = 2,146,304 bytes
```

Across 30 layers:

```text
conv tails =  1.40625 MiB
SSM states = 60.00000 MiB
total      = 61.40625 MiB/request
```

This is fixed with prompt length. The engine may transiently retain three
generations for transactional decode/MTP, but ordinary committed prefill
semantics require one generation. Each layer's state is request-owned and is
committed or rolled back in step order.

### 1.3 Frontier logits

Only one normalized hidden row per request reaches the vocabulary projection:

```text
hidden frontier: [2048]
logits:          [248320]
```

Intermediate chunks return an evaluation handle and perform no LM-head
projection. The frontier chunk projects one row. Exact greedy selection needs
all vocabulary columns unless a fused projection/argmax changes the reduction
algorithm; there are no remaining discarded LM-head rows.

## 2. Exact layer-by-layer dependency trace

Let `x_l[t]` be the input row to layer `l`. Every layer has this shape:

```text
r_l      = Attention_l(norm(x_l))       # A layers, commits K_l/V_l
         = GDN_l(norm(x_l), S_l)        # G layers, commits terminal S_l/tail_l
h_l      = x_l + r_l
x_(l+1)  = h_l + MoE_l(norm(h_l))
```

The attention/GDN artifact is produced **before** that layer's MoE, but the MoE
output becomes every later layer's input.

### 2.1 Backward induction from logits

1. Frontier logits require `x_40[P-1]`.
2. `x_40[P-1]` requires layer 39's frontier attention output, residual, and MoE.
3. Layer 39's frontier attention requires its query at `P-1` and every
   layer-39 K/V row at positions `0...P-1`.
4. Every layer-39 K/V row is projected from the corresponding `x_39[t]`, so
   **all** layer-38 outputs are live.
5. Repeating the argument backward, every row from layers 0–38 is needed either
   as a later layer's K/V input, a later GDN update input, or the frontier path.

Causality does not make old rows dead inside the trunk. It only says row `t`
does not need future rows. The next layer still needs row `t`.

### 2.2 Backward induction from persistent state

For every GDN layer, transformed `q/k/v/a/b` for each token updates the FP32
matrix state in order. The terminal state alone can be written as a composed
chunk transform, but the same recurrence also emits `r_l[t]` for every token,
and those outputs feed layer `l+1`. Therefore:

- a state-only recurrence is exact only if its layer's hidden output is dead;
- no GDN layer has that property in this schedule;
- a chunkwise WY scan may compute the same outputs/state with more parallelism,
  but it cannot omit outputs without defining a different model.

For every full-attention layer before 39, K/V commitment is not enough because
the full attention output feeds the next layer. Layer 39 is the one exception.

### 2.3 The exact layer-39 specialization

For an intermediate chunk:

```text
x_39[all rows] -> K39/V39 projection, K norm/RoPE, cache commit
discard: Q/gate projection, attention, O projection, residual, MoE
```

For the frontier chunk:

```text
x_39[all rows] -> complete K39/V39 commit
x_39[last row] -> Q/gate, newest-query attention, O, residual, MoE, norm, logits
```

`CBv2LastQueryPrefillLayerCache` already expresses the cache operation for the
contiguous backend. The current Qwen loop does not invoke it. This rewrite is
model-exact in real arithmetic; changed matrix shapes/reduction order still
need the normal numerical and quality gate.

## 3. Strategy ledger

The inherited modeled work per token is:

| Term | GFLOP/token |
|---|---:|
| GDN projections, 30 layers | 2.0211 |
| Full-attention projections, 10 layers | 0.5453 |
| Routed experts, 40 layers | 2.0133 |
| Shared experts + gates | 0.2518 |
| Routers | 0.0419 |
| **All linear work** | **4.8734** |
| GDN recurrence | 0.1101 |
| Full attention, P=512 / 2K / 8K | 0.0420 / 0.1679 / 0.6712 |

Small elementwise, cache, sort, and evaluator work is omitted, so every
arithmetic ceiling below is optimistic.

| Strategy | Maximum modeled saving / speed | Main quality or product risk | Verdict |
|---|---|---|---|
| Final-layer K/V-only + last query | Deletes 2.23% / 2.42% / 3.10% at 512/2K/8K; **1.023–1.032x** | Different QMM geometry can move finite-precision logits | Exact supporting optimization, never 2.5x |
| Exact state-only GDN | Making all scan arithmetic free is **1.022x**; no hidden rows may be omitted | WY changes association; omitted outputs change the model | Profile first; supporting only |
| Approximate artifact-only layers | Eight full layers plus state/KV-only on 32 layers has an optimistic **2.59–2.74x** profile | Qwen was not trained for 32 identity hidden layers; all later state drifts | Direct cold-target path, highest quality risk |
| Low/mixed-precision prefill | Linears need 2.62x/2.73x/3.29x at 512/2K/8K if the tail is unchanged; 2x attention lowers 8K need to **2.68x** | Activation outliers, router flips, K/V and recurrent drift | Arithmetically sufficient; no M3 lane measured yet |
| Fixed top-4/top-2 MoE | Ideal **1.24x/1.41x** at 2K; BM=32 prediction about **1.18x/1.31x** | Omitted expert mass changes all later state | High-information component, not standalone |
| Quantized K/V | Free-attention bound **1.034x at 2K, 1.135x at 8K**; 2x attention is only about **1.06x at 8K** | K outliers, accumulated attention error, dequant cost | Residency/enabler, not direct target |
| Quantized GDN state | BF16 SSM halves 60 MiB/request; no projection work removed | Recurrent error compounds through prompt and decode | Memory experiment only; keep FP32 initially |
| Speculative state + correction | With a 4x draft, exact fraction must be **<=20%** for 2.5x before overhead | Exact correction after an early divergence requires downstream replay; sparse correction remains approximate | Possible, high algorithmic/quality risk |
| Chunk-parallel WY scan | Free-scan ceiling **<=1.022x** | New operation order and temporary memory | Implement only after a trace shows anomalous wall share |
| Exact warm prefix reuse | Zero-overhead `speed = 1/(1-s)`; **s=60%** is the 2.5x lower bound | Must snapshot all 10 K/V layers plus all 30 recurrent boundaries atomically | Strong exact product path, outside cold benchmark |
| Four-row shared-prefix compute-once | Zero-overhead `speed = 4/(4-3s)`; **s=80%** is the 2.5x lower bound | COW ownership, cancellation, and row isolation | Can target aggregate only on genuinely shared prompts |
| Arbitrary block reuse / CacheBlend | Published transformer results use selective KV recomputation; Qwen additionally needs ordered GDN repair | A block is context-dependent at every layer; recurrent correction couples its suffix | Approximate RAG profile, not exact generic reuse |
| Q/K/V and cache projection fusion | All QKV projections are 7.3% of modeled 2K work; impossible free-work upper **1.079x**. K/V-only projection work is <1% | Quantization metadata/layout must remain aligned | Low-single-digit support |

### 3.1 Artifact-only layer arithmetic

A skipped GDN layer can still construct a coherent candidate state by running:

```text
input norm
qkv + a + b projections
conv + q/k norm + FP32 recurrence
terminal conv/SSM commit
hidden output := input hidden
```

It omits `z`, recurrent output normalization, `out_proj`, residual, and MoE.
Modeled cost is **0.03749** instead of **0.12872 GFLOP/token/layer**.

A skipped full-attention layer can run K/V projections, K normalization/RoPE,
and cache commit while setting hidden output to its input. Modeled cost is
**0.00419** instead of `0.112–0.179 GFLOP/token/layer` depending on length.

Constructing artifacts for all 40 layers but no full hidden updates costs about
**1.1665 GFLOP/token**. Keeping layers `0-3,36-39` fully active (six GDN, two
attention) gives:

| Prompt | Full model | Artifact-eight profile | Optimistic ratio |
|---:|---:|---:|---:|
| 512 | 5.0255 | 1.9383 | **2.59x** |
| 2,048 | 5.1514 | 1.9635 | **2.62x** |
| 8,192 | 5.6547 | 2.0642 | **2.74x** |

This is the smallest direct proof that the requested output objects do not
force the incumbent FLOP count. It is not evidence that the resulting model
has usable quality.

### 3.2 Why cheap exact correction is unavailable

Suppose a draft changes `x_l[t]`. Then:

- that layer's projected K/V or q/k/v/a/b changes;
- its output changes later rows through attention or recurrence;
- its MoE changes `x_(l+1)[t]`;
- every deeper layer can change at `t` and all later causal positions.

Replaying only the terminal GDN recurrence can correct arithmetic given fixed
transformed inputs; it cannot recover strict transformed inputs. Correcting
one old K/V row after deeper layers consumed it requires replaying those deeper
layers. Consequently, "draft then correct the frontier" is a coherent
approximate model, not restoration of the baseline.

## 4. Binding performance and quality gates

The locked baselines are:

| B | 512 | 2,048 | 8,192 |
|---:|---:|---:|---:|
| 1 | 1,434.6 | 1,671.4 | 1,546.8 |
| 2 | 1,620.2 | 1,621.4 | 1,500.7 |
| 4 | 1,712.6 | 1,694.4 | **1,557.4** |

The primary B=4×8K gate is **3,893.5 tok/s** or **<=8.4150 s** makespan.

Every experiment uses fresh baseline/candidate processes, the exact model
snapshot and hashes, contiguous KV, prefix cache off unless reuse is the named
independent variable, MTP off for TEXT timing, AC power, High Power, and a
quiet GPU. The control must reproduce its cell within 8%.

Common M3 setup and matrix command:

```bash
set -euo pipefail
export ROOT=/Users/gaj/work/qwen36-prefill
export MODEL=qwen3.6-35b-a3b-vl-mtp-mxfp8
export CONFIG="$HOME/.darkbloom/provider.toml"
export OUT="/Users/gaj/qwen36-reverse-prefill/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
sudo pmset -a powermode 2
pmset -g batt | tee "$OUT/power-before.log"
pmset -g custom | tee -a "$OUT/power-before.log"
test -z "$(pgrep -x darkbloom || true)"

cd "$ROOT/provider-swift"
swift build -c release --product darkbloom
export BIN="$(swift build -c release --show-bin-path)/darkbloom"
shasum -a 256 "$BIN" | tee "$OUT/binary.sha256"

run_matrix() {
  arm="$1"; shift
  launch=("$@")
  "${launch[@]}" "$BIN" benchmark \
    --config "$CONFIG" --model "$MODEL" \
    --scheduler-prefill --prefill-lengths 512,2048,8192 \
    --prefill-iterations 3 --kv-backend contiguous \
    >"$OUT/${arm}-b1.json" 2>"$OUT/${arm}-b1.stderr"
  for b in 2 4; do
    for l in 512 2048 8192; do
      "${launch[@]}" "$BIN" benchmark \
        --config "$CONFIG" --model "$MODEL" \
        --arrival-invariance --arrival-batch-size "$b" \
        --arrival-prompt-tokens "$l" --arrival-decode-tokens 64 \
        --arrival-iterations 3 --kv-backend contiguous \
        >"$OUT/${arm}-b${b}-l${l}.json" \
        2>"$OUT/${arm}-b${b}-l${l}.stderr"
    done
  done
}
```

For numerical/model-policy changes, checksum inequality is diagnostic. Binding
quality is the frozen Q0–Q4 gate in note 051:

- no non-finite value, Metal fault, state shape/dtype/offset mismatch,
  cross-row contamination, cancellation leak, or weight-byte change;
- frontier mean KL `<=0.010`, p99 `<=0.100`, and no length-bucket mean
  `>0.015`;
- forced 256-token strict-decode continuation NLL delta and paired-bootstrap
  upper bound `<=0.005 nat/token`;
- WikiText/C4 NLL non-inferiority `<=0.005 nat/token`;
- task losses within the frozen per-task margins, with zero new LongBench
  retrieval or tool/JSON hard failures;
- decode B=1/2/4 after 512 and 8K contexts at least 0.98x baseline;
- ten-iteration B=2/B=4 8K cancellation/uptime soak with no fault signature.

Calibration used to pick layers, precision, thresholds, or correction tokens
is disjoint from the locked evaluation split.

## 5. Five ranked experiments

The ranking is by chance of contributing a real 2.5x result on this M3, not by
implementation convenience. Experiment 5 runs first because its seam already
exists.

### Rank 1 — E20: artifact-only depth ladder

**Hypothesis:** most hidden-layer work can be skipped during prefill while
still constructing internally coherent approximate cache/state. An eight-full-
layer profile has a direct 2.6–2.7x arithmetic path.

Implement one explicit CBv2-prefill phase with strict `T=1` decode fallback:

```text
32,24,16,12 full layers -> sensitivity/quality curve
8 full layers           -> target profile 0-3,36-39
skipped GDN              -> state-only path
skipped attention        -> K/V-only path
```

Proposed experiment command after that profile lands:

```bash
run_matrix e20-control \
  env -u DARKBLOOM_QWEN35_PREFILL_ARTIFACT_ONLY \
      -u DARKBLOOM_QWEN35_PREFILL_FULL_LAYERS
run_matrix e20-artifact8 \
  env DARKBLOOM_QWEN35_PREFILL_ARTIFACT_ONLY=1 \
      DARKBLOOM_QWEN35_PREFILL_FULL_LAYERS=0-3,36-39
```

Continuation gates:

- observed state-only/KV-only hit counts exactly match 32 skipped layers;
- every skipped GDN stages FP32 SSM + BF16 tail and every skipped attention
  layer commits the full K/V length;
- B=4×2K is at least 2.3x before funding the 8K matrix;
- B=4×8K is at least 2.5x;
- Q0/Q1 are run at every depth; only a profile passing all Q0–Q4 may ship.

Expected failure mode: catastrophic NLL/task loss. That is a useful hard
answer: the output objects permit the speedup, but the fixed trained function
does not tolerate the required depth.

### Rank 2 — E21: state-first W4A8/low-precision linears plus quantized attention

**Hypothesis:** preserve routers, normalization, GDN recurrence/SSM, K/V
commit boundaries, and the final two layers while using a fast activation-
quantized contraction for bulk projections. Combine it with quantized-cache
online attention so the 8K attention tail is about 2x faster.

The kernel roof runs before serving integration. It must include dynamic
activation scales, fixed affine-W4 dequantization, routed gather, conversion,
and output casting—not quote an unsupported TensorOp:

```bash
cd "$ROOT/research/qwen36-prefill/probes/w4a8-state-first"
./run.sh "$OUT/e21-kernel"
```

`w4a8-state-first/run.sh` is part of E21's implementation deliverable; it does
not exist in the current tree. Stop unless the real nine-shape weighted rate is
at least **27 useful TFLOP/s** with finite outputs and the M3 path is proven.

Proposed integrated command:

```bash
run_matrix e21-control env -u DARKBLOOM_QWEN35_PREFILL_PROFILE
run_matrix e21-candidate \
  env DARKBLOOM_QWEN35_PREFILL_PROFILE=state-first-w4a8-kv2-v1
```

Gates:

- measured large-linear speed at least 2.7x at 2K and 3.3x at 8K, or at least
  2.7x at 8K with measured attention speed at least 2x;
- routers and GDN recurrence stay strict; state/cache precision changes are
  separately ablated and reported;
- saturation counts are zero or pre-registered and quality-safe;
- complete matrix reaches 2.5x and passes Q0–Q4.

E17 half accumulation, E18 native-uint4 factoring, and E19 relaxed MPP do not
satisfy this hypothesis: their measured M3 implementations were flat/slower.

### Rank 3 — E22: speculative artifact construction with sparse correction

**Hypothesis:** an artifact-eight/top-2 draft can build all K/V and recurrent
state cheaply, then exact recomputation of sensitivity-selected token-layer
cells plus ordered GDN replay can recover quality without exceeding 20% exact
work.

Budget:

```text
speed = 1 / [f_exact + (1-f_exact)/draft_speed + correction_overhead]
draft_speed = 4x => f_exact must be <= 0.20 before overhead for 2.5x
```

Correction must update K/V before deeper consumers and replay each affected
GDN suffix in order. A frontier-only patch is not accepted as “corrected.”

Proposed command:

```bash
for f in 0.10 0.15 0.20 0.30; do
  run_matrix "e22-f${f}" \
    env DARKBLOOM_QWEN35_PREFILL_DRAFT_PROFILE=artifact8-top2 \
        DARKBLOOM_QWEN35_PREFILL_CORRECTION_FRACTION="$f" \
        DARKBLOOM_QWEN35_PREFILL_CORRECTION_POLICY=router-state-sensitivity-v1
done
```

Gates:

- candidate reports draft, recomputed, and GDN-replayed token-layer counts;
- no CPU readback/eval barrier is inserted in each layer;
- recomputed fraction is measured, not inferred from a threshold;
- `f<=0.20` must pass Q0/Q1 before task quality; `f>0.20` cannot reach the
  target under the registered 4x draft and is diagnostic only;
- any claim of exactness requires equality to a full replay. Otherwise the
  profile is explicitly approximate and must pass Q0–Q4.

### Rank 4 — E23: exact hybrid prefix checkpoint and shared-prefix fork

**Hypothesis:** store one atomic prefix artifact containing ten K/V snapshots
and all thirty GDN boundary states, then restore/fork it without recomputing the
matched prefix.

This requires extending Qwen's currently-disabled prefix capability. A cache
hit is valid only for the same model/weight hash, token prefix, cache salt,
execution profile, and state representation. Arbitrary non-prefix blocks are
not exact hits.

The experiment adds a focused benchmark mode:

```bash
"$BIN" benchmark \
  --config "$CONFIG" --model "$MODEL" \
  --qwen-prefix-reuse \
  --prefix-lengths 4096,6144,7168 \
  --prompt-tokens 8192 --requests 4 \
  --decode-tokens 64 --iterations 3 \
  --kv-backend contiguous \
  >"$OUT/e23-prefix.json" 2>"$OUT/e23-prefix.stderr"
```

`--qwen-prefix-reuse` is part of E23's implementation deliverable. It must emit
cold, warm, and simultaneous-shared-prefix arms rather than modifying the
existing cold denominator.

Gates:

- cold and adopted outputs/finish reasons are token-exact;
- recurrent state, offsets, and row ownership survive donation/adoption;
- warm 8K with at least 60% matched tokens is at least 2.5x;
- simultaneous B=4 reaches 2.5x only when measured common-prefix fraction is
  at least 80%;
- cancellation of one fork cannot mutate another;
- report this as a repeated-prefix result. It cannot satisfy the cold primary
  matrix unless the goal is explicitly amended.

Sparse recurrent checkpoints can reduce storage for partial-overlap workloads:
restore the deepest exact boundary and recompute the unmatched gap. They change
the memory/latency frontier, not the amount of cold work.

### Rank 5 — E24: fixed-k MoE quality/performance calibrator

**Hypothesis:** top-4 or top-2 prefill routing removes enough real expert tiles
to be a useful component, and the fixed checkpoint tolerates the resulting
state drift. This cannot reach 2.5x alone, but it is the smallest high-value
experiment and calibrates how much semantic approximation the model permits.

Patch:

```text
research/qwen36-prefill/patches/052-prefill-moe-topk.patch
```

Mac commands:

```bash
run_matrix e24-control \
  env -u DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K \
      -u DARKBLOOM_QWEN35_PREFILL_MOE_FULL_LAYERS
run_matrix e24-k4 \
  env DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K=4 \
      DARKBLOOM_QWEN35_PREFILL_MOE_FULL_LAYERS=39
run_matrix e24-k2 \
  env DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K=2 \
      DARKBLOOM_QWEN35_PREFILL_MOE_FULL_LAYERS=39
```

Gates:

- default/unset path is checkpoint top-8;
- the candidate applies only to explicit CBv2 prefill, never `T=1` decode or
  MTP target verification;
- k4 needs at least 15% and k2 at least 25% B=4×8K improvement to continue;
- decode remains within 3%, no cell regresses more than 5%, and Q0–Q4 pass;
- if fixed-k quality fails, collect router-mass histograms before building a
  GPU-resident ragged adaptive-k plan.

## 6. Recommended execution order

The practical order differs from the target ranking:

1. Run E24 k4/k2 because its default-off seam and unit tests already exist.
2. Implement E20 only far enough to measure the 32/24/16/12/8 depth-quality
   curve. Stop immediately if quality collapses long before the target depth.
3. Fund E21 integration only after a complete M3 primitive crosses its
   inclusive 27-TFLOP/s gate.
4. Use E22 only if E20/E24 show that partial approximation is tolerated but
   neither fixed profile passes.
5. Build E23 as a separate exact product optimization when repeated-prefix hit
   distribution justifies it; never use it to relabel a cold-prefill result.

Do not prioritize final-layer narrowing, cache quantization, projection fusion,
or WY scan as standalone target attempts. Their quantified ceilings are too
small. They become useful only after one structural experiment supplies the
main multiplier.

## 7. Artifact-eight implementation handoff

The default-off implementation is preserved as four ordered root-repository
patches because the agent identity cannot push the `mlx-swift-lm` submodule:

```text
research/qwen36-prefill/patches/052-prefill-moe-topk.patch
research/qwen36-prefill/patches/053-cbv2-prefill-layer-skip.patch
research/qwen36-prefill/patches/054-cbv2-artifact-eight-state-cache-only.patch
research/qwen36-prefill/patches/055-cbv2-prefill-diagnostics-stderr.patch
```

Apply `052`, `053`, `054`, then `055`, to submodule base
`ab73a827c9dde6f8802507003aa0be71605aab8e`. This reproduces the exact tree at
local submodule commit `51ab73f`; intermediate development commits are
`bfcf71c`, `23d3b16`, and `bd81d9e`. The final tree constructs the requested
artifacts and isolates experiment diagnostics to stderr.

The registered run arm is:

```bash
env DARKBLOOM_QWEN35_PREFILL_ARTIFACT_ONLY=1 \
    DARKBLOOM_QWEN35_PREFILL_FULL_LAYERS=0-3,36-39 \
    "$BIN" benchmark ...
```

Omitting `DARKBLOOM_QWEN35_PREFILL_FULL_LAYERS` selects that same eight-layer
set. The enable flag remains mandatory. This handoff records implementation
and tests only; it makes no throughput or quality claim. The Mac benchmark and
Q0–Q4 decision remain pending.

## Sources

Repository:

- `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift`
- `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/{PrefillOutputV2,LastQueryPrefillV2,LayerCacheV2,RecurrentStateV2,EngineV2}.swift`
- `research/qwen36-prefill/notes/{026,030,037,038,051,052,055,056}-*.md`
- `research/qwen36-prefill/results.tsv`

External algorithms:

- Yang et al., [Gated Delta Networks: Improving Mamba2 with Delta
  Rule](https://arxiv.org/abs/2412.06464) — gated chunkwise WY recurrence.
- Liu et al., [KIVI: A Tuning-Free Asymmetric 2bit Quantization for KV
  Cache](https://proceedings.mlr.press/v235/liu24bz.html) — per-channel K,
  per-token V, residual full-precision window. Its throughput gains come from
  memory/batch expansion and do not transfer as a cold-prefill compute claim.
- Yao et al., [CacheBlend: Fast Large Language Model Serving for RAG with
  Cached Knowledge Fusion](https://arxiv.org/abs/2405.16444) — selective KV
  recomputation for transformer blocks; Qwen's ordered recurrent state adds a
  dependency absent from that result.
- [Sparse Prefix Caching for Hybrid and Recurrent LLM
  Serving](https://arxiv.org/abs/2605.05219) — exact sparse recurrent
  checkpoints with suffix recomputation.
- [Marconi: Prefix Caching for the Era of Hybrid
  LLMs](https://arxiv.org/abs/2411.19379) — hybrid-model cache admission and
  eviction under exact-match constraints.
