# v0.8.0 PagedAttention — Live Gate Results

Measured on Apple M4 Max, 40 GPU cores, 128 GB, 546 GB/s.
Model: `mlx-community/gemma-4-26B-A4B-it-qat-4bit` (real weights, 15 GB, 3 shards).
Provider built `swift build -c release`. Medians of **5 repetitions** per point.

## G0b — Does batching pay end to end?

Bar: aggregate ≥ 1.07x of B=4, per-request decode ≥ 22 tok/s.

| B | contiguous agg | paged agg | paged/contig | contig per-req | paged per-req |
|--:|---:|---:|---:|---:|---:|
| 1 | 107.2 | 98.8 | 0.92x | 107.2 | 98.8 |
| 2 | 116.3 | 120.1 | 1.03x | 58.2 | 60.1 |
| 3 | 182.6 | 156.4 | 0.86x | 60.9 | 52.1 |
| 4 | 197.5 | 194.4 | 0.98x | 49.4 | 48.6 |
| 5 | 194.3 | 200.9 | 1.03x | 38.9 | 40.2 |
| 6 | 186.1 | 223.1 | **1.20x** | 31.0 | 37.2 |
| 7 | 199.7 | 222.7 | **1.12x** | 28.5 | 31.8 |
| 8 | 211.1 | 247.3 | **1.17x** | 26.4 | 30.9 |

**B=4 -> B=8 aggregate gain: contiguous 1.069x, paged 1.272x.**

### Verdict: PASS on paged, marginal on contiguous

Both backends clear the per-request floor at B=8 (26.4 and 30.9 tok/s vs a
22 tok/s bar, and far above the `EIGENINFERENCE_MIN_DECODE_TPS=15` production
floor).

The aggregate bar is where they separate. Contiguous gains **1.069x** from
B=4 to B=8 — it lands exactly ON the 1.07x bar, i.e. within noise of not
paying at all. Paged gains **1.272x**.

The migration plan modelled 1.26x for this step. That model is confirmed —
**but only for paged**. On contiguous the same step is worth essentially
nothing.

This is the plan's central claim, now measured rather than derived: *paged is
a batching enabler.* Its value is not a faster kernel — it is slightly
**slower** at B=1 (0.92x) and B=3 (0.86x) — it is that the batch curve keeps
climbing where contiguous flattens. The crossover is at B=5-6.

## Prefill (single sample, 1 iteration)

| tokens | contiguous | paged |
|--:|---:|---:|
| 512 | 990.1 tok/s | 1107.9 tok/s |
| 2048 | 759.0 tok/s | 710.2 tok/s |

Prefill is not a paged win and was never claimed to be — there is no paged
prefill kernel. These are within run-to-run noise of each other.

## G1 — Is paged sized correctly?

Bar: per-sequence paged KV <= contiguous at ctx {1k, 10k, 100k}; pool
footprint fits 36 GB boxes.

### Per-sequence KV, gemma-4 (25 sliding w=1024 + 5 full, fp16)

Derived from the LANDED ring geometry (`ringPageCount = 97 pages = 1,552
tokens`), cross-checked against `PagedKVPool.pageDemand`.

| ctx | contiguous | paged (ring 1,552) | ratio | paged + ring shrink | ratio |
|--:|--:|--:|--:|--:|--:|
| 1,024 | 0.273 GiB | 0.273 GiB | 1.00x | 0.273 GiB | 1.00x |
| 10,240 | 0.977 GiB | 1.077 GiB | **1.10x** | 0.980 GiB | 1.00x |
| 102,400 | 8.008 GiB | 8.109 GiB | 1.01x | 8.011 GiB | 1.00x |

### Verdict: MARGINAL FAIL at 10k, and the ring shrink is what fixes it

Paged overshoots contiguous by **10% at 10k context**. It is at parity at
1k (both under the window) and at 100k (the 5 full-attention layers
dominate and the sliding overshoot washes out). 10k is the worst case
because it is where the sliding ring's extra `maxPrefillChunk` of width is
largest relative to total KV.

The overshoot is exactly `ring - window = 1,552 - 1,024 = 528` tokens per
sliding layer. Shrinking the ring to `window + span` closes it to 1.00x at
every context.

**This promotes `gather(ring) ++ chunk` from an optimisation to a G1
blocker.** It also needs BOTH halves: the layer half is landed, but
row-level direct writers cannot re-gather post-write and need their own
answer.

### Measured, real weights, B=1

| prefill | contiguous | paged |
|--:|--:|--:|
| 1,024 | 1291.2 tok/s | 1299.4 tok/s |
| 8,192 | 861.1 tok/s | 910.1 tok/s |
| 32,768 | 354.3 tok/s | 371.6 tok/s |

Peak RSS at 32k: contiguous 14.914 GiB, paged 14.861 GiB.

Note paged is slightly FASTER at long prefill (+5.7% at 8k, +4.9% at 32k).
The migration plan predicted paged could not help prefill because there is
no paged prefill kernel — that was right about the kernel and wrong about
the outcome. The gain is query sub-blocking (WS-0.2p): paged previously
built one full `[l, kL]` score tensor and now blocks at q=128, which cuts
the score-tensor traffic contiguous had already avoided since #85.
