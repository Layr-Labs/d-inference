# 032 — Hostile review: the M3 Max impossibility roof is not signed

Status: **FAIL — broad impossibility claim not established**

Scope: hostile review of `GOAL.md`, `program.md`, notes 011/027/028/029,
the E3/E4 raw artifacts, the benchmark source currently present as
`libs/mlx-swift/Tests/MLXTests/QwenExpertDenseReferencePerfTests.swift`,
the pinned MLX dispatch/kernel source, and the current reviewer gate.

This verdict does **not** say 2.5× is likely. It says the supplied evidence
does not prove that exact Qwen 3.6 aggregate prefill cannot reach 2.5× on this
M3 Max. The evidence closes several implementations. It does not establish a
hardware upper bound.

## Verdict in one paragraph

E2 kills the tested `[4,1024]` scheduler geometry. E3 kills a persistent BF16
expert cache through the current MLX gather-MM implementation. E4 shows that
changing BF16 inputs to FP16 does not make the current Steel kernel leave its
FP32 `simdgroup_matrix` arithmetic regime. None of those facts bounds a
different exact mixed-input Metal kernel. The claimed proof additionally uses
an incorrect 93% routed-expert attribution, benchmarks synthetic balanced
experts rather than the real snapshot, does not preserve immutable benchmark
source/provenance, does not capture thermal or GPU-counter evidence, and does
not measure the program's B=4 8K acceptance cell. Most importantly, Metal 4 on
the host's macOS 26.4 exposes `bfloat × bfloat -> float` and
`bfloat × uint4b_format -> float` TensorOps. Apple states that TensorOps run
from M1 through M5 and fall back to optimized shaders on GPUs without the M5
neural accelerator. E3/E4 never execute those paths.

Reviewer disposition:

- **PASS, narrow:** the current non-NAX MLX Steel route has only low-teens
  measured headroom at the tested synthetic `M=16,384` shapes.
- **PASS, narrow:** materializing a 60–75 GiB BF16 expert cache is unsupported
  by the measured result and should remain dead.
- **PASS, narrow:** ordinary `eval(run())` is blocking; there is no evidence
  that E3/E4 accidentally timed only command submission.
- **FAIL, broad:** “exact Qwen 3.6 prefill cannot reach 2.5× on M3 Max.”
- **FAIL, artifact gate:** E3/E4 are not sufficient for an independent
  reviewer to reproduce or sign.

## 1. The FLOP count is locally correct; the Amdahl proof is not

### 1.1 What E3 counted correctly

For both routed projections in the benchmark:

```text
assignments = 16,384

gate_up: 2 × 16,384 × 2,048 × 1,024 = 68.719476736 GFLOP
down:    2 × 16,384 ×   512 × 2,048 = 68.719476736 GFLOP
```

Counting one multiply and one add as two useful model FLOPs is internally
consistent with the project ledger and common advertised GPU FLOP rates. The
reported effective rates reproduce from those counts and the logged medians.

That is only a **useful-work** count. Affine W4 QMM also unpacks nibbles,
loads scale/bias values, computes dequantized values, casts them, builds or
walks expert descriptors, and may execute partial tile work. Those operations
are absent from `2*M*N*K`. Therefore:

- `2*M*N*K / wall` is a valid effective-throughput metric;
- it is not a count of executed hardware operations;
- it cannot be compared to an FP32 peak as a hard bound unless every legal
  implementation is first proved to require one FP32 FMA per useful MAC.

That last premise is false for the available Metal API surface (§3).

### 1.2 “Routed QMM is 93%” is false

The corrected per-token ledger is:

```text
routed expert linear work       2.0133 GFLOP/token
all non-routed linear work      2.8602 GFLOP/token
all linear work                 4.8734 GFLOP/token
GDN recurrence                  0.1101 GFLOP/token
attention at P=2,048           ~0.1679 GFLOP/token
modeled total at P=2,048       ~5.1514 GFLOP/token
```

Thus routed gate-up plus down is:

```text
2.0133 / 4.8734 = 41.3% of linear FLOPs
2.0133 / 5.1514 = 39.1% of modeled total FLOPs at 2K
```

The 93–95% figure can describe **all linear projections** at 2K. It cannot
describe routed experts alone. Note 028 applies the 1.13× routed
gather-to-monolithic ratio to 93% of the full model:

```text
1 / (0.93 / 1.13) = 1.22×
```

That calculation is not licensed by E3. Applying the same deliberately
impossible “everything else is free” construction to the actual routed FLOP
share gives:

```text
1 / (0.391 / 1.13) = 2.89×
```

The measured wall-time cross-check is even more direct. E3's two routed
medians imply:

```text
(6.3125 ms + 3.3834 ms) × 40 layers = 0.3878 s
0.3878 / 1.2253 s B=1 2K baseline    = 31.7% of wall
```

E1 gave approximately 0.404 s, or 33.0%. Making that measured route 1.13×
faster and granting a zero-cost tail gives a nonsensical but valid upper
construction above 3×, not 1.22×.

This does not make 2.5× achievable. It proves only that note 028's stated
Amdahl contradiction does not exist.

### 1.3 E3 does not bound all linear projections

The non-routed linears contain more FLOPs than the routed experts and run
different shapes:

- GDN: `2048->8192`, `2048->4096`, two `2048->32`, and `4096->2048`;
- attention: `2048->8192`, two `2048->512`, and `4096->2048`;
- shared experts: `2048->512` and `512->2048`;
- routers: `2048->256`;
- dense row counts are cohort tokens, not eight routed assignments per token.

E3 measures routed `(K,N)=(2048,1024)` and `(512,2048)` at
`M=16,384`. Its plain monolithic matmul cannot be assigned as a universal
1.13× ceiling to the dense shape mix. Tile selection, cache reuse, split-K,
dispatch count, output width, and mixed-input opportunities differ.

A hard projection roof must be a real-dispatch-count-weighted result over
every projection shape at every candidate cohort size, not one favorable
square-ish reference reused as a constant.

### 1.4 The “27.2 TFLOPS required” threshold is not the system threshold

`2.5 × 10.89 = 27.2 TFLOPS` is the rate required to make that one routed
kernel itself 2.5× faster. It is not derived from the full-model target.

For the measured B=4, P=2K cell:

```text
baseline makespan             4.9360 s
2.5× target                  1.9744 s
all-linear work             39.9231 TFLOP
zero-tail linear threshold  20.22 TFLOP/s
```

With a 0.25–0.40 s exact non-linear tail, the required weighted all-linear
rate is about 23.2–25.4 TFLOP/s. That is still far above E3's current Steel
result, but it is a different claim and must be evaluated across all linears.

## 2. The BF16 monolithic result is not a hardware upper bound

`monolithicRun()` executes:

```swift
x.reshaped([assignments, k]).matmul(denseWeights[0])
```

It is one plain MLX matmul against the first synthetic expert matrix. It is
not a gather, not a real MoE computation, not a hardware-intrinsic peak test,
and not an exhaustive kernel search.

It is intentionally favorable in several ways:

- one 4 MiB BF16 matrix is reused for every row;
- all dimensions are tile-aligned;
- expert routing and dequantization are absent;
- the output is already warm after three iterations.

Those properties make it a useful implementation control. They do not make
its 12.3 TFLOP/s an upper bound. It can still lose to:

- another Steel tile schedule or dispatch order;
- a Metal Performance Primitives/TensorOps kernel;
- a cooperative-tensor dequantize-plus-matmul kernel;
- a native packed-input TensorOp;
- an MPS/MPSGraph dense control;
- a shape-specialized kernel that fuses exact affine reconstruction.

The distinction is categorical:

```text
measured best implementation in E3 != maximum achievable by the hardware
```

To call 12.3 a hardware bound, the artifact would need either a documented
hardware issue limit that applies to the exact operand/accumulator types, or
counter evidence that a peak-capable implementation saturates that limit.
E3 supplies neither.

## 3. A concrete hidden Metal path remains untested

### 3.1 E4 did not test a lower-width matrix lane

In the pinned Steel source, `BlockMMA` defaults `AccumType = float`.
`qmm_t_impl`, `qmm_t_expert_impl`, and the dense Steel GEMM instantiate float
accumulator fragments. `BlockMMA`'s A, B, and C `MMATile`s use that
`AccumType`, so BF16/FP16 values are loaded into float
`simdgroup_matrix` fragments before `simdgroup_multiply_accumulate`.

Therefore E4's BF16-versus-FP16 comparison changes input/storage conversion.
It does not select a BF16/FP16 matrix multiply with an FP32 destination.
Flat E4 results prove the current Steel route remains in the same FP32
arithmetic regime. They do not prove the M3 lacks a faster mixed-input route.

The queued half-accumulator experiment is a different, likely illegal test:
it changes accumulation precision. It must not be confused with a
BF16-input/FP32-destination TensorOp.

### 3.2 Metal 4 exposes the missing mixed-input operations

The current Metal Shading Language specification, Table 7.3, lists:

- Metal 4 + OS 26.1: `bfloat × bfloat -> float`;
- Metal 4 + OS 26.4: `bfloat × uint4b_format -> float`;
- Metal 4 + OS 26.4: `bfloat × int4b_format -> float`.

The target host is recorded as macOS 26.4. Apple's
[M5/A19 GPU talk](https://developer.apple.com/videos/play/tech-talks/111432/)
states that TensorOps code is portable from M1 through M5 and that older GPUs
without neural accelerators fall back to optimized shader implementations.
The [Metal specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)
and [MPP guide](https://developer.apple.com/download/files/Metal-Performance-Primitives-Programming-Guide.pdf)
define the operand/destination combinations.

M3 does not have the M5 per-core neural accelerator. That closes the **M5
NAX hardware** branch. It does not make the TensorOps API nonexistent on M3.
Note 028's statement “M5 Metal 4 TensorOps do not exist on this M3 Max”
conflates API availability with accelerator availability and is false.

MLX's `is_nax_available()` returning false for generation 15 proves only that
MLX will not select its NAX kernels. It says nothing about how a custom MPP
kernel's optimized M3 fallback performs.

### 3.3 The exact legal packed variants

There are two separate candidates and they need separate verdicts.

**Candidate A — exact incumbent operands**

1. Decode each affine W4/g64 tile exactly as the incumbent does.
2. Produce byte-identical BF16 weight values in a cooperative tensor.
3. Feed BF16 activations and those BF16 weights to
   `matmul2d<bfloat,bfloat,float>` with `relaxed_precision=false`.
4. Cast at the same output boundary.

This preserves the incumbent operand bytes and FP32 destination type. Reduction
order may still differ, so operation tolerance and greedy parity must be
measured. It is the cleanest unclosed loophole because it requires no new
activation quantization and no persistent BF16 cache.

**Candidate B — native packed affine reconstruction**

Use `bfloat × uint4b_format -> float` on raw codes and apply each group's
scale and bias in FP32. Algebraically:

```text
sum_i x_i * (s_g*q_i + b_g)
  = s_g * sum_i(x_i*q_i) + b_g * sum_i(x_i), per group g
```

This can avoid unpacking every weight into threadgroup memory. It is not
automatically bit-equivalent: the incumbent rounds each reconstructed weight
to BF16 before the FP32 dot, while factoring scale/bias outside the dot changes
that rounding point. It is legal only if an implementation reproduces the
incumbent rounding or passes the pre-existing QMM tolerance plus every
full-model greedy/KV/GDN gate without loosening them.

**Pure integer dot products are not a free third candidate.** Native
integer×integer units would also require integer activations. Quantizing the
BF16 activations changes the model contract. The mixed
`bfloat × uint4 -> float` operation is the relevant exact-path loophole.

## 4. The E3/E4 benchmark is synthetic, not “exact Qwen”

The current benchmark source:

- creates `MLXRandom.normal` weights;
- quantizes those random weights at runtime;
- creates random activations;
- assigns exactly 64 consecutive rows to every one of 256 experts;
- uses no tensor from the named Qwen snapshot;
- uses no router output from a real prompt.

“Exact serving assignment count” means only that `M=16,384`. It does not mean
exact weights, exact activations, exact routing, or exact serving distribution.
The uniform 64/expert layout is especially favorable to a BM=32 expert kernel:
every expert has exactly two full row tiles. Real routing can contain partial
tiles, hot experts, cold experts, and fewer than 256 touched experts.

This synthetic benchmark cannot answer either of these hostile questions:

1. Does the real quantized snapshot contain exact zero/duplicate/block
   structure a correct kernel can skip?
2. Does any real projection have an exact low-rank factorization that changes
   the mathematical work?

Both are unlikely for trained dense weights. “Unlikely” is not evidence in an
impossibility proof.

### Required real-weight structure scan

For every routed expert projection and every dense projection in the exact
snapshot, archive:

- tensor SHA-256 and quantization metadata;
- exact histogram of raw W4 codes, BF16 scales, and BF16 biases;
- count of exactly zero dequantized values;
- count of all-zero 16×16, 32×32, 32×64, and 64×64 blocks;
- duplicate rows, columns, groups, and whole experts by hash;
- exact rank of the dequantized matrix, not merely approximate SVD rank;
- singular-value diagnostics to expose near-low-rank structure, labeled
  non-exact and therefore non-shippable unless the quality contract changes.

Because BF16 values are dyadic rationals, exact rank can be checked by mapping
a common integer scaling into several large finite fields and confirming with
an exact elimination/factorization for any apparent deficiency. A floating
SVD alone cannot prove exact rank.

For perspective, a rank-`r` factorization beats dense MAC count by 2.5× only
below roughly:

```text
gate_up  (2048×1024): r < 273
down      (512×2048): r < 164
```

If every relevant matrix is full rank and has no useful exact block sparsity
or duplication, this branch closes. E3's random tensors do not close it.

Also capture real per-layer/per-chunk router histograms at B=1/2/4 and
P=512/2K/8K: assignments per expert, touched experts, BM tile count, partial
rows, and repeated routing patterns. Synthetic uniform routing is not a
substitute.

## 5. Timing synchronization mostly passes; error/profiling evidence does not

The ordinary Swift `eval` call is blocking:

- `Transforms+Eval.swift` calls `mlx_eval` under `evalLock`;
- C++ `eval(...).wait()` waits for completion;
- Metal `CommandEncoder::synchronize()` waits for the command buffer and
  throws a recorded command-buffer error.

The timer starts before `run()` and ends after `eval(run())`, so graph creation
and GPU completion are included. A command-submission-only timing explanation
does not fit the source or the 3–6 ms samples. This part of the roof survives
hostile review.

But an implementation wall time is still not a hardware-kernel bound:

- no GPU start/end timestamps are recorded;
- no dispatch count proves every timed iteration executed the intended route;
- no Metal kernel name or expert-route diagnostic is in the artifact;
- no performance counters distinguish math issue, occupancy, cache, memory,
  or command gaps;
- `eval` ignores the integer return value from `mlx_eval`; the default handler
  should trap, but a sign-off benchmark should use `checkedEval`/`withError`
  and explicitly assert no captured error after every evaluation;
- route order is always W4, BF16 gather, monolithic; there is no ABBA or
  randomized order control.

The decisive timing artifact must report CPU wall, command-buffer GPU time,
kernel-level GPU time, dispatch count, and error status for every sample.
Wall/GPU disagreement over 5% must be explained rather than hidden in a
“TFLOPS” number.

## 6. Power, thermal, and provenance gates fail

The E3/E4 text artifacts contain only XCTest output. `results.tsv` says AC and
`powermode=2`, but there is no raw companion evidence for:

- `pmset -g batt`, `pmset -g custom`, and `pmset -g therm` before and after;
- GPU frequency, power, temperature, or performance-limit reason;
- competing CPU/GPU processes;
- cold-versus-soaked repetitions;
- host hardware identity;
- test source SHA, root SHA, recursive submodule SHAs, or metallib SHA;
- environment keys, especially the expert-route selector;
- NAX/TensorOps route diagnostics.

This is not clerical. A throttled run produces a falsely low “roof”; a short
turbo run produces a falsely high sustained roof. E3 lasts about one second
and E4 about two seconds, immediately after large random tensor generation.
Initial temperature and frequency are unknown.

Worse, the benchmark source is currently an untracked file inside
`libs/mlx-swift`, and the E3/E4 root commits contain the notes/artifacts but no
immutable benchmark source or gitlink update. `results.tsv` records only
`mlx-swift-local`. The surrounding working tree also contains experimental
float-dequantization submodule commits. The artifacts do not identify whether
those exact commits, the shipping dequantizer, or another local state produced
the numbers.

An independent reviewer cannot reproduce E3/E4 from the commits that claim
them. That alone fails an impossibility sign-off.

## 7. The tested arithmetic may not be the current Darkbloom contract

The local QMM experiment changes affine dequantization from BF16
multiply/add-per-weight to FP32 scale/bias arithmetic followed by one BF16
cast. Its own regression distinguishes `-110.0` before from `-109.5` after.

That can be a valid upstream semantic correction, but it is not “same current
Darkbloom numerics” by declaration. The current E3 benchmark checks W4 versus
dequantized BF16 with a permissive synthetic `allClose`; it does not show:

- byte-identical incumbent dequantized operands;
- exact real-model greedy checksums;
- unchanged top-8 identities/weights;
- unchanged GDN/KV state;
- full-model B=1/2/4 parity.

Until the artifact pins which dequantization semantics ran and passes the
full contract, “exact QMM” is an unproven label.

## 8. The conclusion targets the wrong acceptance surface

`GOAL.md` is not a requirement for 2.5× B=1 at every length. It explicitly
says that if B=1 is roofed, put the 2.5× into B=2/B=4 aggregate. `program.md`
defines the primary score as B=4, 8K aggregate. The binding reviewer gate says
the project may claim success when the M3 Max B=4 8K median reaches 2.5×,
while B=1 and B=2 must be published and must not regress.

Current accepted artifacts contain:

- B=1 at 512/2K/8K;
- B=2 at 2K only;
- B=4 at 2K only;
- no valid B=2 8K baseline;
- no valid B=4 8K baseline, denominator, or 2.5× target.

Therefore a proof that B=1 cannot reach 2.5× does not kill the requested
objective. A proof about the current `M=16,384` 2K step does not by itself
kill B=4 8K aggregate.

E2 is useful but narrower than its verdict:

- it tests B=4, P=2K, chunk 1,024/budget 4,096;
- it gains 1.034×;
- it changes 2/4 greedy checksums.

That kills that exact candidate. It does not prove that a corrected recurrent
boundary implementation, `[B,2048]` geometry, a mixed-input projection kernel,
or a composition at B=4 8K cannot win. “Do not run `[4,2048]`” is a queue
decision, not a hardware theorem.

The acceptance language also remains slightly ambiguous about whether B=2
must itself reach 2.5×. Before a final roof, the owner must pin one statement:

```text
A. B=4 8K >= 2.5×; B=1/B=2 disclose and do not regress  (current reviewer gate)
or
B. both B=2 8K and B=4 8K >= 2.5×                       (stronger target)
```

No impossibility verdict can be signed against an unstated denominator.

## 9. Decisive loophole tests

Run these in order. A prose argument cannot replace them.

### R0 — Make E3/E4 reproducible

Required:

1. Commit the benchmark source in the exact MLX-Swift submodule commit.
2. Pin that gitlink in the root commit.
3. Archive root/submodule/metallib/test-binary SHAs and all relevant env keys.
4. Log expert route diagnostics and actual kernel names.
5. Run shipping-dequant and FP32-dequant arms separately; never mix them.
6. Use deterministic seeds and retain every sample.

Failure to reproduce the published medians within 8% voids the roof.

### R1 — Lock the actual target and dispatch census

Measure three-or-more post-warmup repetitions for B=1/2/4 at
P=512/2K/8K through real CBv2. Record B=4 8K as the primary denominator.
For each cell, capture every projection dispatch shape and count.

Compute:

```text
T_target = measured_primary_baseline / 2.5
R_linear_required = F_linear / (T_target - measured_legal_tail)
```

No extrapolation from B=1 or 2K is accepted.

### R2 — Weighted all-projection kernel roof

At all real dense row counts and routed assignment counts
`8K/16K/32K/65K`, benchmark:

1. shipping Steel W4 QMM/gather-QMM;
2. current dense BF16 Steel GEMM/gather-MM;
3. MPP `bfloat × bfloat -> float` with exact cooperative dequantization;
4. MPP `bfloat × uint4 -> float` with affine-g64 handling;
5. MPS/MPSGraph dense GEMM as an independent dense control;
6. a bounded tile sweep for the exact shapes.

Report a dispatch-count-weighted harmonic/effective throughput over the real
projection mix. An arithmetic mean of per-cell TFLOP/s is invalid.

Stop condition:

- if a legal weighted path reaches the target from R1, the impossibility claim
  is falsified and full-model integration is required;
- if every legal path misses, continue to R3/R4 before declaring a roof.

### R3 — Prove mixed-input numerical legality

For Candidate A and Candidate B separately:

- compare dequantized BF16 operand bytes against the incumbent;
- compare FP32 outputs and BF16 outputs on adversarial code/scale/bias values,
  overflow/subnormal boundaries, random full shapes, and every real tensor;
- preserve existing QMM tolerances without widening them;
- compare real-model greedy IDs/checksums, top-8 IDs/weights, KV bytes/offsets,
  and GDN state at B=1/2/4 and P=512/2K/8K;
- use `relaxed_precision=false`;
- reject any activation quantization or lower-precision recurrent state.

A half/BF16 accumulator is a separate quality-changing candidate. It survives
only if the existing operation and full-model contracts pass unchanged.

### R4 — Real-weight and real-routing structure audit

Run the exact sparsity/duplication/rank scan from §4 on the SHA-pinned model.
Capture real router histograms and actual expert tile counts from R1.

Decision:

- any useful exact structure requires a measured exact specialized kernel;
- full rank, no block zeros/duplicates, and no exploitable routing structure
  closes this branch;
- approximate low rank or pruning is rejected for this objective.

### R5 — Timing and sustained-power proof

For every roof candidate:

- `checkedEval` or `withError`, with an immediate error check per eval;
- CPU wall and command-buffer GPU timestamps;
- Metal System Trace with kernel names, counters, occupancy, cache bandwidth,
  math utilization, and performance limiters;
- ABBA/randomized route order across fresh processes;
- at least three cold sessions and three thermally soaked sessions;
- AC, High Power, thermal state, GPU power/frequency, and competing processes
  recorded before/during/after.

The roof uses the fastest valid sustained median, not the slowest run.

### R6 — Full-model composition

If any legal projection path survives:

- integrate behind exact shape guards with the incumbent fallback;
- run B=1/2/4 × 512/2K/8K CBv2 prefill;
- run the complete decode, correctness, memory, cancellation, and uptime gate;
- substitute measured projection and tail times into one additive latency
  budget; do not multiply isolated marketing speedups.

Only the full B=4 8K aggregate median can satisfy or falsify the primary goal.

## 10. Exact evidence required for reviewer sign-off

I will sign **“impossible on M3 Max under the current numerical contract”**
only when all boxes below are supplied.

### Objective and denominator

- [ ] Acceptance statement A or B from §8 is explicitly selected.
- [ ] Valid B=1/2/4 baselines exist at 512/2K/8K.
- [ ] B=4 8K raw primary samples and exact 2.5× target are archived.

### Arithmetic

- [ ] Corrected FLOP ledger distinguishes routed from all-linear work.
- [ ] Real dispatch shapes/counts produce a weighted projection workload.
- [ ] The final contradiction uses `F/R + T_tail`, not the 93% routed formula.
- [ ] Quantized/dequant/partial-tile work is reported separately from useful
      `2*M*N*K`.

### Hardware paths

- [ ] Current Steel, bounded tile variants, MPP BF16/FP32, MPP packed uint4,
      and an independent dense control are measured on this M3 Max.
- [ ] MPP route/kernel proof is present; “NAX unavailable” is not substituted.
- [ ] Either all-linear work alone exceeds `T_target` under a counter-supported
      hardware ceiling, or the measured legal tail makes the additive bound
      exceed `T_target`.
- [ ] Performance counters show the claimed ceiling is saturated at maximum
      valid clock; a merely fastest-so-far kernel is not called a roof.

### Exact model structure

- [ ] Real snapshot sparsity, duplicates, exact rank, and routing histograms
      are archived and show no useful exact shortcut.
- [ ] Any candidate packed or reordered arithmetic fails/passes the existing
      numerical contract on adversarial and real-model tests.

### Measurement integrity

- [ ] Benchmark source, root/submodule/metallib/binary/model SHAs are immutable.
- [ ] Route diagnostics, kernel names, dispatch counts, GPU timestamps, and
      checked error status are present.
- [ ] AC/High Power/thermal/frequency/power/process evidence is present.
- [ ] Cold and sustained ABBA samples agree within the preregistered noise band.

### End-to-end consequence

- [ ] Full CBv2 B=1/2/4 evidence exists, not only microbenchmarks.
- [ ] Correctness, decode, memory, uptime, and cancellation gates all ran.
- [ ] Both independent reviewers can reproduce the arithmetic and artifact
      provenance from committed source.

Until those boxes pass, the only defensible conclusion is:

> The current MLX non-NAX Steel implementation, the tested wider scheduler
> geometry, a persistent BF16 expert cache, and an FP16 input-only variant do
> not provide 2.5×. Whether an exact mixed-input/packed TensorOps projection
> path plus aggregate B=2/B=4 execution can reach the program's primary target
> remains experimentally open.
