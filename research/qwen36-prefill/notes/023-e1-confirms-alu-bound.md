# 023 — E1 QMM TFLOPS confirm note 011: packing is not 2.5×

Status: measured + derived. Updates the rank-2 expectation.

## Isolated gather-QMM TFLOPS (this Mac, E1, High Power)

Fused gate_up geometry `M × 1024 × 2048`, FLOPs = `2 M N K`.

| tokens | M | tile ms | TFLOPS |
|---:|---:|---:|---:|
| 2048 | 16384 | 6.541 | 10.5 |
| 4096 | 32768 | 12.516 | 11.0 |
| 8192 | 65536 | 24.486 | 11.2 |

Time is linear in M. Tile vs legacy at these M is 1.04–1.07×
(`notes/021`). That is the same ALU roof [011](notes/011-explorer-moe-gdn.md)
derived from the B=1 curve (8.6–9.1 TFLOPS end-to-end). Isolated QMM is
a bit faster than the full stack, as it should be. It is **not** 24 TFLOPS.

## What this does to the queue

[012](notes/012-synthesizer-queue.md) rank 2 expected `[4,2048]` at
2.0–3.5× and set kill `<1.5×` / `<2.0×`. That kill would discard a
correct 1.1× result.

011's pre-registered prediction: one packed `[4,2048]` pass is
**1.08–1.25×** because the once-per-pass weight term is only 66 ms of a
4.9 s burst. E1 says the MoE QMM itself will not create the missing
1.3×.

E2 still runs. It is now a **test of 011**, not a hunt for 2.5× by
widening the cohort. If B=4 `[4,1024]` / `[4,2048]` land in 1.05–1.30×,
the packing lever is exhausted and 2.5× has to come from delivered QMM
efficiency (new kernel), not scheduler geometry.

B=1 2.5× stays illegal under this roof (011 §0.5).
