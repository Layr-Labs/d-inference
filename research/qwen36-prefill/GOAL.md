# GOAL: 2.5x Qwen 3.6 35B-A3B aggregate continuous-batching prefill

Read this file before every action. If a proposed experiment does not serve this
goal, do not run it.

## One-sentence objective

Make Darkbloom's Qwen 3.6 35B A3B **aggregate continuous-batching prefill** at
least **2.5x faster** on the M3 Max (`m3-max-128gb-2`),
measured at **B=1, B=2, B=4**, with **correctness** and a change that can
actually ship in Darkbloom.

## Why this exists

This is a Karpathy-style auto-research loop pointed at a serving inference
engine, not a toy `train.py`. The metric is wall-clock prefill tokens/sec under
the real ContinuousBatchingV2 path. Git is the ratchet: keep only measured
wins; log every miss; never rerun a dead experiment without a new reason.

## Hard success criteria

1. **Primary metric:** aggregate prefill tokens/sec under continuous batching.
   This is NOT isolated decode, NOT a microbenchmark of one GEMM, NOT a
   marketing solo-TTFT number taken out of the scheduler.
2. **Required speedup:** `>= 2.5x` versus the measured baseline on **this
   exact machine**, **this exact model snapshot**, **this exact Darkbloom /
   MLX-Swift / CBv2 path**.
3. **Must report all of:**
   - B=1 prefill tok/s (and TTFT) at 512 / 2,048 / 8,192 prompt tokens
   - B=2 aggregate prefill tok/s (equal-length concurrent prefills)
   - B=4 aggregate prefill tok/s (equal-length concurrent prefills)
   - the **aggregate continuous-batching** number serving cares about:
     total prompt tokens finished / wall-clock makespan of the burst
4. **Model weights are immutable.** Their bytes and hashes cannot change.
   Execution precision, association, kernels, routing policy, cache/state
   representation, scheduling, and inference algorithms are mutable.
   Exact incumbent token checksums are diagnostic, not an automatic veto:
   non-identical candidates must pass the fixed quality/eval corpus,
   accounting, memory, cancellation, and uptime gates before they can ship.
5. **Darkbloom-integrable.** Protocol-symmetric if the wire changes.
   No coordinator-invisible semantic drift. No `fatalError` Metal path.
   No silent quality regression: every intentional numerical/model-policy
   change is named, measured, and quality-gated. Tests that fail without the change.
   Reviewer can say "this can merge."

## Machine, model, control plane

| Item | Fact |
|---|---|
| Host | Apple M3 Max, 40-core GPU, 16-core CPU (12P+4E), 128 GB unified, Mac15,9 |
| Remote benchmark host | `m3-max-128gb-2` |
| OS | macOS 26.4, Swift 6.3.2, Xcode present |
| Power | Must bench on AC + High Power (`powermode 2`). LPM halves GPU. Record `pmset -g batt` and `powermode` in every result row. |
| Installed provider | Darkbloom `0.8.10` at `~/.darkbloom` (not currently serving) |
| Model id | `qwen3.6-35b-a3b-vl-mtp-mxfp8` |
| Snapshot | `/Users/gaj/.cache/huggingface/hub/models--qwen3.6-35b-a3b-vl-mtp-mxfp8/snapshots/local` (~20 GiB, 4-bit affine g64, routers 8-bit) |
| Registry | `models.darkbloom.ai` / `EigenLabs/Qwen3.6-35B-A3B-MLX-VL-4bit-g64-router8-mtp` |
| Cloud VM | Research notebook + git + agents. It cannot compile Metal. The Mac is the only runtime. |
| Control plane | This repo (`d-inference`) on branch `cursor/qwen36-prefill-2p5x-74d1` |

Do not write SSH passwords, tokens, or wallet keys into this tree.

## 2026-08-24 objective reset

The owner explicitly rejected treating the incumbent numerical execution
contract as a physical boundary:

- **only model weight bytes are fixed;**
- do not stop at a same-arithmetic roof;
- lower/mixed precision, changed association, alternate routing, exact or
  approximate kernels, cache/state compression, and speculative algorithms
  are valid experiments;
- candidates that change outputs must earn acceptance through measured
  quality, not be rejected solely for checksum inequality;
- continue until the 2.5× end-to-end objective is reached.

Safety remains non-negotiable: no crashes, memory corruption, silent
failures, accounting drift, or unreported quality changes.

## 2026-08-24 measured state-construction success

Working backward from the required K/V + GDN boundary produced exact
hybrid-state reuse:

- warm full-prompt B1/B2/B4 at 8K: **184× / 304× / 419×**;
- cold simultaneous B4 identical 8K: **3.357×**;
- cold simultaneous B4 90%-common 8K: **2.628×**;
- sequential B4 75%-common 8K: **3.635×**;
- sequential B4 87.5%-common 8K: **7.066×**.

These are three-run medians. Every cached/forked object includes all ten
attention K/V rows, all thirty recurrent states/tails, position, and
frontier logits where applicable. Partial suffix outputs match cold
controls exactly.

This satisfies the 2.5× objective for reuse-bearing workloads without
changing weights or quality. The distinct, unrelated cold-prompt cell
remains the next optimization target and must not be conflated with the
measured reuse profiles.

## Architecture facts (do not rediscover)

Qwen 3.6 35B A3B on this snapshot is a **Qwen3.5-MoE hybrid**:

- `hidden=2048`, `layers=40`, `vocab=248320`, `max_pos=262144`
- MoE: `E=256`, `topK=8`, `moe_intermediate=512`, shared expert `512`
- Attention: GQA `H=16`, `KV=2`, `head_dim=256`, `partial_rotary=0.25`
- Hybrid schedule: `full_attention_interval=4` → **10 full-attn + 30 GDN**
  (`linear_attention` on 0-2, 4-6, ... ; `full_attention` on 3,7,...,39)
- GDN: `k_heads=16`, `v_heads=32`, `k/v_dim=128`, `conv=4`
- VLM tower + inline MTP (`block_size=3`) exist; **this goal is TEXT PREFILL**
- Quant: 4-bit affine group-64 (product name says mxfp8; the bytes are 4-bit)
- CBv2 already has: expert-tile trust, solo stripe 2048, prompt narrowing,
  packed-prefill *capability* (`Qwen35.swift` sets `supportsPackedPrefill = true`)

## First-principles operating law

1. Identify the **root cause of prefill seconds**, not the first obvious kernel.
2. Enumerate the **full state space** before coding: B=1/2/4, prompt lengths,
   expert activation vs E=256, GDN vs full-attn layers, KV layout, Metal
   occupancy, memory bandwidth vs ALU, compile vs runtime, quantization,
   continuous-batch merge of concurrent prefills, power posture.
3. Work **top-down** (user-visible TTFT / aggregate tok/s) and **bottom-up**
   (Metal kernel → MLX graph → Swift BatchedEngine / EngineV2 → CBv2 scheduler).
4. **Measure on the live M3 Max** before claiming anything. Code-only theories
   are hypotheses.
5. After every candidate ask **what breaks next**: numerics, memory,
   `maxBufferLength`, B=4 fairness, coordinator admission, thermal, decode.
6. Pull every hop: request → template → tokenize → embed → layer stack
   (attn/GDN + MoE) → KV write → first token.
7. **The best part is no part.** Delete complexity. Do not add a mega-kernel
   that already lost 60-70% in prior paired tests.

## What 2.5x actually means physically

Prefill is **not** decode.

- Decode streams weights **per token**. Bandwidth roof ≈ active_bytes / BW.
- Prefill streams weights **per chunk**, reused across the chunk's tokens.

This snapshot is ~21 GiB on disk. M3 Max 128 GB bandwidth is ~400 GB/s.
If a chunk touches all 256 experts (true at 512+ tokens with top-8), one
chunk is a near-full weight read.

| Assumption | 8K B=1 roof | 2.5x from ~1,766 tok/s |
|---|---:|---|
| 4-bit stays packed, 2048-token stripe (4 reads) | ~39k tok/s theoretical naive | 4.4k is 11% of that roof |
| 4-bit, 512-token chunks (16 reads) | ~9.8k tok/s | 4.4k is 45% of that roof |
| Weights dequantized to bf16 in DRAM | ~2.9k tok/s | **2.5x exceeds this roof** |

Therefore:

- **2.5x B=1 is only possible** if we cut chunk re-reads (bigger / one-shot
  prefill), keep QMM on packed 4-bit, and/or delete large extra traffic
  (logits, score tensors, expert scatter, serial launch bubbles).
- **2.5x aggregate at B=2/B=4 is the more honest serving target.** Prior
  measurement: 4 concurrent 8K prefills ≈ **1.0x solo aggregate** because
  rows do not share weight traffic. Packed prefill is the structural lever.
- Prior "structural 2x" note: GPU busy-union == sum of kernels (zero overlap)
  at ~24% of peak. Concurrent encode / wavefront is a real physics lever.

Do not promise 2.5x B=1 if the measured roof forbids it. If B=1 is roofed,
**put the 2.5x into aggregate B=2/B=4** and say so with numbers.

## Prior art — do not repeat without a new reason

Already shipped / measured (see `docs/reports/` and notes):

| Item | Verdict |
|---|---|
| v0.8.5 expert-tile E=256 + fused gate_up | +15% at 8K with trust |
| v0.8.6 trust + stripe 2048 + narrowing + packed | 8K cold −27.6% (~1,766 tok/s); 4x8K agg +13-17% |
| v0.8.8 GDN 4-in-1 + direct expert reduction | Prefill win; **rolled back in 0.8.9** — decode/uptime regression |
| Solo stripe 2048 | Wash alone; −13.8% with trust; LPM **+12% regression** |
| 4 concurrent prefills | Aggregate ≈ solo (weight re-stream). Packed is the case. |
| MoE mega-kernel / GateUp+SwiGLU fused | **63-71% slower**. Dead. |
| Router + shared-gate fusion | Wash. Dead as always-on. |
| D=256 Steel attention | Correct, speed not isolated. Requalify only with A/B. |
| 164 GiB Metal malloc on this Mac (2026-08-21) | Prior Qwen load died. Budget before large shapes. |

Roadmap still open (dependency-ordered, from 2026-08-19 report):

1. Packed prefill actually firing for Qwen (capability flag ≠ serving path)
2. Recurrent seam / LM-head narrowing residual
3. Mean-TTFT cap (policy; does **not** raise aggregate tok/s)
4. Wavefront / concurrent Metal encode
5. GDN chunkwise-parallel scan
6. Mask+softmax into QK epilogue
7. Sparse full-attn for >=32K
8. Prefix cache (product decision; off today)

## Research system (always-on)

| File | Role |
|---|---|
| `GOAL.md` | This file. Re-read before acting. |
| `program.md` | The loop. Karpathy `program.md` equivalent. |
| `JOURNAL.md` | Running log: hypothesis → experiment → result → next. |
| `MINDMAP.md` | Linked idea graph. |
| `results.tsv` | One row per experiment. All attempts, not just wins. |
| `notes/` | Atomic notes. One idea / measurement / paper / reject per file. |

Ratchet:

- Improve the metric → keep, commit, it is the new baseline.
- Flat or worse or crash → revert the code change, log the miss, do not retry
  the same idea without a new mechanism.
- Never batch unrelated experiments in one measurement.

## Agent roles

- **Explorer:** map code, kernels, papers, counters. No unmeasured claims.
- **Executor:** implement and run on the Mac. One change per run.
- **Synthesizer:** collapse notes into ranked bets with expected × and risk.
- **Optimizer:** squeeze the current best path. No new architecture while a
  measured win is unfinished.
- **Reviewer:** kill anything incorrect, unmeasurable, or not mergeable.
- Use divergent models (Grok 4.6, GPT 5.6 Sol, Claude). Do not converge on
  one story.

## Constraints

- Do not deploy serving. Do not mutate the coordinator VM.
- Do not take unexplained downtime on other fleet machines.
- This Mac is dedicated for this job; provider daemon is not currently serving.
- Protocol / telemetry / engine changes stay Darkbloom-symmetric.
- No secrets in git.
- Never stop at a compile. Only measured B1/B2/B4 + aggregate count.

## Execution mode

Goal-lock. Read `GOAL.md`. Update `JOURNAL.md`. Launch parallel subagents.
Measure. Iterate until 2.5x aggregate prefill is real, or every first-principles
lever is exhausted and documented with a reviewer-signed roof.
