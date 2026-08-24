# 018 — Expert-tile allowlist IS the aggregate roof

Status: active (code fact + Mac B=1/B=4 numbers agree)

## The closed set

`Gemma4ExpertQMMRoute` (name is historical; Qwen E=256 uses the same
gate) hits only when

```
assignments ∈ {4096, 8192, 16384}
```

Source: `libs/mlx-swift/Source/Cmlx/include-framework/mlx-backend-common-gemma4_expert_qmm.h:147-149`.

Qwen top-8 ⇒ tokens per tile-forward = assignments / 8:

| M | tokens / weight stream | How Darkbloom uses it |
|---:|---:|---|
| 4096 | 512 | plain chunk |
| 8192 | 1024 | unused today |
| **16384** | **2048** | solo stripe AND packed `[4,512]` |

Anything larger is `fallback_assignment_count` → **legacy gather**.
Contracts even document this: larger stripes "stay correct but fall
back off the tile route" (`CBv2Contracts.swift` ~700-703).

## Why B=4 aggregate == B=1

- Solo 2048: one tile-hit forward, 2048 tokens, ~1225 ms, 1,669 tok/s.
- Burst 4×2048: step budget 2048, chunk 512 → packed `[4,512]` = **also
  2048 tokens = 16384 assignments = tile-hit**. Four such steps.
  Makespan ~4× solo. Aggregate ~1,663 tok/s.

The scheduler did not leave packing on the table. It packed **up to
the tile allowlist** and stopped. Raising `prefillChunkSize` /
`maxBatchedTokensPerStep` without extending M **falls off the fast
route** and will likely regress.

## What 2.5× requires

2.5 × 2048 tokens/stream = **5120 tokens** = **40960 assignments**.
That value is not in the allowlist and is not a power of two.

Nearest legal extensions if we only add powers of two:

| New M | tokens/stream | × vs today | Burst shape example |
|---:|---:|---:|---|
| 32768 | 4096 | 2.00× | `[4,1024]` or `[2,2048]` |
| 65536 | 8192 | 4.00× | `[4,2048]` or `[1,8192]` |

2.5× is 32768 (2×) plus a second lever (overlap, GDN, fewer evals),
**or** 65536 if memory/occupancy holds.

## Kernel vs gate

The Metal builder (`build_sorted_expert_tiles_bm32`) takes `M` as a
runtime buffer and sizes descriptors as `M/32 + E - 1`. The allowlist
is a **CPU-side** closed set, not an obvious Metal hard cap. Host
must still allocate the descriptor buffer for the new max tiles
(1279 at M=32768, 2303 at M=65536 vs 767 at 16384).

Existing 0.8.10 metallib may already run larger M if the CPU gate
and descriptor alloc change — **or** it may have a hidden cap.
That is the first A/B: microbench `gatherQuantizedMM` at M=32768
with today's metallib vs legacy.

## Experiment E1 (next, after burst JSON)

1. Microbench tile vs legacy at M=16384 (control), 32768, 65536 on
   this Mac. Kill if tile is not ≥1.3× legacy at the new M.
2. If tile wins: extend allowlist + descriptor alloc; add
   `DARKBLOOM_CBV2_MAX_BATCHED_TOKENS` / chunk env; set burst
   `[4,1024]` or `[4,2048]`.
3. Full CBv2 A/B vs `notes/009` baseline. Decode A/B required
   (0.8.8 lesson). Reviewer veto if decode drops.

Do not raise scheduler budget before the microbench. That would
measure the known-slow fallback and poison the ratchet.
