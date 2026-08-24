# 082 — Short-prompt cold gap remains after E51

Status: **measured; B1×512/2K and B2/B4×512 remain below 2.5×**

The quality-passing suffix192 + top-k4 state river solves long cold prefill but
not the complete short matrix:

| Cell | Candidate tok/s | Speedup |
|---|---:|---:|
| B1×512 | 2,213.1 | 1.543× |
| B2×512 | 2,741.9 | 1.992× |
| B4×512 | 3,057.1 | 2.145× |
| B1×2K | 3,931.8 | 2.352× |
| B2×2K | 4,268.3 | 2.699× |
| B4×2K | 4,468.2 | 2.635× |

## B1×512 bounded suffix sweep

| Profile | tok/s | Speedup | Quality |
|---|---:|---:|---|
| suffix192 + top-k4 | 2,213.1 | 1.543× | PASS, 96.44% |
| suffix128 + top-k8 | 2,197.4 | 1.532× | FAIL, 94.67%, one fatal |
| suffix128 + top-k4 | 2,607.0 | 1.817× | not advanced; top-k4 cannot supply the missing 1.38× |
| suffix1 + top-k4 | 4,095.1 | 2.854× | known unusable state-river quality |

The quality reserve is not the only cost: reducing 192 to 128 full-depth rows
barely changes top-k8 B1 throughput. Artifact construction across 36 skipped
layers remains underfilled at M=512. The speed ceiling proves enough arithmetic
can be deleted, but measured quality proves that deletion is not usable.

## Closed adjacent hypotheses

- activation-subspace residual contraction: 0/20 real-capture profiles pass
  (note 079 in the activation branch);
- scheduler/command overlap: ≤1.49% ideal gain (note 048);
- clock/thermal policy: strict B4 sustains 1,374 MHz and 47.39 W (note 081);
- strict MPP/retile/precision probes: far below the required inclusive lane.

## Remaining mechanism

Short B1 is dominated by small-M kernel efficiency and state-producing
projections. The next evidence must come from a labeled GPU Shader Profiler
capture identifying issue, occupancy, bandwidth, or dependency stalls. A
further blind state/token deletion profile is not justified without a new
quality-preserving reconstruction mechanism.

Artifacts:

- `artifacts/e53-suffix128-topk8-b1-512.json.gz`
- `artifacts/e53-suffix128-topk4-b1-512.json.gz`
- `artifacts/e53-suffix1-topk4-b1-512.json.gz`
- `artifacts/e51-suffix192-topk4-b2-512.json.gz`
- `artifacts/e51-suffix192-topk4-b2-2048.json.gz`
- `artifacts/e51-suffix192-topk4-b4-512.json.gz`
