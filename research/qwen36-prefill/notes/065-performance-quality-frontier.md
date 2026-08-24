# 065 — Performance bar crossed; semantic gate still binds

Status: **performance PASS, quality FAIL for ≥2.5× profiles**

## Fastest profile

Prefill-only layer stride 2 plus MoE top-k 1, weights fixed:

| Cell | Baseline tok/s | Candidate tok/s | Speedup |
|---|---:|---:|---:|
| B=1×512 | 1,434.6 | 3,605.1 | **2.513×** |
| B=1×2K | 1,671.4 | 4,511.7 | **2.699×** |
| B=1×8K | 1,546.8 | 4,529.0 | **2.928×** |
| B=2×8K | 1,500.7 | 4,428.0 | **2.951×** |
| B=4×2K | 1,695.8 adjacent | 4,601.7 | **2.713×** |
| B=4×8K | 1,557.4 | 4,273.8 | **2.744×** |

The raw throughput objective is reached across every required axis.

## Quality

The 12-prompt/64-token natural corpus rejects this profile:

- exact cases: 0/12;
- token-position agreement: 1.04%;
- first token differs on every case;
- unrelated text, loops, and control-token leakage occur.

Blind review 064 marks every measured ≥2.5× profile unusable.

## Quality-preserving component

Top-k 4 with all 40 layers:

- B=4×8K: 1.192×;
- 56.0% token-position agreement;
- blind semantic score retains 99.19% of baseline;
- no candidate-only fatal failure or corruption.

This is a viable approximate component, not the full multiplier.

## Artifact-only state construction

State/KV-only skipped layers correctly construct persistent artifacts and
reach 2.36–2.75× at B=4×2K depending on top-k. Eight/eleven full-layer
profiles remain semantically degraded; constructing shape-correct state
is necessary but not sufficient for language quality.

## Active path

Compose the quality-passing top-k4 profile with:

1. exact KV+GDN prefix-state reuse;
2. sensitivity-guided token/layer work deletion;
3. quality-gated state-river profiles.

Do not claim completion from throughput alone.
