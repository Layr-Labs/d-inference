# 078 — E50 cohort activation subspace contraction with sentinel repair

Status: **new fixed-weight cold-prefill experiment preregistered; offline probe
implemented; no Mac or model-quality result**

## Verdict

The one new mechanism worth screening is **cohort activation subspace
contraction with output-sentinel residual repair**:

1. factor a runtime prefill activation cohort across its token/assignment axis;
2. apply each original immutable quantized weight only to the small activation
   basis;
3. reconstruct every output row;
4. use a small set of exact output columns to identify bad rows; and
5. apply the original weight to the exact activation residual of only those
   rows.

This is not the exact/approximate **weight** factorization screened in notes
047/058. The checkpoint tensor remains untouched and full-rank. The proposed
low-dimensional object is the prompt-dependent activation matrix. It is also
not layer skip, cache compression, prefix reuse, or dead strict MPP: every
token still traverses all 40 layers, all ten K/V histories and thirty GDN
states are constructed, routers remain strict, and the candidate composes with
the measured top-k4 prefill policy.

There is a direct arithmetic route. The measured B=4x8K top-k4 result is
1.192x native. Retaining all unexplained top-k4 wall time means contracted
linear work must cost at most **35.8122%** of current top-k4 linear work, or
improve at least **2.7923x**, before any extra integration overhead. The
preregistered shape schedule below costs 24.39% by charged MAC-equivalents and
therefore has room for measurement loss.

There is **no quality claim yet**. Runtime activations may not have a useful
rank at the required repair fraction, sentinel columns may miss harmful rows,
and small-rank QMM plus dynamic reconstruction may be slow on M3. The Mac gates
below are intentionally able to kill the mechanism before serving integration.

## 1. Why this branch is genuinely new

### 1.1 Exact weight rank is already closed

Note 047 audited 31,887 logical dequantized matrices. Every dense projection
rules out the 39% exact rank deletion needed by that experiment, and the
adversarial complete routed top-8 upper bound is 24.46%. Replacing
`W[K,N]` by static checkpoint factors is not reopened.

E50 instead observes that for one live cohort:

```text
X[M,K] ~= Q[M,r] B[r,K]
```

and evaluates:

```text
native               Y       = X W
activation basis     Y_hat   = Q (B W)
selected row repair  Y_hat[S] += (X[S] - Q[S] B) W
```

`W`, its affine W4 bytes, scales, biases, and hash are unchanged. `Q` and `B`
are request-local execution state, not learned parameters. At `S=all rows`,
the real-arithmetic expression returns to `XW`; useful speed requires a much
smaller `S`.

### 1.2 It preserves the state-construction topology

Unlike E4/E8 frontier-state-river, no layer becomes identity and no historical
hidden row is replaced by one early-depth river. Every attention/GDN output,
residual, MoE, K/V write, and recurrent transition still executes. Only selected
large projections use an approximate contraction.

That distinction matters because the measured state-river quality failure was
not marginal:

| Profile | Native-score retention | Candidate-only fatal cases | Performance context |
|---|---:|---:|---:|
| frontier E4 | 40.00% | 6 | arithmetic-fast, unusable |
| frontier E8 | 66.22% | 3 | 2.41x at B=4x2K |
| top-k4, all layers | 96.44% at 128 tokens | 0 | 1.192x at B=4x8K |

E50 keeps the top-k4 policy and starts from its quality-passing full-depth
topology rather than trying another blind depth mask.

### 1.3 Why MTP-hidden draft is not the first implementation

The inline Qwen MTP head is useful evidence but not a free prompt encoder.
`Qwen35MTPModule` fuses:

```text
target final-normalized hidden at t + actual embedding at t+1
  -> 2048-wide fusion
  -> one full-attention/MoE MTP layer
  -> hidden used to predict t+2
```

For a cold prompt, the required target final hidden is exactly what a cheap
parallel draft does not have. Recursively generating it makes the MTP hidden
chain token-serial and repeatedly executes a small-M projection path; feeding
an early-layer hidden changes the head's trained input distribution. Neither
is currently an arithmetic or quality-backed substitute for all prompt
hidden rows. An MTP residual may be tested later as a *basis initializer* only
after E50 establishes a rank signal; it is not smuggled into this first arm.

### 1.4 Why ANE/CoreML is a later execution backend, not the mechanism

The current tree has no CoreML path for affine-W4 dense projections or dynamic
gathered experts. A CoreML experiment would first need to prove:

- exact derivation from immutable checkpoint values;
- compile/load feasibility for the 20 GiB model and 256 expert banks;
- dynamic routed gather support without CPU fallback;
- no per-layer GPU/ANE copy or synchronization tax; and
- inclusive speed across dense and routed shapes.

Offloading only the shared expert or another small branch cannot supply the
missing multiplier. If E50 finds a quality-passing activation rank, its dense
`Q @ (BW)` reconstruction is an independent ANE/CoreML backend candidate
because its inner rank is static per profile. The first implementation stays
in MLX/Metal so backend viability is not confused with model-policy viability.

## 2. Exact candidate policy

### 2.1 Dense projection

For each named prefill activation site:

1. Form a deterministic random range sample `Z = X Omega`, where `Omega` is a
   fixed algorithmic Rademacher/Gaussian sketch identified by profile seed.
2. Orthogonalize `Z` on device to obtain `Q`; compute `B = Q^T X`.
3. Apply the existing `QuantizedLinear` weight to `B`.
4. Reconstruct `Y_hat = Q(BW)`.
5. Select `h` deterministic output columns. Compute those columns directly
   from `X` and compare with `Y_hat`.
6. Select at most `p*M` rows by relative sentinel error, entirely on device.
7. Gather their input residual `R_S = X[S] - Q[S]B`, run `R_S` through the
   same original quantized weight, and scatter-add into `Y_hat[S]`.

The full native output is evaluated only in the shadow probe. It is forbidden
as a selector oracle in the timed candidate.

One basis is shared when projections already share an input:

- GDN `qkv/z/a/b`;
- full-attention `q/gate/k/v`;
- routed gate/up and shared gate/up after the strict router has selected
  top-k4. Routers and scalar gates themselves remain strict.

Output projections use their own basis because their input differs.

### 2.2 Routed experts

After strict top-k4 routing, flatten the routed activation assignments:

```text
X_route[A,K], expert_id[A], A = M * 4
X_route ~= Q_route B_route
Z[e,r,N] = B_route W[e,K,N]       for all 256 experts
Y_hat[a] = Q_route[a] Z[expert_id[a]]
```

Sentinel and repair operations use each assignment's routed expert:

```text
Y_hat[S] += (X_route[S] - Q_route[S] B_route)
            W[expert_id[S]]
```

This avoids 256 separate activation decompositions and retains the existing
expert identities, top-k4 scores, and weighted combine. Gate/up and down have
separate bases because SwiGLU lies between them.

### 2.3 Fail-closed boundaries

The profile is valid only for explicit CBv2 text prefill with `T>1`.

- Decode and MTP target verification always use the incumbent projection.
- Routers, softmax/norm, attention, GDN recurrence, cache writes, and final LM
  head remain incumbent.
- Unsupported shapes, non-finite basis state, rank failure, too many repair
  rows, or a device-side allocation failure fall back **before** state mutation.
- A fallback row remains in timing and accounting; it is never dropped.
- The profile ID, seed, rank table, sentinel table, repair caps, fallback
  counts, and actual repaired counts enter benchmark artifacts and telemetry.

## 3. Binding arithmetic budget

### 3.1 Composition with measured top-k4

At 8K, the inherited ledger is:

```text
native linear work                         4.87342080 GFLOP/token
top-k4 linear work                         3.86678784 GFLOP/token
GDN scan + full attention                  0.78130048 GFLOP/token
native total                               5.65472128 GFLOP/token
measured B=4x8K top-k4 speedup             1.192x
measured top-k4 wall fraction              1 / 1.192 = 0.83892617
top-k4 linear/native arithmetic fraction   3.86678784 / 5.65472128
                                             = 0.68381581
fixed measured residual                    0.83892617 - 0.68381581
                                             = 0.15511036
```

Let `c` be the **inclusive** candidate/top-k4 linear cost fraction, MAC-weighted
across all shapes, and `o` be extra wall cost normalized by native B=4x8K time
that is not charged inside `c`:

```text
T_candidate / T_native = 0.15511036 + 0.68381581*c + o
```

The 2.5x condition is:

```text
c <= (0.40000000 - 0.15511036 - o) / 0.68381581
with o=0: c <= 0.35812222, or >=2.79234276x linear contraction
```

The primitive continuation gate is stricter: `c <= 0.30`. At `o=0` that
predicts 2.776x native and leaves 0.03974 native wall fraction, about 0.836 s
of the measured 21.0375 s B=4x8K baseline, for unmodeled integration loss.

At B=4x2K, the measured 1.213x top-k4 arm yields a looser binding limit of
`c <= 0.43461` (at least 2.301x). The 8K cell remains the design constraint.

### 3.2 Charged projection formula

For dense `X[M,K] W[K,N]`, rank `r`, `h` sentinel columns, `s` repaired rows,
and zero power iterations, the probe charges MAC-equivalents:

```text
baseline                         M K N
range sample + basis coefficients 2 M K r
basis through weight              r K N
output reconstruction             M r N
sentinel columns                   M K h
repair input reconstruction        s r K
repair through weight              s K N
conservative QR equivalent       2 M r^2
```

Every power iteration adds `2 M K r + 2 M r^2`. It is disabled in the first
profile.

For routed experts, replace basis-through-weight with `E r K N`, where
`E=256`, and use `A=M*4` assignments for every other `M`. This term prevents
pretending all expert weights are one matrix.

### 3.3 Preregistered B=4x2K projection schedule

This is the first shadow schedule, not a tuned quality result. `M=8192`,
`A=32768`, zero power iterations:

| Projection family | Shape | `r/h/p` | Charged fraction |
|---|---|---:|---:|
| GDN shared input bundle | `8192x2048 -> 12352` | `128/32/12%` | 0.2241 |
| attention input bundle | `8192x2048 -> 9216` | `128/32/12%` | 0.2329 |
| GDN/attention output | `8192x4096 -> 2048` | `64/16/12%` | 0.2186 |
| shared expert gate/up | `8192x2048 -> 1024` | `32/8/10%` | 0.1940 |
| shared expert down | `8192x512 -> 2048` | `32/8/10%` | 0.2052 |
| routed gate/up, 256 experts | `32768x2048 -> 1024` | `16/8/10%` | 0.2737 |
| routed down, 256 experts | `32768x512 -> 2048` | `16/8/10%` | 0.2771 |
| routers + scalar gates | strict | — | 1.0000 |

Weighting those fractions by the exact top-k4 linear ledger gives:

```text
candidate linear work    0.94326088 GFLOP/token
top-k4 linear work       3.86678784 GFLOP/token
c                        0.24393913
modeled native speed     3.106x before extra wall overhead
maximum extra o          0.07808020 native wall fraction
                         = 1.643 s at B=4x8K
```

This is an arithmetic budget, not a latency prediction. Small-rank QMMs may
be weight-bandwidth-bound, QR may synchronize, reconstruction has different
throughput from affine W4 QMM, and repair gathers may fragment. Measured
inclusive wall time overrides this table.

## 4. Implementable code path

Current seams:

- `MLXNN.QuantizedLinear.callAsFunction` reaches `quantizedMM` with public
  weight/scales/bias metadata.
- `QuantizedSwitchLinear.callAsFunction` reaches `gatherQuantizedMM` with
  expert indices.
- `Qwen35SparseMoeBlock` computes the strict router and top-k indices before
  `SwitchGLU`.
- `Qwen35DecoderLayer.cbv2Forward` already distinguishes dedicated prefill
  routing from decode/MTP.

Implementation sequence:

1. Add `ActivationSubspaceProbe` in a focused MLXLMCommon file. It owns
   deterministic sketch construction, on-device orthogonalization, sentinel
   scoring, repair selection, accounting, and fail-closed result metadata.
2. Add an explicit Qwen prefill projection policy keyed by layer and projection
   family. Default is disabled. Do not modify generic `Linear` behavior.
3. Expose dense contracted application on `QuantizedLinear` and global-basis
   expert application on `QuantizedSwitchLinear`; retain current methods as
   the fallback.
4. Wire shared-input bundles first in shadow mode. Evaluate native and
   candidate projection roots together, record errors, and return native.
5. Wire routed gate/up and down shadow paths, including all-expert basis cost.
6. Only after the shadow and primitive gates pass, return candidate roots in
   explicit CBv2 prefill and run complete state/quality evaluation.

The device path may replace QR with a fixed-shape Gram/Cholesky or custom
orthogonalization only if it has no CPU readback and the charged operation
count is updated. The offline NumPy probe is a numerical roof, not the serving
implementation.

Proposed profile controls after integration:

```text
DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K=4
DARKBLOOM_QWEN35_PREFILL_ACTIVATION_CONTRACT=e50-r1
DARKBLOOM_QWEN35_PREFILL_ACTIVATION_CONTRACT_SHADOW=1
```

## 5. Probe delivered

`probes/activation-residual-contract/` contains:

- `budget.py`: dense/expert MAC accounting and measured top-k4 composition;
- `probe.py`: randomized activation basis, sentinel-only row selection,
  selected exact residual repair, chunked full-output scoring, input hashes,
  and JSON result;
- `test_probe.py`: arithmetic, exact-rank fixture, residual-repair, and
  sentinel-recall regression tests;
- `README.md`: reproducible synthetic and captured-projection commands.

The probe accepts activation `[M,K]` and dequantized checkpoint weight `[K,N]`
`.npy` files. The dequantized export must follow the checkpoint's actual BF16
affine decode and be tied to the original model hash. A convenient float32
re-dequantization is a different matrix and is rejected.

Probe output thresholds are an early engineering screen only:

```text
charged candidate MAC fraction             <= 0.30
projection output NRMSE                    <= 0.01
p99 row relative L2                        <= 0.05
p01 row cosine                             >= 0.995
sentinel recall of oracle worst repair rows >= 0.90
```

The full output is used only to evaluate sentinel recall and numerical error.
If a script uses full-output error to pick repairs, the result is invalid.

### 5.1 Local implementation validation

The Linux/NumPy run validates probe behavior, not Qwen rank or M3 speed:

```text
python3 -m unittest -v test_probe.py
  7 tests, PASS

rank-8 synthetic source, candidate rank 16, no repair
  charged MAC fraction       0.119140625
  output NRMSE               0.000124813
  p99 row relative L2        0.000283129
  projection screen          PASS

rank-128 synthetic source, candidate rank 16, 10% repair
  charged MAC fraction       0.220802307
  output NRMSE               0.850335073
  p99 row relative L2        0.973778107
  projection screen          FAIL (numerics)

same high-rank source, 100% repair
  charged MAC fraction       1.134765625
  output NRMSE               0.000000410
  projection screen          FAIL (arithmetic)
```

The positive fixture only proves that the implementation recognizes a matrix
constructed to be low rank. The two negative controls prove that the screen
rejects both a cheap inaccurate contraction and an accurate over-budget exact
repair endpoint.

## 6. Mac continuation gate

### M0 — Adjacent controls and immutable inputs

On the dedicated `m3-max-128gb-2`:

- AC power, High Power, quiet GPU, no provider daemon;
- pinned binary, root/submodule commits, model/config/index/shard hashes;
- prefix/block cache off, MTP off for text timing, contiguous KV;
- adjacent native and top-k4 controls at B=1/2/4, lengths 512/2K/8K;
- control must reproduce locked makespan within 8%.

Stop on a hash/config mismatch, missing cell, wrong flattened cohort geometry,
or a top-k4 control outside the validity band.

### M1 — Shadow activation-rank screen

Capture or evaluate on device for all 40 layers and every family in section
3.3, using a calibration corpus disjoint from quality acceptance:

- requested and achieved rank;
- sentinel and oracle output errors;
- repair count/fraction and selected-index hash;
- fallback/non-finite/orthogonalization failures;
- candidate bytes and every allocation;
- strict and candidate wall time by component.

Continue only if:

1. at least 95% of top-k4 linear MACs have a valid candidate or explicit strict
   fallback record;
2. the MAC-weighted candidate fraction including strict fallbacks is `<=0.30`;
3. every candidate projection passes the five probe thresholds;
4. actual repair never exceeds the preregistered cap;
5. no rank/repair policy changes with B solely because rows are co-scheduled;
6. there is no CPU readback or per-layer synchronization in the candidate.

Failure here rejects E50. Do not increase ranks/repair after seeing holdout
quality unless the recomputed weighted fraction remains below 0.30 and the
change is frozen on calibration data.

### M2 — Inclusive primitive speed

Time candidate versus incumbent at the real M3 shapes, including sketch,
orthogonalization, `B`, quantized basis projection, reconstruction, sentinels,
top-row selection, residual gather/QMM/scatter, and all-expert basis work.

Continue only if:

```text
MAC-weighted candidate/strict projection wall <= 0.30
each major family candidate/strict wall        <= 0.40
peak active bytes stay within UnifiedMemoryCap
no Metal fault, allocation refusal, NaN/Inf, or fallback omission
```

The first ratio is the practical `>=3.33x` inclusive linear gate. A favorable
dense shape cannot average away a failed routed shape.

### M3 — Full-model performance

Enable candidate return values only after M1/M2 pass:

- B=4x2K must reach at least 2.5x native before funding 8K;
- B=2x8K makespan `<=4.3666 s` / aggregate `>=3,751.8 tok/s`;
- B=4x8K makespan `<=8.4150 s` / aggregate `>=3,893.5 tok/s`;
- report B=1/2/4 at 512/2K/8K, all submitted/completed rows, repair/fallback
  counts, peak memory, and first-128 decode time;
- B=1 and every non-primary cell must be at least 0.98x its adjacent top-k4
  control or use an explicit per-shape strict fallback.

No selector, rank construction, materialization, or repair may move behind the
first-token timestamp.

### M4 — State and quality, binding

Compare three named arms: native top-8, top-k4 full-depth, and E50+top-k4.
Tune only on calibration; evaluate the frozen profile once on holdout.

Automatic reject:

- changed checkpoint bytes/hash, missing K/V, non-FP32 GDN state, wrong
  cache/state offset, cross-row contamination, cancellation leak, NaN/Inf,
  Metal fault, or unreported fallback;
- any strict router difference between top-k4 and E50 caused before the routed
  expert contraction;
- candidate/native blind adjusted-score retention below 95%;
- candidate/top-k4 blind adjusted-score retention below 98.5%;
- any candidate-only fatal case or any corruption case with `X>=3`.

The complete inherited Q0-Q4 gates remain binding:

- frontier mean KL `<=0.010`, p99 `<=0.100`, no length-bucket mean `>0.015`;
- forced 256-token strict-decode NLL delta and paired-bootstrap upper bound
  `<=0.005 nat/token`;
- WikiText/C4 NLL non-inferiority `<=0.005 nat/token`;
- frozen task margins with zero new LongBench retrieval or tool/JSON hard
  failure;
- decode B=1/2/4 after 512 and 8K at least 0.98x control;
- ten-iteration B=2/B=4 8K cancellation/uptime soak without fault signature.

Passing the 12-case 128-token screen alone is not enough. Top-k4 already uses
most of the permissive 95% score margin.

## 7. Decision rule

E50 earns integration only if real activations are contractible at the frozen
rank/repair schedule **and** the complete operation is at most 0.30x the
incumbent projection wall. It earns retention only if both B=2 and B=4 8K
cross their absolute 2.5x bars and all state/quality gates pass.

If rank must rise, repair exceeds its cap, routed expert basis work misses the
inclusive wall gate, or quality falls below the frozen thresholds, record the
failure and stop. Do not relabel a shadow/oracle result, synthetic low-rank
fixture, CoreML microbenchmark, or exact-repair endpoint as a 2.5x model result.

## Sources checked

- `research/qwen36-prefill/{GOAL.md,results.tsv}`
- `research/qwen36-prefill/notes/{026,047,050,051,054,055,063,066,067,077}-*.md`
- `libs/mlx-swift/Source/MLXNN/Quantized.swift`
- `libs/mlx-swift-lm/Libraries/MLXLMCommon/SwitchLayers.swift`
- `libs/mlx-swift-lm/Libraries/MLXLLM/Models/{Qwen35,Qwen35MTP}.swift`
