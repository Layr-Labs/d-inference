# 038 — Complete schema-6 baseline matrix (B=1/2/4 × 512/2K/8K)

Status: **binding baseline**

One binary SHA:
`5e1e3110871dabb3c672de788c4864bfdeeecd65110391fb98cfe08bac96614b`.
All runs used the same model, contiguous CBv2, default geometry, greedy
sampling, AC, and High Power. B=2/B=4 are three post-warmup burst
repetitions; B=1 is three fresh-engine scheduler-prefill repetitions.

## Aggregate prefill tok/s

| Prompt tokens/row | B=1 | B=2 | B=4 | B=4 / B=1 |
|---:|---:|---:|---:|---:|
| 512 | **1,434.6** | **1,620.2** | **1,712.6** | 1.194× |
| 2,048 | **1,671.4** | **1,621.4** | **1,694.4** | 1.014× |
| 8,192 | **1,546.8** | **1,500.7** | **1,557.4** | 1.007× |

B=1 TTFT medians: 356.2 / 1,224.7 / 5,295.6 ms.

## B=4 binding 2.5× bars

| Prompt | Baseline | Required tok/s |
|---:|---:|---:|
| 512 | 1,712.6 | 4,281.5 |
| 2,048 | 1,694.4 | 4,236.0 |
| 8,192 | 1,557.4 | **3,893.5** |

The program primary is B=4×8K. B=1/B=2 are disclosure and
non-regression gates unless the owner selects the stronger interpretation
that B=2 must also reach 2.5×.

## Artifacts

- `artifacts/baseline-v6-b1-curve.{json,meta}`
- `artifacts/baseline-rebuilt-b2-512.{json,meta}`
- `artifacts/baseline-v6-b2-2048.{json,meta}`
- `artifacts/baseline-rebuilt-b2-8192.{json,meta}`
- `artifacts/baseline-rebuilt-b4-512.{json,meta}`
- `artifacts/baseline-v6-b4-2048.{json,meta}`
- `artifacts/baseline-rebuilt-b4-8192.{json,meta}`

All B=2/B=4 row checksums were stable across repetitions. Prompt rows
are intentionally different, so checksums differ across rows and batch
sizes where finite-precision packed geometry differs.
