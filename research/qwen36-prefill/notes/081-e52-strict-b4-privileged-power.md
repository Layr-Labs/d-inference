# 081 — E52 strict B4 runs at maximum clock and high power

Status: **measured; downclock/thermal/command-feed lanes closed**

## Question

Note 048 found 98.69% GPU duty but a qualitative Metal trace label reporting
61.15% `Medium` performance state at B4. Unprivileged tooling could not map
that enum to live frequency or power.

E52 runs privileged:

```text
powermetrics --samplers gpu_power -i 100 -n 1800
```

across the same strict cache-free B4×8K arrival benchmark. The benchmark's
burst remains valid at 1,542.3 aggregate prefill tok/s and 0.02 ms arrival
error. The tolerance was widened only so `powermetrics` host overhead would not
abort later staggered patterns.

## Result

| Counter, active-residency ≥90% | Value |
|---|---:|
| Samples | 1,620 |
| Active residency median | 100.0% |
| GPU frequency median | **1,374 MHz** |
| Frequency p10 / p90 | 1,371 / 1,378 MHz |
| Samples ≥1,370 MHz | **94.81%** |
| GPU power median | **47.39 W** |
| Power p10 / p90 | 44.18 / 50.52 W |
| Maximum observed power | 51.85 W |

The device's published top state in the same stream is 1,380 MHz. B4 strict
prefill therefore sustains near-maximum clock and high power. The trace's
`Medium` enum is not evidence of downclocking.

## Decision

The following mechanisms cannot supply the missing multiplier:

- CPU/command submission overlap (≤1.324% ideal bound from note 048);
- thermal recovery (thermal state stayed nominal and throughput did not fade);
- forcing a higher GPU clock (the workload already runs at ~1.374 GHz median).

Any remaining strict-path headroom is kernel-internal: arithmetic issue,
register/occupancy pressure, memory/cache behavior, or dependency stalls.
Only a labeled device-scope Xcode GPU Shader Profiler capture can distinguish
those. Do not spend another cycle on scheduling or power posture.

Artifacts:

- `artifacts/e52-strict-b4-power-summary.txt`
- `artifacts/e52-strict-b4-powermetrics.txt.gz`
- `artifacts/e52-strict-b4.json.gz`
- `artifacts/e52-strict-b4.stderr.txt`
