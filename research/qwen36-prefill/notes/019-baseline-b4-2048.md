# 019 — Official B=4 2048-token burst baseline

Status: kept (measurement)

JSON: `artifacts/baseline-arrival-2048.json`
Harness: 0.8.10 `--arrival-invariance`, prompt 2048, decode 2, 2 iters,
`DARKBLOOM_ARRIVAL_TOLERANCE_MS=20`, High Power, contiguous.

## Burst (the goal metric)

| iter | makespan | 4× TTFT (all equal) | agg prefill tok/s (4×2048 / TTFT) |
|---:|---:|---:|---:|
| 1 | 4846 ms | 4827 ms | **1,698** |
| 2 | 5064 ms | 5044 ms | **1,624** |
| **median** | **4955 ms** | **4936 ms** | **1,661** |

B=1 2048 median = 1,669 tok/s. **B=4 / B=1 = 0.995×.**

All four TTFTs match to <0.02 ms. Interleave is fair and
makespan-pessimal, as `notes/014` predicted.

Log-line `aggregate ~200 tok/s` is **decode** TPS. Ignore it.

## Stagger (policy evidence, not the metric)

`stagger-25ms` i=1 first-row TTFT **1223 ms** = B=1 2048 exactly
(solo stripe armed while the first request is alone). Later rows
~5.1 s. Mean TTFT changes with arrival; **aggregate does not beat
solo.**

## Implication

H0 is closed. Packing is on. Tokens per tile-hit weight stream stay
2048 (`notes/018`). 2.5× aggregate = 4,153 tok/s at this cell
(1,661 × 2.5).
