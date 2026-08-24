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

