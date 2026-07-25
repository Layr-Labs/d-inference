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
