# 058 — E21 exact full-weight structure audit

Status: **complete; exact shortcuts bounded, approximate policies remain open**

The streaming scanner read the immutable 20 GB snapshot directly:

| Coverage | Count |
|---|---:|
| quantized tensors | 522 |
| logical matrices | 31,887 |
| expert matrices | 31,488 |
| dense matrices | 399 |
| decoded values | 35,495,165,952 |

Every payload was hashed. BF16 affine values were decoded with the
root-pinned MLX arithmetic, and finite-field minors certified exact rank
lower bounds.

## Structure

```text
decoded zeros       4,567,901,228
zero rows                 118,658
zero columns                1,736
duplicate rows            117,886
duplicate columns         123,665
duplicate groups        3,806,046
duplicate experts               0
```

Only 841 of 138,652,672 aligned BN32×BK8 blocks are wholly zero.

## Exact work-deletion bound

- all 31,887 matrices received a finite-field certificate;
- model-wide MAC-weighted exact-rank deletion upper: **24.31%**;
- maximum dense-matrix deletion upper: 36.52%;
- worst top-8 routed-layer rank deletion upper: 24.46%;
- exact routed zero/tile removal: **0.6775%** of routed MACs;
- no duplicate whole experts.

Therefore no exact zero/duplicate/rank transform deletes the ≥39% linear
work needed by the prior strict-arithmetic program.

This is not a stop under the owner override. Approximate low rank,
adaptive experts, layer/token deletion, and changed state construction
are valid if quality passes.

Artifacts:

- `artifacts/e21-real-weight-audit-summary.{txt,json}`
- `artifacts/e21-real-weight-audit-result.txt`
- `artifacts/e21-real-weight-audit-manifest.json`
- `artifacts/e21-real-weight-audit-routed-tiles.json`
- `artifacts/e21-real-weight-audit-raw-results.tar.gz`
- `artifacts/e21-real-weight-audit-artifacts.sha256`
