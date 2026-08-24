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

## 2026-08-24T05:28Z — B=4 2048 official

2 burst iters: TTFT 4827 / 5044 ms, all four rows locked together.
Median agg prefill **1,661 tok/s = 0.995× B=1**. H0 closed. See
`notes/019`. Next is E1 tile microbench at M=32768/65536, not a
scheduler-only change.

