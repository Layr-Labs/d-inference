# JOURNAL

Auto-research log. Newest entry at the bottom. One experiment per
heading. Never delete a miss.

## 2026-08-24T05:16Z — engagement

User granted Tailscale access to `m3-max-128gb-2` (`100.75.135.42`),
user `gaj`. Job: 2.5x Qwen 3.6 35B A3B aggregate CBv2 prefill, B=1/2/4.

## 2026-08-24T05:17Z — machine recon

- Tailscale connected as `cursor-darkbloom-74d1`.
- SSH password auth works. Host: `gajs-MacBook-Pro-8.local`, M3 Max
  40-core GPU, 128 GB, macOS 26.4, Swift 6.3.2, Xcode present.
- AC power, battery 100%, `powermode=0` (automatic) — **not yet High
  Power**. Must flip to 2 before any decision-grade number.
- Darkbloom `0.8.10` installed at `~/.darkbloom`. Provider daemon is
  **not running** (stale `daemon-state.json` claimed gemma-4 serving).
  Only `io.darkbloom.fan-helper` is live. Safe to take the GPU.
- Model present: `~/.cache/huggingface/hub/models--qwen3.6-35b-a3b-vl-mtp-mxfp8/snapshots/local` (20 GiB).
  Config is `qwen3_5_moe` / 4-bit affine g64, **not** literal mxfp8.
  40 layers, E=256 top-8, hidden 2048, hybrid 30 GDN + 10 full-attn,
  vocab 248320, MTP block 3, VLM tower present.
- No source checkout on the Mac. Cloud workspace had empty mlx
  submodules; `libs/mlx-swift-lm` now initialized at `ab73a827`.
- Prior local log: 2026-08-21 Qwen load `fatalError` allocating
  164,783,923,200 bytes > 86,586,540,032 `maxBufferLength`. Hazard
  for naive large-shape benches.

## 2026-08-24T05:20Z — first-principles read of prior art

Read `docs/reports/2026-08-19-solo-prefill-stripe-experiment.md` and
`2026-08-21-qwen-prefill-retained-optimizations.md`.

Key physics already measured on a **different** machine (M4 Max):

- 4 concurrent 8K prefills ≈ 1.0x solo aggregate (weight re-stream).
- Stripe 2048 + trust ≈ −13.8% TTFT at 8K; stripe alone is a wash;
  LPM stripe regresses +12%.
- Mega-kernel / fused GateUp+SwiGLU: 63-71% slower. Dead.
- v0.8.8 GDN fusion + direct expert reduction: prefill win, decode
  regression, rolled back in 0.8.9. Do not silently re-enable.

Cloud `ProviderCore.version` is `0.8.10` — same as the Mac binary.
0.8.6 already claims ~1,766 tok/s 8K cold and +13-17% 4x8K aggregate
vs 0.8.5. **2.5x from that is ~4,415 tok/s aggregate.** Roofline
note written in GOAL.md: B=1 2.5x may be physically illegal if
weights dequant to bf16; B=4 packed is the plausible 2.5x.

## 2026-08-24T05:25Z — research system standing up

Created `GOAL.md`, `program.md`, `MINDMAP.md`, `notes/`, `results.tsv`.
Branch: `cursor/qwen36-prefill-2p5x-74d1`.

Next:

1. Dump High Power, run **baseline** on installed 0.8.10
   (`--scheduler-prefill` 512/2048/8192 and `--arrival-invariance`
   B=2/B=4) before any code change.
2. Parallel explorers on CBv2 packed-prefill path: does Qwen's
   `supportsPackedPrefill = true` actually fire in EngineLoopV2
   for text bursts, or is the 4x8K ≈ 1x number still live?
3. Init `libs/mlx-swift` so we can compile on the Mac.
4. Do not touch mega-kernels. First bets: packed firing, chunk
   policy, traffic deletion, concurrent encode.

## 2026-08-24T05:30Z — hypothesis H0 (untested)

**H0:** On this M3 Max, B=4 equal-length text prefills still do not
share expert-weight traffic, so aggregate tok/s ≈ B=1. If packed
prefill is actually off or falling back to per-row forwards, turning
it on is the 2.5x lever. If it is already on, 2.5x must come from
bytes/chunk (stripe, 4-bit residency, kernel overlap), not batching.

This is the first experiment. No code change until H0 is measured.

## 2026-08-24T05:22Z — canary PASS

Installed 0.8.10, High Power, AC, contiguous, L=512 B=1:

- TTFT 420.1 ms
- 0.822 ms/token
- **1,217 tok/s**
- stripe cfg 2048 (inactive at L=512)
- 164 GiB fatal did **not** reproduce on this shape

See `notes/007-canary-b1-512.md`. Full baseline (512/2048/8192 × 3 +
4-wide arrival 2048/8192) started at 05:24Z as `run_baseline.sh`.

## 2026-08-24T05:24Z — code read while canary ran

Packed path exists (`EngineLoopV2` ~1692–1807). Recurrent Qwen
skips packing when `positionState != nil`. MoE flattens packed
`[B,L]` into one expert-tile (`notes/008`). H0 now has three
outcomes, not two: packing-off / packing-on-weight-bound /
packing-on-compute-bound. Arrival aggregate vs 4×B=1 distinguishes
the last two only if we also know `packedPrefillActivity`.

## 2026-08-24T05:23Z — B=1 curve locked

Medians (3 iters, High Power): **512 → 1,435 tok/s; 2048 → 1,669;
8192 → 1,555**. 8K ≈ 4 × 2048 streams (+7.4%). See `notes/009`.

## 2026-08-24T05:24Z — H0 resolved (pending 2nd burst iter)

4×2048 burst makespan 4,926 ms ⇒ **1,663 agg prefill tok/s = 1.00×
B=1**. Packing is on (time matches 4 packed `[4,512]` steps, not 16
solo 512s). The 2048 step budget splits a burst into 512-token
chunks, so tokens-per-weight-stream stays 2048. That is why
aggregate cannot beat solo.

Next experiment (not started): raise burst chunk and
`maxBatchedTokensPerStep` so one step can be packed `[4,2048]`.
Reviewer must bless expert-tile assignment cap and memory.

## 2026-08-24T05:26Z — the roof is the tile allowlist

`assignments ∈ {4096,8192,16384}` is a CPU closed set
(`notes/018`). Packed `[4,512]` is already at 16384. Raising the
scheduler budget without a new M falls to legacy gather. 2.5× means
M=32768 (2×) + another lever, or M=65536 (4×).

Arrival harness v1 died on stagger-25ms (10 ms > 5 ms tolerance).
Burst i=1 is in the log only. Rerunning with
`DARKBLOOM_ARRIVAL_TOLERANCE_MS=20`.

## 2026-08-24T05:32Z — papers explorer (015)

Orca selective-batching transfers; expert parallelism does not.
Packed `[B,L]` flattening is a diagnosis first, not a new kernel.
Confirms E1: more tokens per already-loaded expert tile. Sparse
attention stays quality-gated. No implementation from this note.

## 2026-08-24T05:28Z — B=4 2048 official

2 burst iters: TTFT 4827 / 5044 ms, all four rows locked together.
Median agg prefill **1,661 tok/s = 0.995× B=1**. H0 closed. See
`notes/019`. Next is E1 tile microbench at M=32768/65536, not a
scheduler-only change.

## 2026-08-24T05:35Z — E1 allowlist patch (unmeasured)

Opened CPU allowlist to `{4096, 8192, 16384, 32768, 65536}` via
`gemma4_expert_qmm_assignment_count_ok`. Host classifier smoke PASS
on the cloud VM. Metal kernel unchanged (M already a runtime buffer).
No CBv2 budget raise.

Next: compile mlx-swift tests on the M3 Max and A/B tile vs legacy
at M=16384 (control), 32768, 65536. Keep only if tile ≥1.3× legacy
and numerics hold. See `notes/020`.

## 2026-08-24T05:40Z — E1 measured

Correctness PASS (new M included). Tile HIT 25/25 at M=32768 and
65536 on the installed 0.8.10 metallib. Tile/legacy at T4096 = 1.06×,
T8192 = 1.07×. **Missed the 1.3× kernel-only keep bar.** Isolated QMM
time is linear in M, so this kernel is not the 2× weight-stream win.

Allowlist stays (correct, hits, not slower at E2 shapes). CBv2 tok/s
unchanged until E2 raises chunk/budget on a binary that contains this
gate. See `notes/021`.

## 2026-08-24T05:48Z — explorers closed; 011 vs 012

All research explorers finished. Packed already fires (010/014). Metal
has one GPU stream and no overlap lever we can turn from Swift (013).
Reviewer still requires B=2 harness + decode A/B (016; harness is
committed, binary rebuilding).

011 decomposes the B=1 curve as `66.2 ms + 0.566 ms·N` and predicts
`[4,2048]` at **1.08–1.25×**, not 012's 2.0–3.5×. E1 isolated QMM is
**10.5–11.2 TFLOPS** and linear in M (`notes/023`). That confirms the
ALU roof. E2 is now a test of 011, not a 2.5× attempt by widening the
cohort. If it lands ~1.1×, escalate: 2.5× needs a faster gathered
4-bit QMM, not a bigger step budget.

## 2026-08-24T05:55Z — E2 wide cohort dead

Rebuilt binary control (B=4×2,048, chunk 512 / budget 2,048) reproduced
at **1,641.9 tok/s**, 1.1% from the locked baseline. E2 `[4,1024]`
(chunk 1,024 / budget 4,096) produced **1,698.4 tok/s = 1.034×** the
adjacent control.

Worse: greedy checksums changed on rows 0 and 3. Stable within each arm,
different across arms. Automatic correctness veto. Do not run
`[4,2048]`; same mechanism, larger M. See `notes/027`.

The new harness also measured the missing B=2 default baseline:
**1,626.4 tok/s**, 2,517.2 ms prefill makespan.

Next: remove the now-dead serving chunk/budget knobs while retaining the
B=1/B=2/B=4 measurement harness. Move exclusively to arithmetic-equivalent
gathered W4 QMM kernel experiments at the existing geometry.

## 2026-08-24T06:04Z — E3 dense arithmetic roof

Measured the exact same quantized weights through three paths at M=16,384:

- W4 sorted gather: gate_up **10.89 TFLOPS**, down **10.22**;
- dequantized BF16 sorted gather: **10.93 / 8.37**;
- illegal one-matrix BF16 GEMM roof: **12.30 / 11.60**.

Dequantization is free relative to the MMA and a 60–75 GiB BF16 cache
cannot pay. Even deleting expert grouping gains only 1.13×. If QMM is
93% of prefill, the impossible bound “monolithic QMM + all other work
free” is only ~1.22×. See `notes/028`.

The 2.5× target at the same exact operation count would need ~27 TFLOPS,
over 2× the measured monolithic M3 roof. Remaining BM/BN/BK experiments
can recover single-digit/low-teens efficiency; they cannot close 2.5×.

## 2026-08-24T06:07Z — E4 FP16 lane dead

Repeated the exact expert and monolithic roofs with FP16. Gate W4 moved
10.89 → 11.23 TFLOPS (1.03×), down 10.16 → 10.78 (1.06×); dense gather
and monolithic GEMM were flat. M3 exposes no 2× FP16 path to these
Steel kernels. An invasive dtype change is dead before full-model
checksum risk. See `notes/029`.

## 2026-08-24T06:14Z — E5 half accumulation correctness veto

Steel's hidden FP16-throughput loophole was tested directly: expert MMA
accumulator `float` → `half`, all else fixed. Metallib compiled, then
`SortedGatherQuantizedMMTests` produced **30 failures**, with gate_up
errors up to 2,368 and down up to 96 across every M/histogram class.

Per preregistration, no timing run. Patch reversed; canonical source and
baseline metallib restored. The nominal 2× half-accumulator lane cannot
preserve the model contract. See `notes/033`.

## 2026-08-24T06:20Z — E6 portable MPP/NAX fallback veto

Forced MLX's existing Metal 4 MPP/NAX kernels past the generation-17
gate on this generation-15 M3. The API and shader fallback executed,
but `SortedGatherQuantizedMMTests` failed **11** cases: ordinary QMM,
Qwen random gate/down, and sorted boundaries (max errors 3–14).

No timing run. Override reversed and test host rebuilt. This closes the
shortcut “reuse existing NAX on M3”; a brand-new byte-identical MPP
dequant kernel remains conceptually open. See `notes/034`.

## 2026-08-24T06:27Z — E7 upstream FP32 dequantization dead

Selective upstream MLX #4241 passed its adversarial `-109.5` regression
and all sorted/Qwen correctness tests. On source-matched M3 A/B:

- gate_up 6.3125 → 6.1445 ms (1.027×);
- down 3.3834 → 3.2718 ms (1.034×);
- combined routed projection: **1.030×**.

Below the preregistered 1.05× continuation bar, so no full-model run.
Patches reversed and baseline source/metallib/host restored. See
`notes/035`.

## 2026-08-24T06:32Z — E8 strict MPP Candidate A veto

E6 used MLX NAX's `relaxed_precision=true`. E8 changed the portable MPP
descriptor to strict FP32 destination/accumulation (`false`) while
keeping incumbent BF16 operands. It produced the **same 11 failures and
same errors** as E6.

The M3 optimized-shader mismatch is reduction/tile behavior, not relaxed
precision. No timing. Patch reversed and baseline restored. Candidate A
from hostile review 032 is closed through MLX's available MPP primitive.
See `notes/036`.

## 2026-08-24T06:39Z — primary 8K baselines locked

Three schema-6 burst repetitions, default geometry, AC/High Power:

- B=2×8,192: **1,500.7 tok/s**, 10.9165 s median makespan;
- B=4×8,192: **1,557.4 tok/s**, 21.0375 s median makespan.

Checksums stable. The binding B=4 2.5× bar is **3,893.5 tok/s** or
**8.4150 s**. B=4 still equals B=1 8K within noise. See `notes/037`.

## 2026-08-24T06:47Z — complete baseline matrix

One schema-6 binary, three repetitions:

| L | B=1 | B=2 | B=4 |
|---:|---:|---:|---:|
| 512 | 1,434.6 | 1,620.2 | 1,712.6 |
| 2,048 | 1,671.4 | 1,621.4 | 1,694.4 |
| 8,192 | 1,546.8 | 1,500.7 | 1,557.4 |

B=1 TTFT 356.2 / 1,224.7 / 5,295.6 ms. All required denominators are
now first-class harness artifacts. See `notes/038`.

## 2026-08-24T06:58Z — E9 exact BK64 dead

BK64 passed all 10 sorted/Qwen correctness tests and hit 25/25 with zero
fallbacks. Separate-process BK32/BK64 A/B:

- T2048 gate 0.999×, down 1.002×;
- T4096 gate **1.008×**, down 1.002×.

Halving outer barriers does not move the FP32 SIMD MMA ceiling. No
full-model run; baseline restored. See `notes/039`.

## 2026-08-24T07:04Z — E10 BM64×BN64 dead

Correctness 10/10; hits 25/25. At M≥16K, BM64×BN64 gained only
1.033–1.079×. At T1024 (32 rows/expert) it regressed to 0.57–0.59× due
to tile waste. No cell approached 1.30×.

Per-shape guards cannot turn a low-single-digit kernel cleanup into the
2.5× objective. No full-model run; baseline restored. See `notes/040`.

## 2026-08-24T07:05Z — E11 native uint4 MPP veto

Standalone Metal 4 `bfloat × uint4b_format → float` compiled, linked,
and executed on M3. Unsigned nibble mapping passed 512/512.

The affine factorization candidate moved the incumbent per-weight BF16
rounding boundary. A two-term adversary expected 0.125 and produced
-1.5273438 (max error 1.65234375; BF16 output error 1.65625), failing
512/512 outputs. Timing skipped by preregistered gate.

Candidate B is numerically illegal. Existing probe and machine-readable
evidence are in `probes/e9-native-uint4` and note 041.

## 2026-08-24T07:09Z — E12 MPP reduction path survives

Reproduced the fixed-shape Metal 4 probe on M3:

- static K=8 descriptor: compiler rejects (K dynamic or multiple of 16);
- supported static K16 cooperative load/store: bit-identical to two
  incumbent Steel K8 calls across all fixtures;
- dynamic K8 twice and explicit-add variants: unchanged QMM/Qwen
  tolerances (mixed-exponent BF16 output bit-identical);
- MLX NAX manual register mapping: catastrophic errors.

E6/E8 failed because MLX's NAX register-layout assumption is invalid on
the M3 fallback, not because MPP arithmetic is inherently incompatible.
Candidate A reopens only through supported cooperative load/store.
Timing is next; no serving integration yet. See `notes/042`.

## 2026-08-24T07:14Z — E13 strict MPP hard roof

Supported, bit-identical BF16×BF16→FP32 MPP versus Steel, 17.18 GFLOP
per dispatch, 15 GPU-timestamped samples:

- Steel K8×2: **13.68 TFLOPS**;
- static K16 MPP: **13.72 TFLOPS** (1.003×);
- dynamic K8 MPP: **3.35 TFLOPS**.

The note-026 continuation threshold was ≥22 TFLOPS. If all projections
share this schedule's 13.72 ceiling, B=4×8K linear work alone needs
159.692/13.72 = **11.64 s**, above the entire 2.5× target of **8.415 s**.

This closes the tested M16×N32 schedule, not every MPP tile/scope. Final
physical sign-off requires the bounded sweep and counter/structure
evidence requested by the hostile reviewer. See `notes/043`.

## 2026-08-24T07:19Z — E14/E15 full-shape MPP gates

Two independent probes expanded E13:

- E14, M=2,048 over 99.9966% of the real linear-shape ledger:
  supported static K16 MPP **12.6478 TFLOPS weighted**, Steel 11.0401;
  all 37,289,984 outputs FP32 bit-identical.
- E15, threshold `[4,2048]` row geometry including routed M=65,536:
  static K16 12.0193, Steel 11.9916, dynamic K8 **3.1579 TFLOPS**.
  Dynamic/static explicit accumulation also fails the long-K
  mixed-exponent 1e-3 gate.

Both are far below ≥22 TFLOPS. Full raw samples, GPU timestamps,
thermal/power/process evidence, and source hashes are retained in notes
044/045. Remaining reviewer request: bounded MPP tile/scope sweep.

## 2026-08-24T08:09Z — E16 bounded MPP tile/scope sweep

Compiled 60 strict BF16×BF16→FP32 candidates across five output tiles,
K16/K32, 1/2/4-SIMD-group scopes, and cooperative/tensor inputs. The compiler
accepted 35 and rejected 25 with explicit descriptor/scope constraints. All 35
executable candidates were FP32 bit-identical to Steel across three complete
Qwen shapes (807,403,520 compared outputs).

Every valid candidate recorded 16 GPU-timestamped samples per shape under AC /
High Power. The bounded maximum median was **13.4182 TFLOPS** (M32×N32×K32,
single-SIMD-group cooperative inputs); the fastest individual sample was
13.4236. Both reach only 61.0% of the 22 TFLOPS continuation threshold.

Stop the enumerated matrix and do not integrate serving. This is a bounded
measured maximum, not an M3 hardware theorem; unenumerated schedules, counter
saturation, and the independent structure/routing closure remain outside this
experiment. See `notes/046`.

## 2026-08-24T08:19Z — owner resets numerical constraint

The owner explicitly rejected terminating at the incumbent numerical
contract. Model weight bytes are the only immutable object. Execution
precision, routing, layer/token policy, and cache/state algorithms may
change if quality and safety pass.

The objective remains 2.5×. Work now proceeds backwards from the actual
prefill product: 10-layer KV, 30-layer GDN terminal state/tails, frontier
logits. See `GOAL.md`, `program.md`, and `notes/055`.

## 2026-08-24T08:25Z — reopened precision paths still dead

- half accumulator: flat/slower at every serving cell;
- native uint4 affine factoring: 2.5878 TFLOPS;
- relaxed MPP: identical to strict (13.72 static, 3.35 dynamic).

Numerical freedom does not create hardware throughput in these M3
fallbacks. Move to work deletion/state construction. See `notes/056`.

## 2026-08-24T08:31Z — E20 adaptive MoE first large win

Default-off prefill-only expert policy, decode still top-8:

- B=4×2K: top-4 **1.213×**, top-1 **1.232×**;
- B=4×8K: top-4 **1.192×**, top-1 **1.379×**.

Top-4 retained all sampled two-token outputs at 2K/8K. Top-1 retained
all at 8K but changed 2/4 rows at 2K. Quality corpus is now binding;
checksum identity is diagnostic only under the owner override.

Top-1 primary rate is 2,147.5 tok/s. Another 1.813× is required.
Proceed to layer/token/state reduction and top-1 geometry. See `notes/057`.

## 2026-08-24T09:02Z — E21 immutable-weight structure scan

Scanned all 522 quantized tensors / 31,887 logical matrices / 35.5B
decoded values. Every matrix received an exact finite-field rank
certificate.

Exact model-wide rank/zero/duplicate work deletion is bounded at 24.31%
of linear MACs; routed aligned zero/tile removal is only 0.6775%;
duplicate experts = 0. Exact structure cannot provide the missing work
deletion. Approximate rank/routing/layer policies remain open under the
owner override. See `notes/058`.

## 2026-08-24T08:36Z — reverse-state dependency closure

Worked backward from the actual post-prefill product in `notes/050`:
10 complete attention K/V layers, 30 GDN terminal SSM/conv states, and one
frontier logit vector per row.

Exact dead hidden work exists only after layer 39 commits K/V, for a
**1.023–1.032x** ceiling. Making every GDN scan free is only **1.022x**;
quantized cache, WY scan, and projection fusion are supporting levers rather
than 2.5x candidates.

The direct cold-target construction is now explicit: make skipped GDN layers
state-only and skipped attention layers K/V-only. Keeping only layers
`0-3,36-39` fully active has an optimistic **2.59–2.74x** arithmetic profile
while still constructing every required artifact. Quality risk is severe and
binding.

Five experiments are ranked and gated in `notes/050`. Run the already-captured
default-off fixed-k seam first for information; the highest cold-target bet is
the artifact-only depth ladder. Exact prefix reuse can exceed 2.5x at >=60%
warm overlap but is deliberately excluded from the cold baseline claim.

## 2026-08-24T09:30Z — performance target crossed, quality rejects

Stride-2 prefill layers + top-k1 reaches:

- B1 512/2K/8K: **2.513× / 2.699× / 2.928×**;
- B2×8K: **2.951×**;
- B4×2K/8K: **2.713× / 2.744×**.

Natural-prompt quality collapses (1.04% token agreement, corruption).
Artifact-only eight/eleven-layer profiles also cross 2.5× but fail the
semantic gate. Top-k4 all-layer passes blind quality at 99.19% of
baseline but gives 1.192× on primary B4×8K. See notes 063–065.

## 2026-08-24T09:38Z — layer sensitivity mapped

Single four-layer artifact ablations under top-k4 range from 97.1%
token agreement (layers 28–31) to 2.6% (layers 0–3). First/final blocks
are critical; middle redundancy is nonuniform. Combining enough blocks
to reach 2.5× still collapses quality. See `notes/066`.

## 2026-08-24T09:48Z — exact full-prompt CBv2 boundary implemented

Implemented the default-off RAM proof for Qwen's complete hybrid boundary:
10 full-attention K/V rows and offsets, all 30 request-owned GDN conv/FP32
SSM states, scalar model position, and frontier logits. Qwen's historical
KV-only capability remains disabled; only the stronger exact-state cache
contract activates reuse.

Snapshots are storage-owning, cache entries are hard-budgeted/pinned LRU,
and every adopter receives independent attention/recurrent wrappers. The
first test tier covers exact B1 repeat, warm B2/B4 cohorts sharing one cold
prefill, cancellation isolation, identity scoping, accounting, and eviction.
The exact-only library and root wiring are preserved as ordered patches `060`
and `061` because this agent cannot push the nested library remote. See
`notes/060`.

## 2026-08-24T10:04Z — simultaneous exact prompt fork implemented

Added a separate default-off live-row experiment for overlapping Qwen
requests. CBv2 now detects compatible identical/shared token prefixes before
planning, runs the prefix on one leader, and forks finalized full-attention K/V
plus all recurrent owners before independent suffix/decode.

B2/B4 fixtures pin cold-control token checksums, exact saved token-cell
accounting, follower and leader cancellation, post-fork follower departure,
independent clone ownership, and zero terminal reservations. The prefill-work
ceiling is `B / [B - (B - 1)s]`; B4 reaches 2.5x at 80% common-prefix overlap
and approaches 4x for long identical prompts. See `notes/061`.

## 2026-08-24T11:33Z — real Qwen exact-prefix donation fixed

Default-off M3 instrumentation found the real-model donor reached every policy,
layout, and budget gate, then failed recurrent snapshot validation: quantized
embedding weights are packed `uint32`, but their output and all 30 conv tails
are bfloat16. The recurrent spec had mistaken storage dtype for activation
dtype.

The spec now mirrors MLX dequantization: affine uses its floating scales dtype,
MXFP4/MXFP8 use bfloat16 despite `uint8` scales, and ordinary embeddings retain
the weight dtype. A quantized-mode regression passes, as do all six exact
cache/engine tests and eight provider benchmark tests. The prompt-512 M3 run
now observes 75,371,520-byte donations and exact B1/B2/B4 hits with full output
equality; distinct-suffix partial-prefix arms remain misses. See `notes/060`
and `notes/062`.

## 2026-08-24T12:49Z — exact hybrid-state reuse measured

Warm full-prompt B1/B2/B4 speedups:

- 512: **15.3× / 23.8× / 33.6×**;
- 2K: **50.4× / 86.6× / 122.2×**;
- 8K: **186.8× / 320.2× / 402.9×**.

Every hit restores independent K/V, GDN state/tails, position, and
frontier logits. First-token parity is exact.

## 2026-08-24T12:58Z — exact cold prompt fork crosses primary

With no prior cache entry, one leader computes and forks state:

- B4 identical: **3.013× at 512**, **3.254× at 8K**;
- B4 90% common at 8K: **2.627×**;
- B4 75% common at 8K: 2.017×.

The 2.5× objective is reached through correct KV+GDN construction, not a
faster wrong kernel. Distinct cold prompts remain an active target;
partial durable-prefix reuse is next. See `notes/068`.

## 2026-08-24T13:36Z — 8K reuse medians locked

Three-run medians:

- warm exact B1/B2/B4: **184.4× / 304.1× / 419.3×**;
- cold B4 identical fork: **3.357×**;
- cold B4 90% common fork: **2.628×**;
- cold B4 75% common fork: 2.047×.

All state construction remains exact and request-owned. The measured
profiles clear 2.5× with substantial margin.

## 2026-08-24 — durable exact boundaries generalized

The default-off exact Qwen cache now snapshots every finalized whole-block
cold-prefill boundary, indexes model/policy/scope-bound token prefixes, and
returns the longest exact match to later sequential requests. Partial adopters
receive independent K/V and all recurrent owners at `M`, then execute their
distinct suffix normally; cached frontier logits remain exclusive to complete
prompt hits.

The regression matrix covers partial B1/B2/B4, suffix/decode parity against
cache-disabled controls, longest-match fallback, frontier upgrade, pin/LRU
accounting, and provider report/schema integration. The 8K benchmark's 75% and
90% corpus arms now target 6,144 and 7,168 saved tokens respectively while
retaining exact output equality. See `notes/069`.

## 2026-08-24T12:51Z — durable partial-prefix reuse measured

The M3 Max 8K corpus now records direct durable hits at every requested
overlap: 2,048 / 4,096 / 6,144 / 7,168 tokens for the 25/50/75/90% arms.
Warm makespan speedups are **1.32x / 1.89x / 3.59x / 7.04x** respectively.
All sixteen distinct-suffix rows match their cache-disabled generated token
sequences exactly; the 75% and 90% arms clear the 60% overlap target.

The inherited identical-B2 second-token batch-geometry variation from note 068
is unchanged and remains isolated from the new partial-prefix arms. The report
passes its draft-2020-12 schema and is preserved as
`artifacts/e37-partial-prefix-8192.json`.

## 2026-08-24T13:51Z — durable partial-prefix medians locked

Three-run 8K medians:

- 25% exact prefix: 1.295×;
- 50%: 1.874×;
- 75%: **3.635×**;
- 87.5% aligned from requested 90%: **7.066×**.

Every distinct-suffix row retains exact first/full-token and finish parity.
